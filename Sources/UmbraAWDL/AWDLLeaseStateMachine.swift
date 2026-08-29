import Darwin
import Foundation

public struct AWDLLeaseRecord: Codable, Equatable, Sendable {
    public let leaseIdentifier: String
    public let priorState: AWDLInterfaceState

    public init(leaseIdentifier: String, priorState: AWDLInterfaceState) {
        self.leaseIdentifier = leaseIdentifier
        self.priorState = priorState
    }
}

public protocol AWDLInterfaceControlling: Sendable {
    func state() throws -> AWDLInterfaceState
    func setState(_ state: AWDLInterfaceState) throws
}

public protocol AWDLLeasePersisting: Sendable {
    func load() throws -> AWDLLeaseRecord?
    func save(_ record: AWDLLeaseRecord) throws
    func clear() throws
}

public actor AWDLLeaseStateMachine {
    private let interface: any AWDLInterfaceControlling
    private let persistence: any AWDLLeasePersisting
    private var loaded = false
    private var lease: AWDLLeaseRecord?

    public init(
        interface: any AWDLInterfaceControlling,
        persistence: any AWDLLeasePersisting
    ) {
        self.interface = interface
        self.persistence = persistence
    }

    public func recoverPersistedLease() throws {
        try loadIfNeeded()
        guard let lease else { return }
        try interface.setState(lease.priorState)
        try persistence.clear()
        self.lease = nil
    }

    public func status() throws -> AWDLHelperStatus {
        try loadIfNeeded()
        return AWDLHelperStatus(
            interfaceState: try interface.state(),
            leaseIdentifier: lease?.leaseIdentifier,
            priorState: lease?.priorState
        )
    }

    public func down(leaseIdentifier: String) throws -> AWDLHelperStatus {
        try Self.validate(leaseIdentifier)
        try loadIfNeeded()
        if let lease {
            guard lease.leaseIdentifier == leaseIdentifier else { throw AWDLHelperError.busy }
            return try status()
        }

        let priorState = try interface.state()
        let record = AWDLLeaseRecord(
            leaseIdentifier: leaseIdentifier,
            priorState: priorState
        )
        try persistence.save(record)
        lease = record
        do {
            try interface.setState(.down)
            return try status()
        } catch {
            do {
                try interface.setState(priorState)
                try persistence.clear()
                lease = nil
            } catch {
                // Keep the durable lease so daemon restart/retry restores it.
            }
            throw error
        }
    }

    public func up(leaseIdentifier: String) throws -> AWDLHelperStatus {
        try Self.validate(leaseIdentifier)
        try loadIfNeeded()
        guard let lease else { return try status() }
        guard lease.leaseIdentifier == leaseIdentifier else { throw AWDLHelperError.busy }
        try interface.setState(lease.priorState)
        try persistence.clear()
        self.lease = nil
        return try status()
    }

    public func restoreOwnedLeaseIfPresent(leaseIdentifier: String) throws {
        try loadIfNeeded()
        guard lease?.leaseIdentifier == leaseIdentifier else { return }
        _ = try up(leaseIdentifier: leaseIdentifier)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        lease = try persistence.load()
        loaded = true
    }

    private static func validate(_ leaseIdentifier: String) throws {
        guard UUID(uuidString: leaseIdentifier)?.uuidString == leaseIdentifier.uppercased() else {
            throw AWDLHelperError.invalidLeaseIdentifier
        }
    }
}

public struct AWDLSystemInterfaceController: AWDLInterfaceControlling, Sendable {
    private let interfaceName: String

    public init(interfaceName: String = AWDLHelperContract.interfaceName) {
        self.interfaceName = interfaceName
    }

    public func state() throws -> AWDLInterfaceState {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { freeifaddrs(addresses) }
        var address: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = address {
            if String(cString: current.pointee.ifa_name) == interfaceName {
                return current.pointee.ifa_flags & UInt32(IFF_UP) == 0 ? .down : .up
            }
            address = current.pointee.ifa_next
        }
        throw AWDLHelperError.interfaceUnavailable
    }

    public func setState(_ state: AWDLInterfaceState) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [interfaceName, state.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AWDLHelperError.operationFailed(
                message?.isEmpty == false ? message! : "ifconfig exited \(process.terminationStatus)"
            )
        }
    }
}

public final class AWDLJSONLeaseStore: AWDLLeasePersisting, @unchecked Sendable {
    public static let defaultURL = URL(
        fileURLWithPath: "/var/db/app.umbra.Umbra.AWDLHelper/lease.json"
    )

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL = defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> AWDLLeaseRecord? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
            return try JSONDecoder().decode(
                AWDLLeaseRecord.self,
                from: Data(contentsOf: fileURL, options: .uncached)
            )
        }
    }

    public func save(_ record: AWDLLeaseRecord) throws {
        try lock.withLock {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    public func clear() throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        }
    }
}
