import Foundation

public final class QUICPathMigrationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: QUICPathSnapshot?
    private var generation: UInt64 = 0

    public init() {}

    /// Returns an observation only for a material path change after the initial path.
    public func observe(_ path: QUICPathSnapshot) -> QUICMigrationObservation? {
        lock.withLock {
            guard let previous = current else {
                current = path
                return nil
            }
            guard previous != path else { return nil }
            generation &+= 1
            current = path
            return QUICMigrationObservation(
                generation: generation,
                previous: previous,
                current: path
            )
        }
    }

    public func reset() {
        lock.withLock {
            current = nil
            generation = 0
        }
    }
}
