import Darwin
import AppKit
import SwiftUI
import UmbraCLI
import UmbraServices

@MainActor
final class UmbraApplicationDelegate: NSObject, NSApplicationDelegate {
    typealias StopBarrier = @MainActor @Sendable () async -> Void
    typealias TerminationReply = @MainActor @Sendable (Bool) -> Void

    private enum TerminationState: Equatable {
        case idle
        case stopping
        case replied
    }

    var stopBarrier: StopBarrier = {}
    private var terminationState = TerminationState.idle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func requestTermination(
        reply: @escaping TerminationReply
    ) -> NSApplication.TerminateReply {
        switch terminationState {
        case .idle:
            terminationState = .stopping
            let stopBarrier = stopBarrier
            Task { @MainActor [weak self] in
                await stopBarrier()
                guard let self, self.terminationState == .stopping else { return }
                self.terminationState = .replied
                reply(true)
            }
            return .terminateLater
        case .stopping:
            return .terminateLater
        case .replied:
            return .terminateNow
        }
    }
}

@main
struct UmbraApp: App {
    @NSApplicationDelegateAdaptor(UmbraApplicationDelegate.self) private var applicationDelegate
    @StateObject private var store: AppStore
    private let composition: LiveApplicationComposition?

    init() {
        let launchRequest = UmbraBootstrap.resolveLaunchRequest()
        let terminateAfterStream: Bool
        let requestedIntent: SessionIntent?
        switch launchRequest {
        case .launchApplication:
            terminateAfterStream = false
            requestedIntent = nil
        case let .stream(intent):
            terminateAfterStream = true
            requestedIntent = intent
        }
        do {
            let composition = try LiveApplicationComposition()
            self.composition = composition
            let store = AppStore(
                service: composition.clientService,
                preferences: composition.preferences
            )
            _store = StateObject(wrappedValue: store)
            applicationDelegate.stopBarrier = { [weak composition] in
                await composition?.stopForApplicationTermination()
            }
            if terminateAfterStream {
                composition.clientService.onSessionTerminated = { succeeded in
                    exit(succeeded ? CLIExitCode.success.rawValue : CLIExitCode.failure.rawValue)
                }
            }
            if var intent = requestedIntent {
                let runtimeResolution = composition.runtimePreferenceResolver.resolveForStreaming(
                    intent.preferences,
                    uiScreen: NSApp.keyWindow?.screen
                )
                intent = runtimeResolution.applying(to: intent)
                composition.supportLog?.record(
                    source: "Application",
                    level: .info,
                    message: "Starting requested \(intent.kind.rawValue) stream for host \(intent.hostID), application \(intent.applicationID)."
                )
                Task { @MainActor [weak store] in
                    composition.supportLog?.record(
                        source: "Application",
                        level: .debug,
                        message: "The initial streaming task started."
                    )
                    do {
                        await composition.clientService.waitUntilReady()
                        _ = try await composition.applicationService.beginSession(intent)
                        composition.supportLog?.record(
                            source: "Application",
                            level: .info,
                            message: "The requested streaming session was accepted."
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        composition.supportLog?.record(
                            source: "Application",
                            level: .error,
                            message: "The requested streaming session failed: \(error.localizedDescription)"
                        )
                        if terminateAfterStream { exit(CLIExitCode.failure.rawValue) }
                        store?.failure = PresentedFailure(
                            title: "Couldn’t Start Stream",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        } catch {
            if terminateAfterStream {
                if let data = "\(error.localizedDescription)\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                exit(CLIExitCode.failure.rawValue)
            }
            composition = nil
            _store = StateObject(wrappedValue: AppStore(service: UnavailableUmbraClientService()))
        }
    }

    var body: some Scene {
        WindowGroup("Umbra") {
            RootView(store: store)
        }
        .defaultSize(width: 1_040, height: 720)
        .commands {
            UmbraCommands(supportLog: composition?.supportLog)
        }

        Settings {
            UmbraSettingsView(preferences: store.preferences)
        }
    }

}
