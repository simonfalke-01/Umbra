import Foundation

public enum HostStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case online
    case offline
}

public enum PairState: String, Codable, CaseIterable, Sendable {
    case unknown
    case paired
    case notPaired
}

public enum HostReachability: String, Codable, CaseIterable, Sendable {
    case unknown
    case lan
    case vpn
}

public struct HostCodecSupport: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let h264 = Self(rawValue: 0x0000_0001)
    public static let hevc = Self(rawValue: 0x0000_0100)
    public static let hevcMain10 = Self(rawValue: 0x0000_0200)
    public static let av1Main8 = Self(rawValue: 0x0001_0000)
    public static let av1Main10 = Self(rawValue: 0x0002_0000)
    public static let h264High8YUV444 = Self(rawValue: 0x0004_0000)
    public static let hevcRext8YUV444 = Self(rawValue: 0x0008_0000)
    public static let hevcRext10YUV444 = Self(rawValue: 0x0010_0000)
    public static let av1High8YUV444 = Self(rawValue: 0x0020_0000)
    public static let av1High10YUV444 = Self(rawValue: 0x0040_0000)
    public static let h264Lossless = Self(rawValue: 0x0080_0000)
    public static let hevcLossless = Self(rawValue: 0x0100_0000)
    public static let av1Lossless = Self(rawValue: 0x0200_0000)

    public static let allH264: Self = [.h264, .h264High8YUV444]
    public static let allHEVC: Self = [.hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444]
    public static let allAV1: Self = [.av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444]
    public static let all10Bit: Self = [.hevcMain10, .hevcRext10YUV444, .av1Main10, .av1High10YUV444]
    public static let allYUV444: Self = [.h264High8YUV444, .hevcRext8YUV444, .hevcRext10YUV444, .av1High8YUV444, .av1High10YUV444]
    public static let allLossless: Self = [.h264Lossless, .hevcLossless, .av1Lossless]
}

public struct StreamApplication: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var hdrSupported: Bool
    public var isAppCollectorGame: Bool
    public var isHidden: Bool
    public var supportsDirectLaunch: Bool

    public init(
        id: Int,
        name: String,
        hdrSupported: Bool = false,
        isAppCollectorGame: Bool = false,
        isHidden: Bool = false,
        supportsDirectLaunch: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hdrSupported = hdrSupported
        self.isAppCollectorGame = isAppCollectorGame
        self.isHidden = isHidden
        self.supportsDirectLaunch = supportsDirectLaunch
    }

    public var isInitialized: Bool { id != 0 && !name.isEmpty }

    public func validate() throws {
        guard id > 0 else {
            throw ModelValidationError(field: "application.id", reason: "must be greater than zero")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "application.name", reason: "must not be empty")
        }
    }
}

public struct StreamHost: Identifiable, Codable, Hashable, Sendable {
    public var id: String { uuid }

    // Persisted host traits.
    public var uuid: String
    public var name: String
    public var hasCustomName: Bool
    public var macAddress: Data
    public var localAddress: NetworkEndpoint?
    public var remoteAddress: NetworkEndpoint?
    public var ipv6Address: NetworkEndpoint?
    public var manualAddress: NetworkEndpoint?
    public var serverCertificate: Data
    public var applications: [StreamApplication]
    public var isNvidiaServerSoftware: Bool

    // Traits refreshed from the host while Umbra is running.
    public var status: HostStatus
    public var pairState: PairState
    public var activeAddress: NetworkEndpoint?
    public var activeHTTPSPort: UInt16?
    public var activeAddressReachability: HostReachability
    public var currentGameID: Int?
    public var gfeVersion: String?
    public var appVersion: String?
    public var displayModes: [DisplayMode]
    public var maxLumaPixelsHEVC: Int
    public var codecSupport: HostCodecSupport
    public var gpuModel: String?
    public var isSupportedServerVersion: Bool

