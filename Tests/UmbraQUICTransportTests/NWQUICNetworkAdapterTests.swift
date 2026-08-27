import Network
import Testing
@testable import UmbraQUICTransport

@Suite("Network.framework QUIC adapter")
struct NWQUICNetworkAdapterTests {
    @Test("control readiness waits for aggregate recovery, never DATAGRAM, and is one-shot")
    func controlReadinessDoesNotWaitForDatagram() {
        #expect(NWQUICNetworkAdapter.canEmitReady(
            controlReady: true,
            readyEmitted: false,
            hasWaitingSources: false,
            negotiatedALPN: QUICTransportConfiguration.applicationProtocol
        ))
        #expect(!NWQUICNetworkAdapter.canEmitReady(
            controlReady: false,
            readyEmitted: false,
            hasWaitingSources: false,
            negotiatedALPN: QUICTransportConfiguration.applicationProtocol
        ))
        #expect(!NWQUICNetworkAdapter.canEmitReady(
            controlReady: true,
            readyEmitted: true,
            hasWaitingSources: false,
            negotiatedALPN: QUICTransportConfiguration.applicationProtocol
        ))
        #expect(!NWQUICNetworkAdapter.canEmitReady(
            controlReady: true,
            readyEmitted: false,
            hasWaitingSources: true,
            negotiatedALPN: QUICTransportConfiguration.applicationProtocol
        ))
    }

    @Test("DATAGRAM child uses a copied parent QUIC transport option")
    func datagramChildUsesCopiedParentOption() throws {
        let parent = NWProtocolQUIC.Options(alpn: [QUICTransportConfiguration.applicationProtocol])
        parent.direction = .bidirectional
        parent.maxUDPPayloadSize = 1_350
        parent.maxDatagramFrameSize = QUICTransportProfile.semanticDatagramByteCount
        let parameters = NWParameters(quic: parent)

        let child = try #require(NWQUICNetworkAdapter.makeDatagramChildOptions(from: parameters))

        #expect(child !== parent)
        #expect(!parent.isDatagram)
        #expect(child.isDatagram)
        #expect(child.alpn == parent.alpn)
        #expect(child.direction == parent.direction)
        #expect(child.maxUDPPayloadSize == parent.maxUDPPayloadSize)
        #expect(child.maxDatagramFrameSize == parent.maxDatagramFrameSize)
    }
}
