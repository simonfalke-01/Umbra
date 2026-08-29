import Darwin
import Dispatch
import Foundation
import UmbraAWDL

@main
struct UmbraAWDLHelperMain {
    static func main() async {
        guard getuid() == 0 else {
            FileHandle.standardError.write(Data("UmbraAWDLHelper must run as root.\n".utf8))
            exit(EXIT_FAILURE)
        }

        let stateMachine = AWDLLeaseStateMachine(
            interface: AWDLSystemInterfaceController(),
            persistence: AWDLJSONLeaseStore()
        )
        while true {
            do {
                try await stateMachine.recoverPersistedLease()
                break
            } catch {
                FileHandle.standardError.write(
                    Data("AWDL crash restoration retry: \(error.localizedDescription)\n".utf8)
                )
                try? await Task.sleep(for: .seconds(1))
            }
        }

        do {
            let daemon = try AWDLPrivilegedHelperDaemon(stateMachine: stateMachine)
            daemon.activate()
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                termination.setEventHandler {
                    Task {
                        while true {
                            do {
                                try await stateMachine.recoverPersistedLease()
                                continuation.resume()
                                return
                            } catch {
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                        }
                    }
                }
                termination.resume()
            }
            _ = daemon
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
