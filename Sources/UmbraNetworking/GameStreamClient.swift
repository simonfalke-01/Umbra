import Foundation

public protocol ServerInfoFetching: Sendable {
    func fetchServerInfo() async throws -> ServerInfo
}

public protocol GameStreamServing: Sendable {
    func fetchServerInfo(address: HostAddress, secure: Bool, fastFail: Bool) async throws -> ServerInfo
    func fetchApplications(address: HostAddress) async throws -> [GameStreamApp]
    func startSession(kind: SessionStartKind, address: HostAddress, configuration: LaunchConfiguration) async throws -> LaunchResponse
    func cancelSession(address: HostAddress) async throws
    func fetchApplicationAsset(address: HostAddress, appID: Int) async throws -> Data
}

public struct GameStreamClient: GameStreamServing, Sendable {
    private let transport: any HTTPTransport
    private let requestBuilder: any GameStreamRequestBuilding
    private let parser: GameStreamXMLParser

    public init(
        transport: any HTTPTransport,
        requestBuilder: any GameStreamRequestBuilding,
        parser: GameStreamXMLParser = GameStreamXMLParser()
    ) {
        self.transport = transport
        self.requestBuilder = requestBuilder
        self.parser = parser
    }

    public func fetchServerInfo(
        address: HostAddress,
        secure: Bool,
        fastFail: Bool = false
    ) async throws -> ServerInfo {
        let request = try requestBuilder.serverInfo(address: address, secure: secure, fastFail: fastFail)
        return try parser.parseServerInfo(try await responseData(for: request))
    }

    public func fetchApplications(address: HostAddress) async throws -> [GameStreamApp] {
        let request = try requestBuilder.applicationList(address: address)
        return try parser.parseApplicationList(try await responseData(for: request))
    }

    public func startSession(
        kind: SessionStartKind,
        address: HostAddress,
        configuration: LaunchConfiguration
    ) async throws -> LaunchResponse {
        let request = try requestBuilder.startSession(kind: kind, address: address, configuration: configuration)
        return try parser.parseLaunchResponse(try await responseData(for: request))
    }

    public func cancelSession(address: HostAddress) async throws {
        let request = try requestBuilder.cancelSession(address: address)
        try parser.verifyResponse(try await responseData(for: request))
    }

    public func fetchApplicationAsset(address: HostAddress, appID: Int) async throws -> Data {
        let request = try requestBuilder.applicationAsset(address: address, appID: appID)
        return try await responseData(for: request)
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw UmbraNetworkingError.httpStatus(response.statusCode)
        }
        return data
    }
}

public struct BoundServerInfoFetcher: ServerInfoFetching, Sendable {
    private let client: any GameStreamServing
    private let address: HostAddress
    private let secure: Bool
    private let fastFail: Bool

    public init(client: any GameStreamServing, address: HostAddress, secure: Bool, fastFail: Bool = true) {
        self.client = client
        self.address = address
        self.secure = secure
        self.fastFail = fastFail
    }

    public func fetchServerInfo() async throws -> ServerInfo {
        try await client.fetchServerInfo(address: address, secure: secure, fastFail: fastFail)
    }
}
