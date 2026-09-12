import Foundation
import PackagePlugin

@main
struct CLSPCoreSyncPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // SwiftPM does not inherit the plugin process environment when running
        // this command. Forward only the checker's explicit checkout selection.
        var environment: [String: String] = [:]
        if let checkout = ProcessInfo.processInfo.environment["PHOTON_REPOSITORY"],
           !checkout.isEmpty {
            environment["PHOTON_REPOSITORY"] = checkout
        }
        return [
            .prebuildCommand(
                displayName: "Verify pinned Photon portable core",
                executable: context.package.directoryURL.appending(path: "Scripts/sync-lsp-core.sh"),
                arguments: ["--check"],
                environment: environment,
                outputFilesDirectory: context.pluginWorkDirectoryURL.appending(path: "CLSPCoreSync")
            ),
        ]
    }
}
