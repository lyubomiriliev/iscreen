import AppKit

/// ⇧⌘C: image first, description second — "⌘V, ⌘V".
///
/// Claude Code (and most chat apps) ignore text when the clipboard also holds an image, so both can't
/// go in one paste. Instead the image is offered as a promise: when an app actually pastes it, macOS asks
/// us for the bytes, which tells us the image was used — then the clipboard switches to the description
/// so the next ⌘V pastes the text.
final class PasteSequence: NSObject, NSPasteboardItemDataProvider {
    private static var current: PasteSequence?

    private let png: Data
    private var text: String
    private var textIsFinal = false
    private var imagePasted = false
    private var changeCount = 0
    private let startedAt = Date()

    /// Reads this soon after copying come from clipboard managers, not from a paste.
    private static let backgroundReadWindow: TimeInterval = 0.3

    private init(png: Data, text: String) {
        self.png = png
        self.text = text
    }

    /// Puts the image on the clipboard. `text` is pasted second (it can be improved later via `update`).
    @discardableResult
    static func begin(png: Data, text: String) -> PasteSequence? {
        let sequence = PasteSequence(png: png, text: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        guard item.setDataProvider(sequence, forTypes: [.png]), pasteboard.writeObjects([item]) else { return nil }
        sequence.changeCount = pasteboard.changeCount
        current = sequence
        return sequence
    }

    /// Replaces the text to paste second (e.g. when the AI description is ready).
    func update(text: String) {
        self.text = text
        textIsFinal = true
        switchToTextIfReady()
    }

    /// No better text is coming (AI unavailable or failed): switch as soon as the image was pasted.
    func finalizeText() {
        textIsFinal = true
        switchToTextIfReady()
    }

    var isActive: Bool {
        PasteSequence.current === self && NSPasteboard.general.changeCount == changeCount
    }

    // MARK: - NSPasteboardItemDataProvider

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // Answer immediately — a slow answer is exactly what makes pastes come up empty.
        item.setData(png, forType: type)
        guard Date().timeIntervalSince(startedAt) > Self.backgroundReadWindow else { return }
        imagePasted = true
        // Let the receiving app finish its paste before the clipboard changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if !textIsFinal {
                HUD.show("Image pasted — description coming…", symbol: "sparkles", tint: .controlAccentColor, duration: 30)
            }
            switchToTextIfReady()
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    private func switchToTextIfReady() {
        guard imagePasted, textIsFinal, isActive else { return }
        PasteSequence.current = nil
        if Clipboard.write(text: text) {
            HUD.show("Now press ⌘V again to paste the description", symbol: "text.append", tint: .controlAccentColor, duration: 4)
        }
    }
}
