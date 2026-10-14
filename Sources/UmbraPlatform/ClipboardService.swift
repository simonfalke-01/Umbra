import AppKit
import Foundation

@MainActor
public protocol ClipboardTextReading {
    func readNormalizedText() -> String?
}

@MainActor
public struct AppKitClipboardTextReader: ClipboardTextReading {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func readNormalizedText() -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return ClipboardTextNormalizer.normalize(text)
    }
}

/// Pasteboard representations shared with a streaming host.
public struct PasteboardContent: Equatable, Sendable {
    public var text: String?
    public var html: String?
    public var png: Data?

    public init(text: String? = nil, html: String? = nil, png: Data? = nil) {
        self.text = text
        self.html = html
        self.png = png
    }

    public var isEmpty: Bool {
        (text ?? "").isEmpty && (html ?? "").isEmpty && (png ?? Data()).isEmpty
    }

    /// Approximate encoded size used to enforce the transfer limit.
    public var byteCount: Int {
        (text?.utf8.count ?? 0) + (html?.utf8.count ?? 0) + (png?.count ?? 0) + 15
    }
}

/// Two-way pasteboard bridge for one streaming session.
///
/// Local copies are detected by polling `changeCount`; content written by `applyRemote`
/// is never reported back as a local change. Text, HTML, and images are shared.
@MainActor
public final class PasteboardSync {
    /// Largest local content forwarded to the host.
    public static let maximumByteCount = 16 * 1_024 * 1_024

    public var onLocalChange: ((PasteboardContent) -> Void)?
    public var onOversizedLocalChange: ((Int) -> Void)?

    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastRemoteContent: PasteboardContent?

    public init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.25) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        lastChangeCount = pasteboard.changeCount
    }

    /// Starts watching; only copies made after this call are reported.
    public func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Replaces the pasteboard with host content without echoing it back.
    public func applyRemote(_ content: PasteboardContent) {
        guard !content.isEmpty else { return }
        lastRemoteContent = content
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        if content.text?.isEmpty == false { types.append(.string) }
        if content.html?.isEmpty == false { types.append(.html) }
        if content.png?.isEmpty == false { types += [.png, .tiff] }
        pasteboard.declareTypes(types, owner: nil)
        if let text = content.text, !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
        if let html = content.html, !html.isEmpty {
            pasteboard.setData(Data(html.utf8), forType: .html)
        }
        if let png = content.png, !png.isEmpty {
            pasteboard.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        var content = readContent()
        guard !content.isEmpty, content != lastRemoteContent else { return }
        if content.byteCount > Self.maximumByteCount, content.png != nil {
            // Keep the text forms when only the image is too large.
            onOversizedLocalChange?(content.byteCount)
            content.png = nil
        }
        guard !content.isEmpty, content.byteCount <= Self.maximumByteCount else {
            if content.byteCount > Self.maximumByteCount { onOversizedLocalChange?(content.byteCount) }
            return
        }
        onLocalChange?(content)
    }

    private func readContent() -> PasteboardContent {
        var content = PasteboardContent()
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            content.text = text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        if let data = pasteboard.data(forType: .html), !data.isEmpty {
            content.html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        }
        // Finder copies carry the file icon as an image; files themselves are not shared.
        let types = pasteboard.types ?? []
        if !types.contains(.fileURL) {
            if let png = pasteboard.data(forType: .png), !png.isEmpty {
                content.png = png
            } else if let tiff = pasteboard.data(forType: .tiff),
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                content.png = png
            }
        }
        return content
    }
}
