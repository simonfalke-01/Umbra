import Foundation
import XCTest
@testable import UmbraNetworking

final class GameStreamRequestBuilderTests: XCTestCase {
    private let fixedUUID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

    func testBuildsServerInfoAndAssetURLsWithIdentityContract() throws {
        let builder = GameStreamRequestBuilder(
            uniqueID: "real-id",
            useTrueUniqueID: false,
            uuidProvider: { UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")! }
        )
        let address = HostAddress(host: "2001:db8::10", port: 47_984)

        let info = try builder.serverInfo(address: address, secure: true, fastFail: true)
        XCTAssertEqual(info.url?.scheme, "https")
        XCTAssertEqual(info.url?.host, "2001:db8::10")
        XCTAssertEqual(info.url?.port, 47_984)
        XCTAssertEqual(info.url?.path, "/serverinfo")
        XCTAssertEqual(info.timeoutInterval, 2)
        XCTAssertEqual(query(info)["uniqueid"], "0123456789ABCDEF")
        XCTAssertEqual(query(info)["uuid"], fixedUUID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())

        let asset = try builder.applicationAsset(address: address, appID: 7)
        XCTAssertEqual(asset.url?.path, "/appasset")
        XCTAssertEqual(query(asset)["appid"], "7")
        XCTAssertEqual(query(asset)["AssetType"], "2")
        XCTAssertEqual(query(asset)["AssetIdx"], "0")
    }

    func testBuildsCompleteLaunchURLAndAppliesGFEHighFPSWorkaround() throws {
        let builder = GameStreamRequestBuilder(
            uniqueID: "true-client-id",
            useTrueUniqueID: true,
            uuidProvider: { UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")! }
        )
        let configuration = LaunchConfiguration(
            appID: 42,
            width: 3840,
            height: 2160,
            framesPerSecond: 120,
            remoteInputKey: Data([0, 1, 2, 0xFE, 0xFF]),
            remoteInputKeyID: 4_294_967_000,
            optimizeGameSettings: true,
            playAudioOnHost: false,
            surroundAudioInfo: 196_611,
            gamepadMask: 5,
            persistGameControllers: true,
            enableHDR: true,
            isNVIDIAServerSoftware: true,
            additionalQueryItems: [URLQueryItem(name: "clientFeature", value: "value")]
        )

        let request = try builder.startSession(
            kind: .launch,
            address: HostAddress(host: "sunshine.local", port: 47_984),
            configuration: configuration
        )
        let values = query(request)

        XCTAssertEqual(request.url?.path, "/launch")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(values["uniqueid"], "true-client-id")
        XCTAssertEqual(values["mode"], "3840x2160x0")
        XCTAssertEqual(values["rikey"], "000102feff")
        XCTAssertEqual(values["rikeyid"], "4294967000")
        XCTAssertEqual(values["hdrMode"], "1")
        XCTAssertEqual(values["remoteControllersBitmap"], "5")
        XCTAssertEqual(values["gcmap"], "5")
        XCTAssertEqual(values["gcpersist"], "1")
        XCTAssertEqual(values["corever"], "1")
        XCTAssertEqual(values["clientFeature"], "value")
    }

    func testBuildsResumeCancelAndApplicationListCommands() throws {
        let builder = GameStreamRequestBuilder(
            uniqueID: "id",
            useTrueUniqueID: true,
            uuidProvider: { UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")! }
        )
        let address = HostAddress(host: "host", port: 47_984)
        let configuration = LaunchConfiguration(
            appID: 1,
            width: 1920,
            height: 1080,
            framesPerSecond: 60,
            remoteInputKey: Data(repeating: 1, count: 16),
            remoteInputKeyID: 10,
            optimizeGameSettings: false,
            playAudioOnHost: true,
            surroundAudioInfo: 2,
            gamepadMask: 0,
            persistGameControllers: false,
            enableHDR: false,
            isNVIDIAServerSoftware: false
        )

        XCTAssertEqual(try builder.applicationList(address: address).url?.path, "/applist")
        XCTAssertEqual(try builder.cancelSession(address: address).url?.path, "/cancel")
        let resume = try builder.startSession(kind: .resume, address: address, configuration: configuration)
        XCTAssertEqual(resume.url?.path, "/resume")
        XCTAssertEqual(resume.timeoutInterval, 30)
        XCTAssertEqual(query(resume)["mode"], "1920x1080x60")
        XCTAssertEqual(query(resume)["corever"], "1")
    }

    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }
}
