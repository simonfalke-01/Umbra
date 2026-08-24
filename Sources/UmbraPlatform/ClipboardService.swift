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
