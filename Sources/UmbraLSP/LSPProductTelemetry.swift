import Foundation
import UmbraMedia

/// Fixed-window coarse-stage distribution. It never claims physical presentation or input-to-photon.
public struct LSPDistributionSnapshot: Equatable, Sendable {
    public var count: Int
    public var p50Microseconds: UInt64
    public var p95Microseconds: UInt64
    public var p99Microseconds: UInt64
    public var maximumMicroseconds: UInt64
    public var drops: UInt64
    public var clockDomain: String
}

public struct LSPProductTelemetrySnapshot: Equatable, Sendable {
    /// Coarse VideoToolbox pipeline counters captured on the low-rate telemetry tick.
    public var videoDecoderStatistics: MediaPipelineStatistics? = nil
    public var completeFrameReceiveToVideoToolboxSubmit: LSPDistributionSnapshot?
    public var videoToolboxSubmitToDecodeCompletion: LSPDistributionSnapshot?
    public var completeFrameReceiveToMetalEnqueue: LSPDistributionSnapshot?
    public var metalEnqueueToCommit: LSPDistributionSnapshot?
    public var metalCommitToCompletion: LSPDistributionSnapshot?
    public var audioReceiveToDecode: LSPDistributionSnapshot?
    public var audioDecodeAndRenderEnqueue: LSPDistributionSnapshot?
    public var audioUnderruns: UInt64?
    public var audioRebuffers: UInt64?
    public var reconnectDuration: LSPDistributionSnapshot?
}

struct LSPFixedDurationWindow: Sendable {
    private var samples = [UInt64](repeating: 0, count: 256)
    private var count = 0
    private var writeIndex = 0
    private(set) var drops: UInt64 = 0

    mutating func record(_ microseconds: UInt64) {
        samples[writeIndex] = microseconds
        writeIndex = (writeIndex + 1) % samples.count
        count = min(count + 1, samples.count)
    }

    mutating func drop() { drops &+= 1 }

    func snapshot(clockDomain: String = "client-monotonic") -> LSPDistributionSnapshot? {
        guard count > 0 else { return nil }
        let sorted = Array(samples.prefix(count)).sorted()
        func percentile(_ value: Double) -> UInt64 {
            let rank = max(1, Int(ceil(value * Double(sorted.count))))
            return sorted[min(rank - 1, sorted.count - 1)]
        }
        return .init(
            count: count,
            p50Microseconds: percentile(0.50),
            p95Microseconds: percentile(0.95),
            p99Microseconds: percentile(0.99),
            maximumMicroseconds: sorted.last!,
            drops: drops,
            clockDomain: clockDomain
        )
    }
}
