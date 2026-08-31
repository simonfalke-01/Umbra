import Dispatch
import UmbraNetworking

/// Creates native LSP discovery without altering legacy GameStream browsing.
public enum LSPDiscovery {
    /// Creates a Bonjour browser for `_lumen-stream._udp.local.`.
    ///
    /// - Parameter queue: Private browser and retry queue.
    /// - Returns: A discovery owner that emits only native LSP services.
    public static func makeBonjourBrowser(
        queue: DispatchQueue = DispatchQueue(label: "app.umbra.lsp-bonjour-discovery")
    ) -> NetworkBonjourDiscovery {
        NetworkBonjourDiscovery(serviceProtocol: .lumenStreamingProtocol, queue: queue)
    }
}
