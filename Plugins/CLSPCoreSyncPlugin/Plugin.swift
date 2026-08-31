import PackagePlugin

@main
struct CLSPCoreSyncPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        [
            .prebuildCommand(
                displayName: "Verify pinned Photon portable core",
                executable: context.package.directoryURL.appending(path: "Scripts/sync-lsp-core.sh"),
                arguments: ["--check"],
                outputFilesDirectory: context.pluginWorkDirectoryURL.appending(path: "CLSPCoreSync")
            ),
        ]
    }
}
