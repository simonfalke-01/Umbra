import AppKit
import Darwin
import Foundation

private struct ProcessIdentity: Codable, Equatable {
    let pid: Int32
    let bundleIdentifier: String
    let executablePath: String
    let executableDevice: UInt64
    let executableInode: UInt64
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case pid
        case bundleIdentifier = "bundle_identifier"
        case executablePath = "executable_path"
        case executableDevice = "executable_device"
        case executableInode = "executable_inode"
        case startSeconds = "start_seconds"
        case startMicroseconds = "start_microseconds"
    }
}

private struct CoreProcessIdentity {
    let pid: Int32
    let executablePath: String
    let executableDevice: UInt64
    let executableInode: UInt64
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private enum HelperError: Error, CustomStringConvertible {
    case usage
    case processUnavailable(Int32)
    case executableMismatch(expected: String, actual: String)
    case bundleMismatch(expected: String, actual: String)
    case identityMismatch
    case identityArtifactInvalid(String)
    case bundleRegistrationPending(String)
    case applicationRegistrationPending(Int32)
    case launchFailed(String)
    case runningApplicationUnavailable(Int32)
    case terminationRejected(Int32)

    var description: String {
        switch self {
        case .usage:
            "usage: pid-helper find-bundle <bundle-id> | launch <app> <bundle-id> -- <arguments...> | pid <identity.json> | capture-bootstrap <pid> <executable> <bundle-id> | identity <pid> <executable> <bundle-id> | verify-readiness <identity.json> | verify <identity.json> | terminate <identity.json> | force-terminate <identity.json> | terminate-bootstrap <identity.json> | force-terminate-bootstrap <identity.json>"
        case let .processUnavailable(pid):
            "process \(pid) is unavailable"
        case let .executableMismatch(expected, actual):
            "executable mismatch: expected \(expected), found \(actual)"
        case let .bundleMismatch(expected, actual):
            "bundle mismatch: expected \(expected), found \(actual)"
        case .identityMismatch:
            "process identity changed; refusing to act"
        case let .identityArtifactInvalid(reason):
            "identity artifact is invalid: \(reason)"
        case let .bundleRegistrationPending(bundleIdentifier):
            "bundle registration pending for \(bundleIdentifier)"
        case let .applicationRegistrationPending(pid):
            "application registration pending for process \(pid)"
        case let .launchFailed(reason):
            "application launch failed: \(reason)"
        case let .runningApplicationUnavailable(pid):
            "NSRunningApplication unavailable for process \(pid)"
        case let .terminationRejected(pid):
            "NSRunningApplication rejected termination for process \(pid)"
        }
    }
}

private func resolvedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

private func captureCoreIdentity(
    pid: Int32,
    expectedExecutable: String? = nil
) throws -> CoreProcessIdentity {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    guard pathLength > 0 else { throw HelperError.processUnavailable(pid) }
    let executablePath = resolvedPath(String(cString: pathBuffer))

    if let expectedExecutable {
        let expected = resolvedPath(expectedExecutable)
        guard executablePath == expected else {
            throw HelperError.executableMismatch(expected: expected, actual: executablePath)
        }
    }

    var processInfo = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &processInfo, infoSize) == infoSize else {
        throw HelperError.processUnavailable(pid)
    }

    var fileInfo = stat()
    guard stat(executablePath, &fileInfo) == 0 else { throw HelperError.processUnavailable(pid) }
    return CoreProcessIdentity(
        pid: pid,
        executablePath: executablePath,
        executableDevice: UInt64(fileInfo.st_dev),
        executableInode: UInt64(fileInfo.st_ino),
        startSeconds: processInfo.pbi_start_tvsec,
        startMicroseconds: processInfo.pbi_start_tvusec
    )
}

private func processIdentity(
    core: CoreProcessIdentity,
    bundleIdentifier: String
) -> ProcessIdentity {
    ProcessIdentity(
        pid: core.pid,
        bundleIdentifier: bundleIdentifier,
        executablePath: core.executablePath,
        executableDevice: core.executableDevice,
        executableInode: core.executableInode,
        startSeconds: core.startSeconds,
        startMicroseconds: core.startMicroseconds
    )
}

