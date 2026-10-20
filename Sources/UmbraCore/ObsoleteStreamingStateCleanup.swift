import Foundation

/// Removes the retired native-streaming state without touching GameStream-compatible state.
public enum ObsoleteStreamingStateCleanup {
    private static let markerName = ".obsolete-stream-state-cleanup-v1"
    private static let exactNames: Set<String> = [
        "protocol-v3-trust-v1.json",
        "protocol-v3-trust-v1.json.lock",
        "protocol-v3-hosts-v1.json",
        "protocol-v3-hosts-v1.json.lock",
    ]

    /// Performs the cleanup once for Umbra's default application-support directory.
    ///
    /// - Parameters:
    ///   - fileManager: File manager used to locate and remove state.
    ///   - bundleIdentifier: Application-support directory name.
    public static func performDefaultIfNeeded(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "app.umbra.Umbra"
    ) throws {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try performIfNeeded(
            in: supportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Removes only the retired trust, host-catalog, lock, and temporary files.
    ///
    /// A marker is written after successful cleanup so later launches do not rescan the directory.
    /// Existing directories and every unrelated file are preserved.
    ///
    /// - Parameters:
    ///   - directory: Umbra's application-support directory.
    ///   - fileManager: File manager used to inspect and remove entries.
    public static func performIfNeeded(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let marker = directory.appendingPathComponent(markerName, isDirectory: false)
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries where isRetiredStateName(entry.lastPathComponent) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { continue }
            try fileManager.removeItem(at: entry)
        }

        try Data().write(to: marker, options: [.atomic])
    }

    private static func isRetiredStateName(_ name: String) -> Bool {
        exactNames.contains(name)
            || (name.hasPrefix(".protocol-v3-") && name.hasSuffix(".tmp"))
    }
}
