import Foundation

public struct GameStreamXMLParser: Sendable {
    public init() {}

    public func verifyResponse(_ data: Data) throws {
        let root = try parseDocument(data)
        try verifyStatus(root)
    }

    public func parseServerInfo(_ data: Data) throws -> ServerInfo {
        let root = try parseDocument(data)
        try verifyStatus(root)

        let state = root.text(named: "state") ?? ""
        let reportedGame = Int(root.text(named: "currentgame") ?? "0") ?? 0
        let currentGame = state.hasSuffix("_SERVER_BUSY") ? reportedGame : 0
        let httpsPort = UInt16(root.text(named: "HttpsPort") ?? "") ?? HostAddress.defaultHTTPSPort
        let codecSupport = Int(root.text(named: "ServerCodecModeSupport") ?? "") ?? 1
        let mac = try parseMACIfPresent(root.text(named: "mac"))

        let modes = root.descendants(named: "DisplayMode").compactMap { node -> DisplayMode? in
            guard
                let width = Int(node.text(named: "Width") ?? ""),
                let height = Int(node.text(named: "Height") ?? ""),
                let refreshRate = Int(node.text(named: "RefreshRate") ?? "")
            else { return nil }
            return DisplayMode(width: width, height: height, refreshRate: refreshRate)
        }.sorted {
            Int64($0.width) * Int64($0.height) * Int64($0.refreshRate)
                < Int64($1.width) * Int64($1.height) * Int64($1.refreshRate)
        }

        let localAddress = nonempty(root.text(named: "LocalIP")).flatMap {
            $0.hasPrefix("127.") ? nil : $0
        }

        return ServerInfo(
            name: nonempty(root.text(named: "hostname")) ?? "UNKNOWN",
            uniqueID: root.text(named: "uniqueid") ?? "",
            macAddress: mac,
            localAddress: localAddress,
            externalAddress: nonempty(root.text(named: "ExternalIP")),
            httpsPort: httpsPort == 0 ? HostAddress.defaultHTTPSPort : httpsPort,
            externalPort: UInt16(root.text(named: "ExternalPort") ?? ""),
            pairState: root.text(named: "PairStatus") == "1" ? .paired : .notPaired,
            currentGameID: currentGame,
            state: state,
            appVersion: root.text(named: "appversion") ?? "",
            gfeVersion: nonempty(root.text(named: "GfeVersion")),
            gpuModel: nonempty(root.text(named: "gputype")),
            serverCodecModeSupport: codecSupport,
            maxLumaPixelsHEVC: Int(root.text(named: "MaxLumaPixelsHEVC") ?? "") ?? 0,
            displayModes: modes,
            isNVIDIAServerSoftware: state.contains("MJOLNIR")
        )
    }

    public func parseApplicationList(_ data: Data) throws -> [GameStreamApp] {
        let root = try parseDocument(data)
        try verifyStatus(root)

        return try root.descendants(named: "App").map { node in
            guard let id = Int(node.text(named: "ID") ?? ""), id != 0 else {
                throw UmbraNetworkingError.invalidApplication("missing or zero ID")
            }
            guard let titleNode = node.firstDescendant(named: "AppTitle") else {
                throw UmbraNetworkingError.invalidApplication("missing title for app \(id)")
            }
            return GameStreamApp(
                id: id,
                name: titleNode.text.trimmingCharacters(in: .whitespacesAndNewlines),
                supportsHDR: node.text(named: "IsHdrSupported") == "1",
                isAppCollectorGame: node.text(named: "IsAppCollectorGame") == "1"
            )
        }
    }

    public func parseLaunchResponse(_ data: Data) throws -> LaunchResponse {
        let root = try parseDocument(data)
        try verifyStatus(root)
        return LaunchResponse(sessionURL: root.text(named: "sessionUrl0").flatMap(URL.init(string:)))
    }

    private func parseDocument(_ data: Data) throws -> XMLNode {
        let delegate = TreeParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw UmbraNetworkingError.malformedXML(parser.parserError?.localizedDescription ?? "unknown parser error")
        }
        guard let root = delegate.root, root.name == "root" else {
            throw UmbraNetworkingError.missingRootElement
        }
        return root
    }

    private func verifyStatus(_ root: XMLNode) throws {
        guard let rawStatus = root.attributes["status_code"] else {
            throw UmbraNetworkingError.malformedXML("root has no status_code attribute")
        }
        let statusCode: Int
        if let unsigned = UInt32(rawStatus) {
            statusCode = Int(Int32(bitPattern: unsigned))
        } else if let signed = Int(rawStatus) {
            statusCode = signed
        } else {
            throw UmbraNetworkingError.malformedXML("invalid status_code \(rawStatus)")
        }
        guard statusCode == 200 else {
            let message = root.attributes["status_message"] ?? ""
            if statusCode == -1, message == "Invalid" {
                throw UmbraNetworkingError.serverResponse(
                    statusCode: 418,
                    message: "Missing audio capture device. Reinstalling GeForce Experience should resolve this error."
                )
            }
            throw UmbraNetworkingError.serverResponse(statusCode: statusCode, message: message)
        }
    }

    private func parseMACIfPresent(_ value: String?) throws -> Data? {
        guard let value = nonempty(value), value != "00:00:00:00:00:00" else { return nil }
        return try WakeOnLAN.macAddressBytes(from: value)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func firstDescendant(named name: String) -> XMLNode? {
        if let direct = children.first(where: { $0.name == name }) { return direct }
        for child in children {
            if let match = child.firstDescendant(named: name) { return match }
        }
        return nil
    }

    func descendants(named name: String) -> [XMLNode] {
        children.flatMap { child in
            (child.name == name ? [child] : []) + child.descendants(named: name)
        }
    }

    func text(named name: String) -> String? {
        firstDescendant(named: name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TreeParserDelegate: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}
