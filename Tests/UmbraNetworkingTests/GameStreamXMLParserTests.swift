import Foundation
import XCTest
@testable import UmbraNetworking

final class GameStreamXMLParserTests: XCTestCase {
    private let parser = GameStreamXMLParser()

    func testParsesServerInfoAndGameStreamBusyGameSemantics() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200" status_message="OK">
          <hostname>Studio Mac</hostname>
          <uniqueid>host-123</uniqueid>
          <mac>AA:BB:CC:DD:EE:FF</mac>
          <LocalIP>192.168.1.20</LocalIP>
          <ExternalIP>203.0.113.4</ExternalIP>
          <HttpsPort>48084</HttpsPort>
          <ExternalPort>48089</ExternalPort>
          <PairStatus>1</PairStatus>
          <currentgame>42</currentgame>
          <state>MJOLNIR_SERVER_BUSY</state>
          <appversion>7.1.431</appversion>
          <GfeVersion>3.28.0.417</GfeVersion>
          <gputype>Apple GPU</gputype>
          <ServerCodecModeSupport>259</ServerCodecModeSupport>
          <MaxLumaPixelsHEVC>8294400</MaxLumaPixelsHEVC>
          <SupportedDisplayMode><DisplayMode><Width>3840</Width><Height>2160</Height><RefreshRate>120</RefreshRate></DisplayMode></SupportedDisplayMode>
          <SupportedDisplayMode><DisplayMode><Width>1920</Width><Height>1080</Height><RefreshRate>60</RefreshRate></DisplayMode></SupportedDisplayMode>
        </root>
        """.utf8)

        let info = try parser.parseServerInfo(xml)

        XCTAssertEqual(info.name, "Studio Mac")
        XCTAssertEqual(info.uniqueID, "host-123")
        XCTAssertEqual(info.macAddress, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        XCTAssertEqual(info.httpsPort, 48_084)
        XCTAssertEqual(info.externalPort, 48_089)
        XCTAssertEqual(info.pairState, .paired)
        XCTAssertEqual(info.currentGameID, 42)
        XCTAssertEqual(info.serverCodecModeSupport, 259)
        XCTAssertEqual(info.maxLumaPixelsHEVC, 8_294_400)
        XCTAssertTrue(info.isNVIDIAServerSoftware)
        XCTAssertEqual(info.displayModes.map(\.width), [1920, 3840])
    }

    func testClearsStaleCurrentGameWhenServerIsNotBusyAndUsesDefaults() throws {
        let data = Data("""
        <root status_code="200"><hostname></hostname><uniqueid>x</uniqueid><currentgame>9</currentgame><state>LUMEN_SERVER_FREE</state><PairStatus>0</PairStatus></root>
        """.utf8)
        let info = try parser.parseServerInfo(data)

        XCTAssertEqual(info.name, "UNKNOWN")
        XCTAssertEqual(info.currentGameID, 0)
        XCTAssertEqual(info.httpsPort, HostAddress.defaultHTTPSPort)
        XCTAssertEqual(info.serverCodecModeSupport, 1)
        XCTAssertEqual(info.pairState, .notPaired)
    }

    func testBusyStatePreservesCurrentGameWhenHostIsUnpaired() throws {
        let data = Data("""
        <root status_code="200">
          <hostname>Host</hostname>
          <uniqueid>host-1</uniqueid>
          <currentgame>42</currentgame>
          <state>LUMEN_SERVER_BUSY</state>
          <PairStatus>0</PairStatus>
        </root>
        """.utf8)

        let info = try parser.parseServerInfo(data)

        XCTAssertEqual(info.currentGameID, 42)
        XCTAssertEqual(info.pairState, .notPaired)
    }

    func testParsesApplicationListIncludingEmptyLumenTitle() throws {
        let data = Data("""
        <root status_code="200" status_message="OK">
          <App><AppTitle>Desktop</AppTitle><ID>1</ID><IsHdrSupported>1</IsHdrSupported><IsAppCollectorGame>0</IsAppCollectorGame></App>
          <App><AppTitle/><ID>2</ID><IsHdrSupported>0</IsHdrSupported><IsAppCollectorGame>1</IsAppCollectorGame></App>
        </root>
        """.utf8)

        XCTAssertEqual(try parser.parseApplicationList(data), [
            GameStreamApp(id: 1, name: "Desktop", supportsHDR: true),
            GameStreamApp(id: 2, name: "", isAppCollectorGame: true)
        ])
    }

    func testRejectsInvalidApplicationAndPropagatesGameStreamStatus() throws {
        XCTAssertThrowsError(try parser.parseApplicationList(Data("<root status_code=\"200\"><App><AppTitle>Bad</AppTitle><ID>0</ID></App></root>".utf8))) {
            XCTAssertEqual($0 as? UmbraNetworkingError, .invalidApplication("missing or zero ID"))
        }

        XCTAssertThrowsError(try parser.verifyResponse(Data("<root status_code=\"401\" status_message=\"Not paired\"/>".utf8))) {
            XCTAssertEqual($0 as? UmbraNetworkingError, .serverResponse(statusCode: 401, message: "Not paired"))
        }
    }

    func testMapsUnsignedMinusOneAudioCaptureFailure() throws {
        XCTAssertThrowsError(try parser.verifyResponse(Data("<root status_code=\"4294967295\" status_message=\"Invalid\"/>".utf8))) {
            guard case .serverResponse(let code, let message) = $0 as? UmbraNetworkingError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(code, 418)
            XCTAssertTrue(message.contains("audio capture"))
        }
    }
}
