import AppKit

/// Floating preview in the bottom-right corner after a full-screen capture.
/// Drag it anywhere (Claude Code, Finder, browsers, chat apps). It disappears after 5 seconds;
/// the countdown pauses while the pointer is over it or a drag is in progress.
final class ThumbnailController {
    private static var current: ThumbnailController?

    private let panel: NSPanel
    private let view: ThumbnailView
    private var timer: Timer?
    private let lifetime: TimeInterval = 5

    static func show(image: CGImage, fileURL: URL, png: Data, on screen: NSScreen) {
        current?.dismiss(animated: false)
        let controller = ThumbnailController(image: image, fileURL: fileURL, png: png, screen: screen)
        current = controller
        controller.present()
    }

    private init(image: CGImage, fileURL: URL, png: Data, screen: NSScreen) {
        let maxSize = CGSize(width: 240, height: 160)
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var size = CGSize(width: maxSize.width, height: maxSize.width / aspect)
        if size.height > maxSize.height { size = CGSize(width: maxSize.height * aspect, height: maxSize.height) }

        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - size.width - 20, y: visible.minY + 20, width: size.width, height: size.height)

        view = ThumbnailView(frame: CGRect(origin: .zero, size: size),
                             image: NSImage(cgImage: image, size: size), fileURL: fileURL, png: png)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        view.onHoverChange = { [weak self] hovering in
            hovering ? self?.pauseTimer() : self?.startTimer()
        }
        view.onDragStart = { [weak self] in self?.pauseTimer() }
        view.onDragEnd = { [weak self] dropped in
            if dropped { self?.dismiss(animated: true) } else { self?.startTimer() }
        }
        view.onClick = { [weak self] in
            NSWorkspace.shared.open(fileURL)
            self?.dismiss(animated: true)
        }
    }

    private func present() {
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: target.width + 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    private func pauseTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func dismiss(animated: Bool) {
        pauseTimer()
        let panel = self.panel
        if ThumbnailController.current === self { ThumbnailController.current = nil }
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().setFrame(panel.frame.offsetBy(dx: panel.frame.width + 40, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

final class ThumbnailView: NSView, NSDraggingSource {
    var onHoverChange: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private let image: NSImage
    private let fileURL: URL
    private let png: Data
    private var mouseDownPoint: CGPoint?
    private var dragging = false

    init(frame: CGRect, image: NSImage, fileURL: URL, png: Data) {
        self.image = image
        self.fileURL = fileURL
        self.png = png
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { if !dragging { onHoverChange?(false) } }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        dragging = true
        onDragStart?()

        // File URL for Finder/terminals/upload fields, plus raw PNG for apps that accept image data.
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setData(png, forType: .png)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging, mouseDownPoint != nil { onClick?() }
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        mouseDownPoint = nil
        onDragEnd?(operation != [])
    }
}