private func captureIdentity(
    pid: Int32,
    expectedExecutable: String? = nil,
    expectedBundleIdentifier: String? = nil,
    allowBundleRegistrationDelay: Bool = false,
    requireRunningApplication: Bool = false
) throws -> ProcessIdentity {
    let core = try captureCoreIdentity(pid: pid, expectedExecutable: expectedExecutable)
    let runningApplication = NSRunningApplication(processIdentifier: pid)
    if requireRunningApplication && runningApplication == nil {
        throw HelperError.runningApplicationUnavailable(pid)
    }
    let observedBundleIdentifier = runningApplication?.bundleIdentifier ?? ""
    let bundleIdentifier: String
    if let expectedBundleIdentifier {
        if allowBundleRegistrationDelay && observedBundleIdentifier.isEmpty {
            bundleIdentifier = expectedBundleIdentifier
        } else {
            guard observedBundleIdentifier == expectedBundleIdentifier else {
                throw HelperError.bundleMismatch(
                    expected: expectedBundleIdentifier,
                    actual: observedBundleIdentifier
                )
            }
            bundleIdentifier = observedBundleIdentifier
        }
    } else {
        bundleIdentifier = observedBundleIdentifier
    }

    return processIdentity(core: core, bundleIdentifier: bundleIdentifier)
}

private func matchingApplications(
    bundleIdentifier: String,
    executablePath: String
) -> [NSRunningApplication] {
    var applicationsByPID: [Int32: NSRunningApplication] = [:]
    for application in NSWorkspace.shared.runningApplications {
        let pid = application.processIdentifier
        guard pid > 0,
              !application.isTerminated,
              application.bundleIdentifier == bundleIdentifier,
              let executableURL = application.executableURL,
              executableURL.resolvingSymlinksInPath().path == executablePath else {
            continue
        }
        applicationsByPID[pid] = application
    }
    return applicationsByPID.values.sorted {
        $0.processIdentifier < $1.processIdentifier
    }
}

private func launchTestFlag(_ name: String, bundleIdentifier: String) -> Bool {
    bundleIdentifier == "app.umbra.LaunchFixture"
        && ProcessInfo.processInfo.environment[name] == "1"
}

private func launchTestReturnedCaptureDelayNanoseconds(
    bundleIdentifier: String
) -> UInt64 {
    guard bundleIdentifier == "app.umbra.LaunchFixture",
          let value = ProcessInfo.processInfo.environment[
              "UMBRA_PERF_TEST_RETURNED_CAPTURE_DELAY_MS"
          ],
          let milliseconds = UInt64(value) else {
        return 0
    }
    return milliseconds * 1_000_000
}

private func launchApplicationSummary(_ application: NSRunningApplication?) -> String {
    guard let application else { return "none" }
    let executablePath = application.executableURL?
        .resolvingSymlinksInPath().path ?? ""
    return [
        "pid=\(application.processIdentifier)",
        "bundle=\(application.bundleIdentifier ?? "")",
        "executable=\(executablePath)",
        "is_terminated=\(application.isTerminated)",
        "is_finished_launching=\(application.isFinishedLaunching)",
    ].joined(separator: ",")
}

private func identityFromRunningApplication(
    _ application: NSRunningApplication,
    expectedBundleIdentifier: String,
    expectedExecutablePath: String,
    expectedPID: Int32? = nil,
    allowRegistrationDelay: Bool = false
) throws -> ProcessIdentity {
    let pid = application.processIdentifier
    if let expectedPID, pid != expectedPID {
        throw HelperError.identityMismatch
    }
    guard pid > 0, !application.isTerminated else {
        throw HelperError.processUnavailable(pid)
    }
    let returnedBundleIdentifier = application.bundleIdentifier ?? ""
    if allowRegistrationDelay && returnedBundleIdentifier.isEmpty {
        throw HelperError.applicationRegistrationPending(pid)
    }
    guard returnedBundleIdentifier == expectedBundleIdentifier else {
        throw HelperError.bundleMismatch(
            expected: expectedBundleIdentifier,
            actual: returnedBundleIdentifier
        )
    }
    guard let returnedExecutableURL = application.executableURL else {
        if allowRegistrationDelay {
            throw HelperError.applicationRegistrationPending(pid)
        }
        throw HelperError.executableMismatch(
            expected: expectedExecutablePath,
            actual: ""
        )
    }
    let returnedExecutablePath = returnedExecutableURL.resolvingSymlinksInPath().path
    guard returnedExecutablePath == expectedExecutablePath else {
        throw HelperError.executableMismatch(
            expected: expectedExecutablePath,
            actual: returnedExecutablePath
        )
    }
    let core = try captureCoreIdentity(
        pid: pid,
        expectedExecutable: expectedExecutablePath
    )
    return processIdentity(core: core, bundleIdentifier: returnedBundleIdentifier)
}

