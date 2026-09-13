import Foundation
import UmbraNetworking

/// Resolves Bonjour metadata and the SRV target name without opening a throwaway UDP connection.
final class LSPBonjourTXTResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    typealias Resolution = (service: DiscoveredHostService, endpoint: ResolvedBonjourServiceEndpoint)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Resolution?, Never>?
    private var discovered: DiscoveredHostService?
    private var service: NetService?
    private var serviceRunLoop: CFRunLoop?
    private var finished = false

    func resolve(_ discovered: DiscoveredHostService) async -> Resolution? {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldStart = lock.withLock { () -> Bool in
                    guard !finished else { return false }
                    self.continuation = continuation
                    self.discovered = discovered
                    return true
                }
                guard shouldStart else {
                    continuation.resume(returning: nil)
                    return
                }
                let thread = Thread { [self] in
                    run(discovered)
                }
                thread.name = "Umbra LSP Bonjour resolver"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            self.finish(nil)
        }
    }

    private func run(_ discovered: DiscoveredHostService) {
        autoreleasepool {
            let type = discovered.type.hasSuffix(".") ? discovered.type : discovered.type + "."
            let service = NetService(
                domain: discovered.domain,
                type: type,
                name: discovered.name
            )
            let runLoop = CFRunLoopGetCurrent()
            let shouldResolve = lock.withLock { () -> Bool in
                guard !finished else { return false }
                self.service = service
                serviceRunLoop = runLoop
                return true
            }
            guard shouldResolve else { return }

            service.delegate = self
            service.schedule(in: .current, forMode: .common)
            service.startMonitoring()
            service.resolve(withTimeout: 3)

            let deadline = Date().addingTimeInterval(3.25)
            while !lock.withLock({ finished }), Date() < deadline {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(deadline, Date().addingTimeInterval(0.05))
                )
            }
            if !lock.withLock({ finished }) {
                finish(nil)
            }

            service.stopMonitoring()
            service.stop()
            service.remove(from: .current, forMode: .common)
            lock.withLock {
                self.service = nil
                serviceRunLoop = nil
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolveTXT(sender.txtRecordData())
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        resolveTXT(data)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = errorDict
        finish(nil)
    }

    private func resolveTXT(_ data: Data?) {
        guard var discovered = lock.withLock({ self.discovered }) else { return }
        if let data {
            let values = NetService.dictionary(fromTXTRecord: data)
            var text: [String: String] = [:]
            for (key, value) in values {
                guard let decoded = String(data: value, encoding: .utf8) else {
                    finish(nil)
                    return
                }
                text[key] = decoded
            }
            if !text.isEmpty {
                discovered.txtRecord = text
                lock.withLock { self.discovered = discovered }
            }
        }
        guard !discovered.txtRecord.isEmpty,
              let service = lock.withLock({ self.service }),
              let targetHost = service.hostName, !targetHost.isEmpty,
              let port = UInt16(exactly: service.port), port != 0 else { return }
        finish((discovered, .init(
            targetHost: targetHost,
            port: port,
            serviceName: discovered.name,
            serviceType: discovered.type,
            domain: discovered.domain,
            interfaceName: discovered.interfaceName,
            changeToken: discovered.changeToken
        )))
    }

    private func finish(_ result: Resolution?) {
        let completion = lock.withLock { () -> CheckedContinuation<Resolution?, Never>? in
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        guard let completion else { return }
        let runLoop = lock.withLock { serviceRunLoop }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        completion.resume(returning: result)
    }
}