    public init(
        uuid: String,
        name: String,
        hasCustomName: Bool = false,
        macAddress: Data = Data(),
        localAddress: NetworkEndpoint? = nil,
        remoteAddress: NetworkEndpoint? = nil,
        ipv6Address: NetworkEndpoint? = nil,
        manualAddress: NetworkEndpoint? = nil,
        serverCertificate: Data = Data(),
        applications: [StreamApplication] = [],
        isNvidiaServerSoftware: Bool = false,
        status: HostStatus = .unknown,
        pairState: PairState = .unknown,
        activeAddress: NetworkEndpoint? = nil,
        activeHTTPSPort: UInt16? = nil,
        activeAddressReachability: HostReachability = .unknown,
        currentGameID: Int? = nil,
        gfeVersion: String? = nil,
        appVersion: String? = nil,
        displayModes: [DisplayMode] = [],
        maxLumaPixelsHEVC: Int = 0,
        codecSupport: HostCodecSupport = [.h264],
        gpuModel: String? = nil,
        isSupportedServerVersion: Bool = true
    ) {
        self.uuid = uuid
        self.name = name
        self.hasCustomName = hasCustomName
        self.macAddress = macAddress
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.ipv6Address = ipv6Address
        self.manualAddress = manualAddress
        self.serverCertificate = serverCertificate
        self.applications = applications
        self.isNvidiaServerSoftware = isNvidiaServerSoftware
        self.status = status
        self.pairState = pairState
        self.activeAddress = activeAddress
        self.activeHTTPSPort = activeHTTPSPort
        self.activeAddressReachability = activeAddressReachability
        self.currentGameID = currentGameID
        self.gfeVersion = gfeVersion
        self.appVersion = appVersion
        self.displayModes = displayModes.sorted()
        self.maxLumaPixelsHEVC = maxLumaPixelsHEVC
        self.codecSupport = codecSupport
        self.gpuModel = gpuModel
        self.isSupportedServerVersion = isSupportedServerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, name, hasCustomName, macAddress, localAddress, remoteAddress
        case ipv6Address, manualAddress, serverCertificate, applications
        case isNvidiaServerSoftware, status, pairState, activeAddress, activeHTTPSPort
        case activeAddressReachability, currentGameID, gfeVersion, appVersion
        case displayModes, maxLumaPixelsHEVC, codecSupport, gpuModel
        case isSupportedServerVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uuid: try container.decode(String.self, forKey: .uuid),
            name: try container.decode(String.self, forKey: .name),
            hasCustomName: try container.decodeIfPresent(Bool.self, forKey: .hasCustomName) ?? false,
            macAddress: try container.decodeIfPresent(Data.self, forKey: .macAddress) ?? Data(),
            localAddress: try container.decodeIfPresent(NetworkEndpoint.self, forKey: .localAddress),
            remoteAddress: try container.decodeIfPresent(NetworkEndpoint.self, forKey: .remoteAddress),
            ipv6Address: try container.decodeIfPresent(NetworkEndpoint.self, forKey: .ipv6Address),
            manualAddress: try container.decodeIfPresent(NetworkEndpoint.self, forKey: .manualAddress),
            serverCertificate: try container.decodeIfPresent(Data.self, forKey: .serverCertificate) ?? Data(),
            applications: try container.decodeIfPresent([StreamApplication].self, forKey: .applications) ?? [],
            isNvidiaServerSoftware: try container.decodeIfPresent(Bool.self, forKey: .isNvidiaServerSoftware) ?? false,
            status: try container.decodeIfPresent(HostStatus.self, forKey: .status) ?? .unknown,
            pairState: try container.decodeIfPresent(PairState.self, forKey: .pairState) ?? .unknown,
            activeAddress: try container.decodeIfPresent(NetworkEndpoint.self, forKey: .activeAddress),
            activeHTTPSPort: try container.decodeIfPresent(UInt16.self, forKey: .activeHTTPSPort),
            activeAddressReachability: try container.decodeIfPresent(
                HostReachability.self,
                forKey: .activeAddressReachability
            ) ?? .unknown,
            currentGameID: try container.decodeIfPresent(Int.self, forKey: .currentGameID),
            gfeVersion: try container.decodeIfPresent(String.self, forKey: .gfeVersion),
            appVersion: try container.decodeIfPresent(String.self, forKey: .appVersion),
            displayModes: try container.decodeIfPresent([DisplayMode].self, forKey: .displayModes) ?? [],
            maxLumaPixelsHEVC: try container.decodeIfPresent(Int.self, forKey: .maxLumaPixelsHEVC) ?? 0,
            codecSupport: try container.decodeIfPresent(HostCodecSupport.self, forKey: .codecSupport) ?? [.h264],
            gpuModel: try container.decodeIfPresent(String.self, forKey: .gpuModel),
            isSupportedServerVersion: try container.decodeIfPresent(
                Bool.self,
                forKey: .isSupportedServerVersion
            ) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(hasCustomName, forKey: .hasCustomName)
        try container.encode(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(localAddress, forKey: .localAddress)
        try container.encodeIfPresent(remoteAddress, forKey: .remoteAddress)
        try container.encodeIfPresent(ipv6Address, forKey: .ipv6Address)
        try container.encodeIfPresent(manualAddress, forKey: .manualAddress)
        try container.encode(serverCertificate, forKey: .serverCertificate)
        try container.encode(applications, forKey: .applications)
        try container.encode(isNvidiaServerSoftware, forKey: .isNvidiaServerSoftware)
        try container.encode(status, forKey: .status)
        try container.encode(pairState, forKey: .pairState)
        try container.encodeIfPresent(activeAddress, forKey: .activeAddress)
        try container.encodeIfPresent(activeHTTPSPort, forKey: .activeHTTPSPort)
        try container.encode(activeAddressReachability, forKey: .activeAddressReachability)
        try container.encodeIfPresent(currentGameID, forKey: .currentGameID)
        try container.encodeIfPresent(gfeVersion, forKey: .gfeVersion)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encode(displayModes, forKey: .displayModes)
        try container.encode(maxLumaPixelsHEVC, forKey: .maxLumaPixelsHEVC)
        try container.encode(codecSupport, forKey: .codecSupport)
        try container.encodeIfPresent(gpuModel, forKey: .gpuModel)
        try container.encode(isSupportedServerVersion, forKey: .isSupportedServerVersion)
    }

    public var visibleApplications: [StreamApplication] {
        applications.filter { !$0.isHidden }
    }

    public var uniqueAddresses: [NetworkEndpoint] {
        var seen = Set<NetworkEndpoint>()
        return [activeAddress, localAddress, remoteAddress, ipv6Address, manualAddress]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    public func validate() throws {
        guard !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "host.uuid", reason: "must not be empty")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "host.name", reason: "must not be empty")
        }
        guard macAddress.isEmpty || macAddress.count == 6 else {
            throw ModelValidationError(field: "host.macAddress", reason: "must be empty or exactly 6 bytes")
        }
        if let activeHTTPSPort, activeHTTPSPort == 0 {
            throw ModelValidationError(field: "host.activeHTTPSPort", reason: "must be between 1 and 65535")
        }
        for address in uniqueAddresses {
            try address.validate()
        }
        var applicationIDs = Set<Int>()
        for application in applications {
            try application.validate()
            guard applicationIDs.insert(application.id).inserted else {
                throw ModelValidationError(field: "host.applications", reason: "contains duplicate application id \(application.id)")
            }
        }
        for displayMode in displayModes {
            try displayMode.validate()
        }
        guard maxLumaPixelsHEVC >= 0 else {
            throw ModelValidationError(field: "host.maxLumaPixelsHEVC", reason: "must not be negative")
        }
    }
}
