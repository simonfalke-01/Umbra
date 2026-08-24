import Foundation
import XCTest
@testable import UmbraMedia

final class SoundSourceCompatibilityTests: XCTestCase {
    func testMutedRendererCompletesThreeRealHardwareLifecyclesWithoutErrors() throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_AUDIO_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip(
                "Set UMBRA_RUN_AUDIO_HARDWARE_TESTS=1 to exercise the physical AudioQueue silently."
            )
        }

        for cycle in 1...3 {
            let renderer = AudioQueuePCMRenderer(configuration: PCMRendererConfiguration())
            renderer.setManuallyMuted(true)
            XCTAssertTrue(renderer.isMuted, "Cycle \(cycle) must be muted before hardware starts.")

            try renderer.start()
            XCTAssertTrue(renderer.statistics.playbackStarted, "Cycle \(cycle) did not start playback.")
            Thread.sleep(forTimeInterval: 0.100)

            XCTAssertEqual(renderer.stop(), .complete, "Cycle \(cycle) did not dispose cleanly.")
            XCTAssertNil(renderer.lastError, "Cycle \(cycle) reported an AudioQueue error.")
        }
    }
}
