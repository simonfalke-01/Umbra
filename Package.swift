// swift-tools-version: 6.0

import PackageDescription
import Foundation

let releaseDependencyPrefix = ProcessInfo.processInfo.environment["UMBRA_RELEASE_DEPS_PREFIX"]
let releaseCSettings: [CSetting] = releaseDependencyPrefix.map { prefix in
    [.unsafeFlags(["-I\(prefix)/include", "-I\(prefix)/include/opus"])]
} ?? []
let releaseSwiftSettings: [SwiftSetting] = releaseDependencyPrefix.map { prefix in
    [.unsafeFlags(["-Xcc", "-I\(prefix)/include", "-Xcc", "-I\(prefix)/include/opus"])]
} ?? []
let releaseStaticLinkerSettings: [LinkerSetting] = releaseDependencyPrefix.map { prefix in
    [
        .unsafeFlags([
            "-L\(prefix)/lib",
            "-Xlinker", "-force_load",
            "-Xlinker", "\(prefix)/lib/libopus.a",
            "-Xlinker", "-force_load",
            "-Xlinker", "\(prefix)/lib/libcrypto.a",
            "-Xlinker", "-dead_strip_dylibs",
        ])
    ]
} ?? []
let package = Package(
    name: "Umbra",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Umbra", targets: ["UmbraApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "COpenSSL",
            path: "Vendor/COpenSSL",
            pkgConfig: releaseDependencyPrefix == nil ? "libcrypto" : nil,
            providers: releaseDependencyPrefix == nil ? [
                .brew(["openssl@3"]),
            ] : []
        ),
        .systemLibrary(
            name: "COpus",
            path: "Vendor/COpus",
            pkgConfig: releaseDependencyPrefix == nil ? "opus" : nil,
            providers: releaseDependencyPrefix == nil ? [
                .brew(["opus"]),
            ] : []
        ),
        .target(
            name: "UmbraCore",
            path: "Sources/UmbraCore"
        ),
        .target(
            name: "UmbraNetworking",
            path: "Sources/UmbraNetworking"
        ),
        .target(
            name: "UmbraPairing",
            dependencies: ["UmbraNetworking"],
            path: "Sources/UmbraPairing"
        ),
        .target(
            name: "UmbraCLI",
            dependencies: ["UmbraCore"],
            path: "Sources/UmbraCLI"
        ),
        .target(
            name: "UmbraPlatform",
            path: "Sources/UmbraPlatform"
        ),
        .target(
            name: "UmbraDiagnostics",
            path: "Sources/UmbraDiagnostics"
        ),
        .target(
            name: "UmbraServices",
            dependencies: ["UmbraCore", "UmbraNetworking"],
            path: "Sources/UmbraServices"
        ),
        .target(
            name: "CMoonlightBridge",
            dependencies: ["COpenSSL"],
            path: "Vendor/MoonlightCommon",
            sources: [
                "Facade/src/UmbraClientMicrophoneRTSPExtension.c",
                "Facade/src/UmbraOptimizationModeRTSPExtension.c",
                "Facade/src/UmbraRequiredCallbacks.c",
                "Facade/src/UmbraStreamingBridge.c",
                "Upstream/src",
                "Upstream/enet/callbacks.c",
                "Upstream/enet/compress.c",
                "Upstream/enet/host.c",
                "Upstream/enet/list.c",
                "Upstream/enet/packet.c",
                "Upstream/enet/peer.c",
                "Upstream/enet/protocol.c",
                "Upstream/enet/unix.c",
                "Upstream/nanors/rs.c",
                "Upstream/nanors/deps/obl/oblas_common.c",
                "Upstream/nanors/deps/obl/oblas_lite.c",
            ],
            publicHeadersPath: "Facade/include",
            cSettings: [
                .headerSearchPath("Upstream/src"),
                .headerSearchPath("Upstream/enet/include"),
                .headerSearchPath("Upstream/nanors"),
                .headerSearchPath("Upstream/nanors/deps"),
                .headerSearchPath("Upstream/nanors/deps/obl"),
                .define("HAS_SOCKLEN_T", to: "1"),
                .define("__APPLE_USE_RFC_3542", to: "1"),
            ] + releaseCSettings
        ),
        .target(
            name: "UmbraStreaming",
            dependencies: ["CMoonlightBridge"],
            path: "Sources/UmbraStreaming"
        ),
        .target(
            name: "UmbraMedia",
            dependencies: ["COpus"],
            path: "Sources/UmbraMedia",
            swiftSettings: releaseSwiftSettings
        ),
        .target(
            name: "UmbraOpus",
            dependencies: ["UmbraMedia", "COpus"],
            path: "Sources/UmbraOpus",
            swiftSettings: releaseSwiftSettings
        ),
        .target(
            name: "UmbraMicrophone",
            dependencies: ["COpenSSL", "COpus", "UmbraOpus"],
            path: "Sources/UmbraMicrophone",
            swiftSettings: releaseSwiftSettings
        ),
        .target(
            name: "UmbraQUICTransport",
            path: "Sources/UmbraQUICTransport"
        ),
        .target(
            name: "UmbraProtocolV3",
            dependencies: ["UmbraQUICTransport"],
            path: "Sources/UmbraProtocolV3",
        ),
        .target(
            name: "UmbraIntegration",
            dependencies: [
                "UmbraCore",
                "UmbraNetworking",
                "UmbraPairing",
                "UmbraServices",
                "UmbraStreaming",
                "UmbraPlatform",
                "UmbraMedia",
                "UmbraOpus",
                "UmbraMicrophone",
                "UmbraProtocolV3",
                "UmbraQUICTransport",
            ],
            path: "Sources/UmbraIntegration"
        ),
        .target(
            name: "UmbraCLIExecution",
            dependencies: ["UmbraCLI", "UmbraCore", "UmbraServices"],
            path: "Sources/UmbraCLIExecution"
        ),
        .executableTarget(
            name: "UmbraApp",
            dependencies: [
                "UmbraCore",
                "UmbraNetworking",
                "UmbraPairing",
                "UmbraServices",
                "UmbraIntegration",
                "UmbraPlatform",
                "UmbraMedia",
                "UmbraOpus",
                "UmbraCLI",
                "UmbraCLIExecution",
                "UmbraDiagnostics",
                "UmbraMicrophone",
                "UmbraProtocolV3",
                "UmbraQUICTransport",
            ],
            path: "Sources/UmbraApp",
            exclude: [
                "Resources/InfoPlist.xcstrings",
                "Resources/Localizable.xcstrings",
            ],
            resources: [
                .process("Resources/en.lproj"),
            ],
            linkerSettings: releaseStaticLinkerSettings
        ),
        .testTarget(
            name: "UmbraCoreTests",
            dependencies: ["UmbraCore"],
            path: "Tests/UmbraCoreTests"
        ),
        .testTarget(
            name: "UmbraNetworkingTests",
            dependencies: ["UmbraNetworking"],
            path: "Tests/UmbraNetworkingTests"
        ),
        .testTarget(
            name: "UmbraPairingTests",
            dependencies: ["UmbraPairing", "UmbraNetworking"],
            path: "Tests/UmbraPairingTests"
        ),
        .testTarget(
            name: "UmbraPlatformTests",
            dependencies: ["UmbraPlatform"],
            path: "Tests/UmbraPlatformTests"
        ),
        .testTarget(
            name: "UmbraCLITests",
            dependencies: ["UmbraCLI", "UmbraCore"],
            path: "Tests/UmbraCLITests"
        ),
        .testTarget(
            name: "UmbraDiagnosticsTests",
            dependencies: ["UmbraDiagnostics"],
            path: "Tests/UmbraDiagnosticsTests"
        ),
        .testTarget(
            name: "UmbraServicesTests",
            dependencies: ["UmbraServices", "UmbraCore", "UmbraNetworking"],
            path: "Tests/UmbraServicesTests"
        ),
        .testTarget(
            name: "UmbraMediaTests",
            dependencies: ["UmbraMedia"],
            path: "Tests/UmbraMediaTests"
        ),
        .testTarget(
            name: "UmbraOpusTests",
            dependencies: ["UmbraOpus", "COpus"],
            path: "Tests/UmbraOpusTests"
        ),
        .testTarget(
            name: "UmbraMicrophoneTests",
            dependencies: ["UmbraMicrophone", "UmbraOpus", "COpenSSL"],
            path: "Tests/UmbraMicrophoneTests",
            swiftSettings: releaseSwiftSettings
        ),
        .testTarget(
            name: "UmbraQUICTransportTests",
            dependencies: ["UmbraQUICTransport"],
            path: "Tests/UmbraQUICTransportTests"
        ),
        .testTarget(
            name: "UmbraProtocolV3Tests",
            dependencies: ["UmbraProtocolV3", "UmbraQUICTransport"],
            path: "Tests/UmbraProtocolV3Tests",
        ),
        .testTarget(
            name: "UmbraIntegrationTests",
            dependencies: [
                "UmbraIntegration",
                "UmbraCore",
                "UmbraNetworking",
                "UmbraPairing",
                "UmbraServices",
                "UmbraStreaming",
                "UmbraPlatform",
                "UmbraMedia",
                "UmbraOpus",
                "UmbraMicrophone",
                "UmbraProtocolV3",
                "UmbraQUICTransport",
            ],
            path: "Tests/UmbraIntegrationTests"
        ),
        .testTarget(
            name: "UmbraCLIExecutionTests",
            dependencies: [
                "UmbraCLIExecution",
                "UmbraCLI",
                "UmbraCore",
                "UmbraServices",
            ],
            path: "Tests/UmbraCLIExecutionTests"
        ),
        .testTarget(
            name: "UmbraAppTests",
            dependencies: ["UmbraApp", "UmbraCore", "UmbraMedia", "UmbraProtocolV3"],
            path: "Tests/UmbraAppTests"
        ),
    ]
)
