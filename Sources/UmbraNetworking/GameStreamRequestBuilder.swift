import Foundation

public struct LaunchConfiguration: Equatable, Sendable {
    public var appID: Int
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var remoteInputKey: Data
    public var remoteInputKeyID: UInt32
    public var optimizeGameSettings: Bool
    public var playAudioOnHost: Bool
    public var surroundAudioInfo: UInt32
    public var gamepadMask: UInt32
    public var persistGameControllers: Bool
    public var enableHDR: Bool
    public var isNVIDIAServerSoftware: Bool
    public var additionalQueryItems: [URLQueryItem]

    public init(
        appID: Int,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        remoteInputKey: Data,
        remoteInputKeyID: UInt32,
        optimizeGameSettings: Bool,
        playAudioOnHost: Bool,
        surroundAudioInfo: UInt32,
        gamepadMask: UInt32,
        persistGameControllers: Bool,
        enableHDR: Bool,
        isNVIDIAServerSoftware: Bool,
        additionalQueryItems: [URLQueryItem] = []
    ) {
        self.appID = appID
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.remoteInputKey = remoteInputKey
        self.remoteInputKeyID = remoteInputKeyID
        self.optimizeGameSettings = optimizeGameSettings
        self.playAudioOnHost = playAudioOnHost
        self.surroundAudioInfo = surroundAudioInfo
        self.gamepadMask = gamepadMask
        self.persistGameControllers = persistGameControllers
        self.enableHDR = enableHDR
        self.isNVIDIAServerSoftware = isNVIDIAServerSoftware
        self.additionalQueryItems = additionalQueryItems
    }
}

public enum SessionStartKind: String, Sendable {
    case launch
    case resume
}

public protocol GameStreamRequestBuilding: Sendable {
    func serverInfo(address: HostAddress, secure: Bool, fastFail: Bool) throws -> URLRequest
    func applicationList(address: HostAddress) throws -> URLRequest
    func startSession(kind: SessionStartKind, address: HostAddress, configuration: LaunchConfiguration) throws -> URLRequest
    func cancelSession(address: HostAddress) throws -> URLRequest
    func applicationAsset(address: HostAddress, appID: Int) throws -> URLRequest
}

public struct GameStreamRequestBuilder: GameStreamRequestBuilding, Sendable {
    public static let legacyNVIDIAUniqueID = "0123456789ABCDEF"

    public struct Timeouts: Equatable, Sendable {
        public var fastFail: TimeInterval = 2
        public var request: TimeInterval = 5
        public var launch: TimeInterval = 120
        public var resume: TimeInterval = 30
        public var cancel: TimeInterval = 30

        public init() {}
    }

    public var uniqueID: String
    public var useTrueUniqueID: Bool
    public var timeouts: Timeouts
    private let uuidProvider: @Sendable () -> UUID

    public init(
        uniqueID: String,
        useTrueUniqueID: Bool,
        timeouts: Timeouts = Timeouts(),
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.uniqueID = uniqueID
        self.useTrueUniqueID = useTrueUniqueID
        self.timeouts = timeouts
        self.uuidProvider = uuidProvider
    }

    public func serverInfo(address: HostAddress, secure: Bool, fastFail: Bool = false) throws -> URLRequest {
        try request(
            address: address,
            secure: secure,
            command: "serverinfo",
            timeout: fastFail ? timeouts.fastFail : timeouts.request
        )
    }

    public func applicationList(address: HostAddress) throws -> URLRequest {
        try request(address: address, secure: true, command: "applist", timeout: timeouts.request)
    }

    public func startSession(
        kind: SessionStartKind,
        address: HostAddress,
        configuration: LaunchConfiguration
    ) throws -> URLRequest {
        guard configuration.appID > 0,
              configuration.width > 0,
              configuration.height > 0,
              configuration.framesPerSecond > 0,
              !configuration.remoteInputKey.isEmpty
        else {
            throw UmbraNetworkingError.invalidRequest("launch configuration has invalid dimensions, app ID, or input key")
        }

        let fps = configuration.isNVIDIAServerSoftware && configuration.framesPerSecond > 60
            ? 0
            : configuration.framesPerSecond
        var queryItems = [
            URLQueryItem(name: "appid", value: String(configuration.appID)),
            URLQueryItem(name: "mode", value: "\(configuration.width)x\(configuration.height)x\(fps)"),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: configuration.optimizeGameSettings ? "1" : "0"),
            URLQueryItem(name: "rikey", value: configuration.remoteInputKey.hexString),
            URLQueryItem(name: "rikeyid", value: String(configuration.remoteInputKeyID))
        ]
        if configuration.enableHDR {
            queryItems += [
                URLQueryItem(name: "hdrMode", value: "1"),
                URLQueryItem(name: "clientHdrCapVersion", value: "0"),
                URLQueryItem(name: "clientHdrCapSupportedFlagsInUint32", value: "0"),
                URLQueryItem(name: "clientHdrCapMetaDataId", value: "NV_STATIC_METADATA_TYPE_1"),
                URLQueryItem(name: "clientHdrCapDisplayData", value: "0x0x0x0x0x0x0x0x0x0x0")
            ]
        }
        queryItems += [
            URLQueryItem(name: "localAudioPlayMode", value: configuration.playAudioOnHost ? "1" : "0"),
            URLQueryItem(name: "surroundAudioInfo", value: String(configuration.surroundAudioInfo)),
            URLQueryItem(name: "remoteControllersBitmap", value: String(configuration.gamepadMask)),
            URLQueryItem(name: "gcmap", value: String(configuration.gamepadMask)),
            URLQueryItem(name: "gcpersist", value: configuration.persistGameControllers ? "1" : "0"),
            URLQueryItem(name: "corever", value: "1")
        ]
        queryItems += configuration.additionalQueryItems

        return try request(
            address: address,
            secure: true,
            command: kind.rawValue,
            queryItems: queryItems,
            timeout: kind == .launch ? timeouts.launch : timeouts.resume
        )
    }

    public func cancelSession(address: HostAddress) throws -> URLRequest {
        try request(address: address, secure: true, command: "cancel", timeout: timeouts.cancel)
    }

    public func applicationAsset(address: HostAddress, appID: Int) throws -> URLRequest {
        guard appID > 0 else { throw UmbraNetworkingError.invalidRequest("app ID must be positive") }
        return try request(
            address: address,
            secure: true,
            command: "appasset",
            queryItems: [
                URLQueryItem(name: "appid", value: String(appID)),
                URLQueryItem(name: "AssetType", value: "2"),
                URLQueryItem(name: "AssetIdx", value: "0")
            ],
            timeout: timeouts.request
        )
    }

    private func request(
        address: HostAddress,
        secure: Bool,
        command: String,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = address.host.contains(":") && !address.host.hasPrefix("[")
            ? "[\(address.host)]"
            : address.host
        components.port = Int(address.port)
        components.path = "/\(command)"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: useTrueUniqueID ? uniqueID : Self.legacyNVIDIAUniqueID),
            URLQueryItem(name: "uuid", value: uuidProvider().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        ] + queryItems
        guard let url = components.url else {
            throw UmbraNetworkingError.invalidRequest("could not build /\(command) URL")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("close", forHTTPHeaderField: "Connection")
        return request
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
