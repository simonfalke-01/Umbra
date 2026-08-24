import Foundation

@MainActor
public final class KeepAwakeActivity {
    public private(set) var isActive = false
    nonisolated(unsafe) private var activity: NSObjectProtocol?

    public init() {}

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    public func setActive(_ active: Bool, reason: String = "Umbra game stream is active") {
        guard active != isActive else { return }
        isActive = active
        if active {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: reason
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
