import Foundation

final class BonjourResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var service: NetService?
    private var completion: ((String?) -> Void)?

    func resolve(name: String, type: String, domain: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        self.completion = completion
        let svc = NetService(domain: domain, type: type, name: name)
        self.service = svc
        lock.unlock()

        svc.delegate = self
        svc.resolve(withTimeout: 10.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        lock.lock()
        let cb = completion
        completion = nil
        service = nil
        lock.unlock()

        var host = sender.hostName
        if let h = host, h.contains(":") {
            host = "[\(h)]"
        }
        cb?(host)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.lock()
        let cb = completion
        completion = nil
        service = nil
        lock.unlock()

        cb?(nil)
    }
}
