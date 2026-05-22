import Foundation
import Network
import NSWatchLoggerModels

final class HTTPListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.nswatchlogger.http-listener")

    var onLogReceived: ((LogEntry) -> Void)?
    var onClientConnected: ((ClientConnection) -> Void)?
    var onClientDisconnected: ((UUID) -> Void)?

    var nwListener: NWListener? {
        lock.lock()
        defer { lock.unlock() }
        return listener
    }

    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: nwPort)

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[NSWatchLoggerServer] HTTP listener failed: \(error)")
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        let clientID = UUID()
        let endpoint = describeEndpoint(connection.endpoint)
        let client = ClientConnection(
            id: clientID,
            remoteEndpoint: endpoint,
            transportType: .http
        )
        onClientConnected?(client)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(connection, clientID: clientID)
            case .failed, .cancelled:
                self?.onClientDisconnected?(clientID)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveRequest(_ connection: NWConnection, clientID: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                self?.onClientDisconnected?(clientID)
                return
            }

            self.processHTTPData(data, connection: connection, clientID: clientID)

            if error != nil || isComplete {
                connection.cancel()
                self.onClientDisconnected?(clientID)
            }
        }
    }

    private func processHTTPData(_ data: Data, connection: NWConnection, clientID: UUID) {
        guard let request = parseHTTPRequest(data) else {
            sendResponse(connection, statusCode: 400, body: "Bad Request")
            return
        }

        guard request.method == "POST" else {
            sendResponse(connection, statusCode: 405, body: "Method Not Allowed")
            return
        }

        let path = request.path
        guard path == BonjourConstants.httpPathLog || path == BonjourConstants.httpPathBatch else {
            sendResponse(connection, statusCode: 404, body: "Not Found")
            return
        }

        let body = request.body
        guard !body.isEmpty else {
            sendResponse(connection, statusCode: 400, body: "Empty body")
            return
        }

        if path == BonjourConstants.httpPathLog {
            do {
                let entry = try LogEntry.jsonDecoder.decode(LogEntry.self, from: body)
                onLogReceived?(entry)
                sendResponse(connection, statusCode: 200, body: "OK")
            } catch {
                sendResponse(connection, statusCode: 400, body: "Invalid JSON")
            }
        } else {
            do {
                let entries = try LogEntry.jsonDecoder.decode([LogEntry].self, from: body)
                for entry in entries {
                    onLogReceived?(entry)
                }
                sendResponse(connection, statusCode: 200, body: "OK")
            } catch {
                sendResponse(connection, statusCode: 400, body: "Invalid JSON")
            }
        }
    }

    private func sendResponse(_ connection: NWConnection, statusCode: Int, body: String) {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }

        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n\(body)"

        connection.send(
            content: Data(response.utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func describeEndpoint(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return endpoint.debugDescription
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data
}

private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
    guard let headerEnd = findHeaderEnd(in: data) else { return nil }

    let headerData = data[data.startIndex..<headerEnd]
    guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }

    let method = String(parts[0])
    let path = String(parts[1])

    var headers: [(String, String)] = []
    for line in lines.dropFirst() {
        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        headers.append((key, value))
    }

    let bodyStart = headerEnd + 4 // skip \r\n\r\n
    let body: Data
    if bodyStart < data.count {
        body = data[bodyStart...]
    } else {
        body = Data()
    }

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
}

private func findHeaderEnd(in data: Data) -> Data.Index? {
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
    guard data.count >= 4 else { return nil }

    for i in data.startIndex...(data.index(data.endIndex, offsetBy: -4)) {
        if data[i] == separator[0]
            && data[data.index(after: i)] == separator[1]
            && data[data.index(i, offsetBy: 2)] == separator[2]
            && data[data.index(i, offsetBy: 3)] == separator[3] {
            return i
        }
    }
    return nil
}
