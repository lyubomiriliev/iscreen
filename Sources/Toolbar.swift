import AppKit

/// Dark floating toolbar shown next to the selection: tools · colors · size · undo · save/copy/close.
final class AnnotationToolbar: NSView {
    var onTool: ((Tool) -> Void)?
    var onColor: ((Int) -> Void)?
    var onSize: (() -> Void)?
    var onUndo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onCopyDescribed: (() -> Void)?
    var onClose: (() -> Void)?
    /// Called with the hovered control (nil when the pointer leaves) so the overlay can show an instant hint.
    var onHover: ((ToolbarControl?) -> Void)?

    private var toolButtons: [Tool: SymbolButton] = [:]
    private var swatches: [ColorSwatch] = []
    private let sizeControl = SizeControl(hint: "", width: 44)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 12
            s.shadowOffset = CGSize(width: 0, height: -3)
            s.shadowColor = NSColor(white: 0, alpha: 0.5)
            return s
        }()

        var views: [NSView] = []
        for tool in Tool.allCases {
            let button = SymbolButton(symbol: tool.symbol, hint: "\(tool.title)   \(tool.key.uppercased())")
            button.onClick = { [weak self] in self?.onTool?(tool) }
            toolButtons[tool] = button
            views.append(button)
        }
        views.append(Separator())

        for (i, color) in Palette.colors.enumerated() {
            let swatch = ColorSwatch(color: color, hint: "\(Palette.names[i])   \(i + 1)")
            swatch.onClick = { [weak self] in self?.onColor?(i) }
            swatches.append(swatch)
            views.append(swatch)
        }
        sizeControl.onClick = { [weak self] in self?.onSize?() }
        views.append(sizeControl)
        views.append(Separator())

        let undo = SymbolButton(symbol: "arrow.uturn.backward", hint: "Undo   ⌘Z")
        undo.onClick = { [weak self] in self?.onUndo?() }
        let save = SymbolButton(symbol: "square.and.arrow.down", hint: "Save to Desktop   ⌘S")
        save.onClick = { [weak self] in self?.onSave?() }
        let copyText = SymbolButton(symbol: "text.viewfinder", hint: "Copy text (OCR)   ⌘T")
        copyText.onClick = { [weak self] in self?.onCopyText?() }
        let copyDescribed = SymbolButton(symbol: "text.below.photo", hint: "Copy with description   ⇧⌘C")
        copyDescribed.onClick = { [weak self] in self?.onCopyDescribed?() }
        let copy = SymbolButton(symbol: "doc.on.doc", hint: "Copy   ⌘C", prominent: true)
        copy.onClick = { [weak self] in self?.onCopy?() }
        let close = SymbolButton(symbol: "xmark", hint: "Cancel   Esc")
        close.onClick = { [weak self] in self?.onClose?() }
        views += [undo, Separator(), copyText, copyDescribed, save, copy, close]

        for case let control as ToolbarControl in views {
            control.onHover = { [weak self] control, inside in self?.onHover?(inside ? control : nil) }
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tool: Tool, colorIndex: Int, size: StrokeSize) {
        for (t, button) in toolButtons { button.isActive = t == tool }
        for (i, swatch) in swatches.enumerated() { swatch.isActive = i == colorIndex }
        sizeControl.size = size
        sizeControl.hint = "Size: \(size.title)   [ ]"
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Swallow clicks on the toolbar background so they don't start a new selection underneath.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

class ToolbarControl: NSView {
    var hint: String
    var onClick: (() -> Void)?
    var onHover: ((ToolbarControl, Bool) -> Void)?
    var isActive = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private let width: CGFloat

    init(hint: String, width: CGFloat = 30) {
        self.hint = hint
        self.width = width
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 30))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseEntered(with event: NSEvent) { isHovered = true; onHover?(self, true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; onHover?(self, false) }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    var highlightBackground: NSColor? {
        if isPressed { return NSColor(white: 1, alpha: 0.22) }
        if isHovered { return NSColor(white: 1, alpha: 0.12) }
        return nil
    }

    func drawBackground(_ color: NSColor?) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

final class SymbolButton: ToolbarControl {
    private let image: NSImage?
    private let prominent: Bool

    init(symbol: String, hint: String, prominent: Bool = false) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)?.withSymbolConfiguration(config)
        self.prominent = prominent
        super.init(hint: hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if prominent || isActive {
            drawBackground(NSColor.controlAccentColor.blended(withFraction: highlightBackground == nil ? 0 : 0.15, of: .white))
        } else {
            drawBackground(highlightBackground)
        }
        guard let image else { return }
        let size = image.size
        image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}

final class ColorSwatch: ToolbarControl {
    private let color: NSColor

    init(color: NSColor, hint: String) {
        self.color = color
        super.init(hint: hint, width: 22)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(highlightBackground)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if isActive {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
            ring.lineWidth = 2
            ring.stroke()
        }
        color.setFill()
        let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        dot.fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
    }
}

final class SizeControl: ToolbarControl {
    var size: StrokeSize = .medium { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(highlightBackground)
        // Three dots growing in size; the active one is bright.
        let diameters: [CGFloat] = [4, 7, 10]
        var x = bounds.midX - 14
        for (i, d) in diameters.enumerated() {
            NSColor(white: 1, alpha: i == size.rawValue ? 1 : 0.3).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: bounds.midY - d / 2, width: d, height: d)).fill()
            x += d + 4
        }
    }
}

private final class Separator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.18).setFill()
        CGRect(x: bounds.midX - 0.5, y: bounds.midY - 10, width: 1, height: 20).fill()
    }
}