private func launchApplication(
    appPath: String,
    expectedBundleIdentifier: String,
    arguments: [String]
) throws -> ProcessIdentity {
    let appURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
    guard let bundle = Bundle(url: appURL),
          let actualBundleIdentifier = bundle.bundleIdentifier else {
        throw HelperError.launchFailed("invalid application bundle at \(appURL.path)")
    }
    guard actualBundleIdentifier == expectedBundleIdentifier else {
        throw HelperError.bundleMismatch(
            expected: expectedBundleIdentifier,
            actual: actualBundleIdentifier
        )
    }
    guard let bundleExecutableURL = bundle.executableURL else {
        throw HelperError.launchFailed("application bundle has no executable")
    }
    let expectedExecutablePath = bundleExecutableURL.resolvingSymlinksInPath().path

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    configuration.addsToRecentItems = false

    let prelaunchPIDs = Set(matchingApplications(
        bundleIdentifier: expectedBundleIdentifier,
        executablePath: expectedExecutablePath
    ).map(\.processIdentifier))
    let launchDeadlineNanoseconds = DispatchTime.now().uptimeNanoseconds + 10_000_000_000

    var launchedApplication: NSRunningApplication?
    var launchError: Error?
    var completionReceived = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
        launchedApplication = application
        launchError = error
        completionReceived = true
    }

    while !completionReceived
        && DispatchTime.now().uptimeNanoseconds < launchDeadlineNanoseconds {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard completionReceived else {
        throw HelperError.launchFailed("NSWorkspace completion timed out")
    }
    if let launchError {
        throw HelperError.launchFailed(launchError.localizedDescription)
    }
    guard let application = launchedApplication else {
        throw HelperError.launchFailed("NSWorkspace returned no application")
    }
    if let returnedBundleIdentifier = application.bundleIdentifier,
       !returnedBundleIdentifier.isEmpty,
       returnedBundleIdentifier != expectedBundleIdentifier {
        throw HelperError.bundleMismatch(
            expected: expectedBundleIdentifier,
            actual: returnedBundleIdentifier
        )
    }
    if let returnedExecutableURL = application.executableURL {
        let returnedExecutablePath = returnedExecutableURL.resolvingSymlinksInPath().path
        guard returnedExecutablePath == expectedExecutablePath else {
            throw HelperError.executableMismatch(
                expected: expectedExecutablePath,
                actual: returnedExecutablePath
            )
        }
    }

    let forcePlaceholder = launchTestFlag(
        "UMBRA_PERF_TEST_FORCE_PLACEHOLDER",
        bundleIdentifier: expectedBundleIdentifier
    )
    let hideCandidates = launchTestFlag(
        "UMBRA_PERF_TEST_HIDE_CANDIDATES",
        bundleIdentifier: expectedBundleIdentifier
    )
    let returnedCaptureDelayNanoseconds = launchTestReturnedCaptureDelayNanoseconds(
        bundleIdentifier: expectedBundleIdentifier
    )
    var lastObservedNewPIDs: [Int32] = []
    var observedNewPIDs = Set<Int32>()
    var disappearedCandidatePIDs = Set<Int32>()
    var stableIdentity: ProcessIdentity?
    var stableSinceNanoseconds: UInt64?
    var exclusiveReturnedPID: Int32?
    var returnedCaptureNotBeforeNanoseconds: UInt64 = 0

    while DispatchTime.now().uptimeNanoseconds < launchDeadlineNanoseconds {
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        if !forcePlaceholder && exclusiveReturnedPID == nil,
           application.processIdentifier > 0 {
            exclusiveReturnedPID = application.processIdentifier
            returnedCaptureNotBeforeNanoseconds = nowNanoseconds
                + returnedCaptureDelayNanoseconds
        }
        if let exclusiveReturnedPID {
            guard application.processIdentifier == exclusiveReturnedPID else {
                throw HelperError.identityMismatch
            }
            guard !application.isTerminated else {
                throw HelperError.processUnavailable(exclusiveReturnedPID)
            }
            if nowNanoseconds < returnedCaptureNotBeforeNanoseconds {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
                continue
            }
            do {
                return try identityFromRunningApplication(
                    application,
                    expectedBundleIdentifier: expectedBundleIdentifier,
                    expectedExecutablePath: expectedExecutablePath,
                    expectedPID: exclusiveReturnedPID,
                    allowRegistrationDelay: true
                )
            } catch HelperError.processUnavailable,
                    HelperError.applicationRegistrationPending {
                guard !application.isTerminated else {
                    throw HelperError.processUnavailable(exclusiveReturnedPID)
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
                continue
            }
        }

        var candidates = matchingApplications(
            bundleIdentifier: expectedBundleIdentifier,
            executablePath: expectedExecutablePath
        ).filter { !prelaunchPIDs.contains($0.processIdentifier) }
        if hideCandidates {
            candidates = []
        }
        lastObservedNewPIDs = candidates.map(\.processIdentifier)
        observedNewPIDs.formUnion(lastObservedNewPIDs)
        if candidates.count > 1 {
            throw HelperError.launchFailed(
                "ambiguous new matching applications; observed_new_pids=\(lastObservedNewPIDs)"
            )
        }
        if let candidate = candidates.first {
            do {
                let candidateIdentity = try identityFromRunningApplication(
                    candidate,
                    expectedBundleIdentifier: expectedBundleIdentifier,
                    expectedExecutablePath: expectedExecutablePath,
                    expectedPID: candidate.processIdentifier
                )
                if candidateIdentity == stableIdentity {
                    if let stableSinceNanoseconds,
                       nowNanoseconds - stableSinceNanoseconds >= 250_000_000 {
                        return candidateIdentity
                    }
                } else {
                    stableIdentity = candidateIdentity
                    stableSinceNanoseconds = nowNanoseconds
                }
            } catch HelperError.processUnavailable {
                disappearedCandidatePIDs.insert(candidate.processIdentifier)
                stableIdentity = nil
                stableSinceNanoseconds = nil
            }
        } else {
            if let stableIdentity {
                disappearedCandidatePIDs.insert(stableIdentity.pid)
            }
            stableIdentity = nil
            stableSinceNanoseconds = nil
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    if let exclusiveReturnedPID {
        throw HelperError.processUnavailable(exclusiveReturnedPID)
    }

    throw HelperError.launchFailed(
        "no unique launched application became identity-ready; "
            + "returned_application={\(launchApplicationSummary(application))}; "
            + "observed_new_pids=\(observedNewPIDs.sorted()); "
            + "last_observed_new_pids=\(lastObservedNewPIDs); "
            + "disappeared_candidate_pids=\(disappearedCandidatePIDs.sorted()); "
            + "the CLI process may have exited before identity capture"
    )
}

private func writeIdentity(_ identity: ProcessIdentity) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(identity))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func loadIdentity(path: String) throws -> ProcessIdentity {
    do {
        return try JSONDecoder().decode(
            ProcessIdentity.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
    } catch {
        throw HelperError.identityArtifactInvalid(String(describing: error))
    }
}

private func recaptureAndVerify(_ expected: ProcessIdentity) throws -> ProcessIdentity {
    let actual = try captureIdentity(
        pid: expected.pid,
        expectedExecutable: expected.executablePath,
        expectedBundleIdentifier: expected.bundleIdentifier.isEmpty ? nil : expected.bundleIdentifier,
        requireRunningApplication: !expected.bundleIdentifier.isEmpty
    )
    guard actual == expected else { throw HelperError.identityMismatch }
    return actual
}

private func verifyReadiness(_ expected: ProcessIdentity) throws {
    let actual = try captureIdentity(
        pid: expected.pid,
        expectedExecutable: expected.executablePath
    )
    guard actual.pid == expected.pid,
          actual.executablePath == expected.executablePath,
          actual.executableDevice == expected.executableDevice,
          actual.executableInode == expected.executableInode,
          actual.startSeconds == expected.startSeconds,
          actual.startMicroseconds == expected.startMicroseconds else {
        throw HelperError.identityMismatch
    }
    guard let runningApplication = NSRunningApplication(processIdentifier: expected.pid) else {
        throw HelperError.runningApplicationUnavailable(expected.pid)
    }
    let actualBundleIdentifier = runningApplication.bundleIdentifier ?? ""

    guard !expected.bundleIdentifier.isEmpty else {
        guard actualBundleIdentifier.isEmpty else { throw HelperError.identityMismatch }
        return
    }
    guard !actualBundleIdentifier.isEmpty else {
        throw HelperError.bundleRegistrationPending(expected.bundleIdentifier)
    }
    guard actualBundleIdentifier == expected.bundleIdentifier else {
        throw HelperError.bundleMismatch(
            expected: expected.bundleIdentifier,
            actual: actualBundleIdentifier
        )
    }
}

private func verifyBootstrapIdentityAllowingPendingBundle(_ expected: ProcessIdentity) throws {
    do {
        try verifyReadiness(expected)
    } catch HelperError.bundleRegistrationPending {
        return
    }
}

private func terminate(
    identity: ProcessIdentity,
    force: Bool,
    allowPendingBundle: Bool = false
) throws {
    if allowPendingBundle {
        try verifyBootstrapIdentityAllowingPendingBundle(identity)
        try verifyBootstrapIdentityAllowingPendingBundle(identity)
    } else {
        _ = try recaptureAndVerify(identity)
        _ = try recaptureAndVerify(identity)
    }
    guard let application = NSRunningApplication(processIdentifier: identity.pid) else {
        throw HelperError.runningApplicationUnavailable(identity.pid)
    }
    let accepted = force ? application.forceTerminate() : application.terminate()
    guard accepted else { throw HelperError.terminationRejected(identity.pid) }
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let action = arguments.first else { throw HelperError.usage }
    switch action {
    case "find-bundle":
        guard arguments.count == 2 else { throw HelperError.usage }
        let processIdentifiers = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == arguments[1] && !$0.isTerminated }
            .map(\.processIdentifier)
            .sorted()
        for processIdentifier in processIdentifiers {
            FileHandle.standardOutput.write(Data("\(processIdentifier)\n".utf8))
        }
    case "identity":
        guard arguments.count == 4, let pid = Int32(arguments[1]) else { throw HelperError.usage }
        let identity = try captureIdentity(
            pid: pid,
            expectedExecutable: arguments[2],
            expectedBundleIdentifier: arguments[3].isEmpty ? nil : arguments[3],
            allowBundleRegistrationDelay: !arguments[3].isEmpty
        )
        try writeIdentity(identity)
    case "launch":
        guard arguments.count >= 4,
              arguments[3] == "--",
              !arguments[2].isEmpty else {
            throw HelperError.usage
        }
        try writeIdentity(try launchApplication(
            appPath: arguments[1],
            expectedBundleIdentifier: arguments[2],
            arguments: Array(arguments.dropFirst(4))
        ))
    case "capture-bootstrap":
        guard arguments.count == 4,
              let pid = Int32(arguments[1]),
              !arguments[3].isEmpty else {
            throw HelperError.usage
        }
        let identity = try captureIdentity(
            pid: pid,
            expectedExecutable: arguments[2],
            expectedBundleIdentifier: arguments[3],
            allowBundleRegistrationDelay: true,
            requireRunningApplication: true
        )
        try writeIdentity(identity)
    case "verify":
        guard arguments.count == 2 else { throw HelperError.usage }
        _ = try recaptureAndVerify(try loadIdentity(path: arguments[1]))
    case "pid":
        guard arguments.count == 2 else { throw HelperError.usage }
        let identity = try loadIdentity(path: arguments[1])
        FileHandle.standardOutput.write(Data("\(identity.pid)\n".utf8))
    case "verify-readiness":
        guard arguments.count == 2 else { throw HelperError.usage }
        try verifyReadiness(try loadIdentity(path: arguments[1]))
    case "terminate":
        guard arguments.count == 2 else { throw HelperError.usage }
        try terminate(identity: try loadIdentity(path: arguments[1]), force: false)
    case "force-terminate":
        guard arguments.count == 2 else { throw HelperError.usage }
        try terminate(identity: try loadIdentity(path: arguments[1]), force: true)
    case "terminate-bootstrap":
        guard arguments.count == 2 else { throw HelperError.usage }
        try terminate(
            identity: try loadIdentity(path: arguments[1]),
            force: false,
            allowPendingBundle: true
        )
    case "force-terminate-bootstrap":
        guard arguments.count == 2 else { throw HelperError.usage }
        try terminate(
            identity: try loadIdentity(path: arguments[1]),
            force: true,
            allowPendingBundle: true
        )
    default:
        throw HelperError.usage
    }
}

do {
    try run()
} catch let error as HelperError {
    FileHandle.standardError.write(Data("\(error.description)\n".utf8))
    switch error {
    case .usage:
        exit(2)
    case .processUnavailable:
        exit(3)
    case .identityMismatch, .executableMismatch, .bundleMismatch:
        exit(4)
    case .runningApplicationUnavailable, .terminationRejected:
        exit(5)
    case .identityArtifactInvalid:
        exit(6)
    case .bundleRegistrationPending:
        exit(8)
    case .applicationRegistrationPending:
        exit(8)
    case .launchFailed:
        exit(9)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(7)
}
