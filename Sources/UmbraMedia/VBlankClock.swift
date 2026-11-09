import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import os

/// Tracks when each refresh of one display starts scanning out, from the screen's CADisplayLink.
/// CVDisplayLink timestamps drift against the real vsync on ProMotion panels; CADisplayLink takes
/// its timestamps from WindowServer's own vsync timing.
final class VBlankClock: NSObject, @unchecked Sendable {
    private struct Timing {
        var scanoutStart: CFTimeInterval = 0
        var period: CFTimeInterval = 0
    }

    private let timing = OSAllocatedUnfairLock(initialState: Timing())
    private(set) var displayID: CGDirectDisplayID?
    private var thread: Thread?

    deinit {
        stop()
    }

    /// Follows `displayID`; a no-op when it is already the followed display.
    func start(displayID: CGDirectDisplayID) {
        guard displayID != self.displayID || thread == nil else { return }
        stop()
        self.displayID = displayID
        // The link runs on its own thread so a busy main thread never delays its callbacks.
        let thread = Thread { [weak self] in
            let found = DispatchQueue.main.sync { () -> (CADisplayLink, Int)? in
                guard let self,
                      let screen = NSScreen.screens.first(where: {
                          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                      }) else { return nil }
                return (screen.displayLink(target: self, selector: #selector(VBlankClock.tick(_:))), screen.maximumFramesPerSecond)
            }
            guard self != nil, let (link, maximumFramesPerSecond) = found else { return }
            // Fire on every refresh; a ProMotion link otherwise follows frame-rate arbitration.
            let maximum = Float(max(1, maximumFramesPerSecond))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
            link.add(to: .current, forMode: .common)
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
            link.invalidate()
        }
        thread.name = "app.umbra.vblank-clock"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        thread?.cancel()
        thread = nil
        displayID = nil
        timing.withLock { $0 = Timing() }
    }

    /// The first scanout start at or after `time`, or nil until the display link has reported.
    func nextScanoutStart(atOrAfter time: CFTimeInterval) -> CFTimeInterval? {
        let current = timing.withLock { $0 }
        guard current.period > 0, current.scanoutStart > 0 else { return nil }
        let refreshes = ((time - current.scanoutStart) / current.period).rounded(.up)
        return current.scanoutStart + refreshes * current.period
    }

    /// The display's current refresh period, or nil until the display link has reported.
    var refreshPeriod: CFTimeInterval? {
        let period = timing.withLock { $0.period }
        return period > 0 ? period : nil
    }

    /// Fraction of the refresh period elapsed since the most recent scanout start at `time`.
    func scanPhase(at time: CFTimeInterval) -> Double? {
        let current = timing.withLock { $0 }
        guard current.period > 0, current.scanoutStart > 0 else { return nil }
        let elapsed = (time - current.scanoutStart).truncatingRemainder(dividingBy: current.period)
        return (elapsed < 0 ? elapsed + current.period : elapsed) / current.period
    }

    @objc private func tick(_ link: CADisplayLink) {
        let scanoutStart = link.timestamp
        let period = link.targetTimestamp - scanoutStart
        guard scanoutStart > 0, period > 0.001, period < 0.05 else { return }
        timing.withLock { $0 = Timing(scanoutStart: scanoutStart, period: period) }
    }
}
