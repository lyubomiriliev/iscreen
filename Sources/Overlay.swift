import AppKit
import Carbon.HIToolbox

/// Owns one frozen-screenshot window per display while the user selects and annotates an area.
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private let previousApp: NSRunningApplication?
    private var overlayKeys: [HotKey] = []
    var onClose: (() -> Void)?

    init(shots: [ScreenShot], previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
        for shot in shots {
            let window = OverlayWindow(shot: shot)
            window.selectionView.controller = self
            windows.append(window)
        }
    }

    func show() {
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        // Non-activating panels take keyboard focus even when macOS refuses to activate the app
        // (macOS 14+ "cooperative activation"); activating is still requested as a bonus.
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.selectionView)
        NSApp.activate()
        registerOverlayKeys()
    }

    /// Backstop: while the overlay is open, Esc / ⌘C / ⌘S (and ⌃C / ⌃S) are grabbed system-wide,
    /// so they work even if another app somehow keeps keyboard focus.
    private func registerOverlayKeys() {
        let c = UInt32(kVK_ANSI_C), s = UInt32(kVK_ANSI_S)
        let bindings: [(UInt32, Int, (SelectionView) -> Void)] = [
            (UInt32(kVK_Escape), 0, { $0.escapePressed() }),
            (c, cmdKey, { [weak self] in self?.copy(from: $0) }),
            (c, controlKey, { [weak self] in self?.copy(from: $0) }),
            (s, cmdKey, { [weak self] in self?.save(from: $0) }),
            (s, controlKey, { [weak self] in self?.save(from: $0) }),
        ]
        overlayKeys = bindings.enumerated().map { index, binding in
            let (keyCode, modifiers, action) = binding
            let hotKey = HotKey(id: 100 + UInt32(index)) { [weak self] in
                guard let self, let view = self.activeView else { return }
                action(view)
            }
            hotKey.register(keyCode: keyCode, carbonModifiers: UInt32(modifiers))
            return hotKey
        }
    }

    /// The view with a selection, otherwise the focused/hovered display.
    private var activeView: SelectionView? {
        let views = windows.map(\.selectionView)
        if let selected = views.first(where: { $0.selection != nil }) { return selected }
        if let key = windows.first(where: \.isKeyWindow) { return key.selectionView }
        let mouse = NSEvent.mouseLocation
        return windows.first { NSMouseInRect(mouse, $0.frame, false) }?.selectionView ?? views.first
    }

    func selectionBegan(in view: SelectionView) {
        for window in windows where window.selectionView !== view {
            window.selectionView.reset()
        }
    }

    /// The view holding a selection, or the given view (whole screen) when nothing is selected.
    private func sourceView(preferring view: SelectionView) -> SelectionView {
        windows.map(\.selectionView).first { $0.selection != nil } ?? view
    }

    func copy(from view: SelectionView) {
        guard let encoded = sourceView(preferring: view).encode() else { cancel(); return }
        // Clipboard is fully written (and verified) before the overlay disappears,
        // so an immediate ⌘V in another app always gets real image data.
        let ok = Clipboard.write(png: encoded.data)
        close()
        if ok {
            HUD.show("Copied  \(encoded.width) × \(encoded.height)  ·  \(Self.format(bytes: encoded.data.count))")
        } else {
            HUD.show("Copy failed", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Saves to the Desktop with a smart name ("App – Window title <date>"), then — when Apple's on-device
    /// AI is available — renames it after what's actually in the screenshot.
    func save(from view: SelectionView) {
        let source = sourceView(preferring: view)
        let context = source.sourceContext()
        guard let encoded = source.encode() else { cancel(); return }
        _ = Clipboard.write(png: encoded.data)
        close()

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let file = SavedFile(url: ScreenshotFiles.uniqueURL(in: desktop, baseName: context.fileBaseName()))
        guard (try? encoded.data.write(to: file.url, options: .atomic)) != nil else {
            HUD.show("Save failed", symbol: "exclamationmark.triangle.fill")
            return
        }
        HUD.show("Saved to Desktop & copied  ·  \(Self.format(bytes: encoded.data.count))",
                 duration: 4, reveal: { file.url })

        guard OnDeviceAI.isAvailable else { return }
        Task { @MainActor in
            guard let subject = await OnDeviceAI.shortName(encoded.image, context: context) else { return }
            let renamed = ScreenshotFiles.uniqueURL(in: desktop, baseName: context.fileBaseName(subject: subject))
            if (try? FileManager.default.moveItem(at: file.url, to: renamed)) != nil { file.url = renamed }
        }
    }

    /// Recognizes the text in the area (offline, Apple Vision) and copies it as plain text.
    /// Recognition runs in the background: usually instant, but after a long idle macOS may need a while
    /// to reload its text-recognition models, and the overlay shouldn't freeze meanwhile.
    func copyText(from view: SelectionView) {
        guard let image = sourceView(preferring: view).originalImage() else { cancel(); return }
        close()
        HUD.show("Reading text…", symbol: "text.viewfinder", tint: .controlAccentColor, duration: 120)
        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) { TextRecognizer.recognize(image) }.value
            if text.isEmpty {
                HUD.show("No text found", symbol: "text.magnifyingglass", tint: .systemOrange)
            } else if Clipboard.write(text: text) {
                let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }.count
                HUD.show("Copied text  ·  \(lines) line\(lines == 1 ? "" : "s")")
            } else {
                HUD.show("Copy failed", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Image + description in two pastes: the first ⌘V attaches the image, after which the clipboard
    /// switches to the description (where it came from + an on-device AI description) for the second ⌘V.
    func copyWithDescription(from view: SelectionView) {
        let source = sourceView(preferring: view)
        let context = source.sourceContext()
        let original = source.originalImage()
        guard let encoded = source.encode(),
              let sequence = PasteSequence.begin(png: encoded.data, text: context.captionLine)
        else { cancel(); return }
        close()

        guard OnDeviceAI.isAvailable else {
            sequence.finalizeText()
            HUD.show("Copied — ⌘V pastes the image, then ⌘V again the source info", duration: 3)
            return
        }
        HUD.show("Copied — ⌘V pastes the image, then ⌘V again the description", duration: 3)
        Task { @MainActor in
            let visibleText = await Task.detached(priority: .userInitiated) { original.map(TextRecognizer.recognize) }.value
            let description = await OnDeviceAI.describe(encoded.image, context: context, visibleText: visibleText)
            guard sequence.isActive else { return } // the user copied something else meanwhile
            if let description {
                sequence.update(text: context.captionLine + "\n" + description)
            } else {
                sequence.finalizeText()
                HUD.show("Couldn't write a description — 2nd ⌘V pastes the source only",
                         symbol: "exclamationmark.triangle.fill", duration: 4)
            }
        }
    }

    func cancel() { close() }

    private func close() {
        overlayKeys.forEach { $0.unregister() }
        overlayKeys.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        onClose?()
    }

    static func format(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A saved file whose URL can change when it gets renamed in the background.
final class SavedFile {
    var url: URL
    init(url: URL) { self.url = url }
}

final class OverlayWindow: NSPanel {
    let selectionView: SelectionView

    init(shot: ScreenShot) {
        selectionView = SelectionView(shot: shot)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(shot.screen.frame, display: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The frozen screenshot is GPU-composited as layer contents; the selection view only draws
        // dimming, selection and annotations on top, which keeps drawing smooth on big displays.
        let background = NSView(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        background.wantsLayer = true
        background.layer?.contents = shot.image
        background.layer?.contentsGravity = .resize
        background.layer?.contentsScale = shot.screen.backingScaleFactor
        selectionView.frame = background.bounds
        selectionView.autoresizingMask = [.width, .height]
        background.addSubview(selectionView)
        contentView = background
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Every key press goes through the overlay first, so shortcuts keep working
    /// no matter which subview (e.g. a text box being typed in) has focus.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, selectionView.handleKey(event) { return }
        super.sendEvent(event)
    }
}

final class SelectionView: NSView, NSTextFieldDelegate {
    weak var controller: OverlayController?
    private(set) var selection: CGRect?

    private let shot: ScreenShot
    private var drag: Drag = .none
    private var tool: Tool = .select
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var current: Annotation?
    private var textField: NSTextField?
    private var textStyle: (color: NSColor, size: StrokeSize) = (.red, .medium)
    private var hoveredControl: ToolbarControl?
    private let toolbar = AnnotationToolbar()
    private let liveRenderer: AnnotationRenderer

    private enum Drag {
        case none
        case creating(start: CGPoint)
        case moving(grab: CGPoint, original: CGRect)
        case resizing(xEdge: Int, yEdge: Int, original: CGRect)
        case drawing(start: CGPoint)
    }

    private let handleSize: CGFloat = 8
    private let accent = NSColor(calibratedRed: 0.27, green: 0.62, blue: 1.0, alpha: 1)

    init(shot: ScreenShot) {
        self.shot = shot
        liveRenderer = AnnotationRenderer(image: shot.image, viewSize: shot.screen.frame.size, drawsHighlightBackdrop: true)
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        toolbar.isHidden = true
        toolbar.onTool = { [weak self] tool in self?.toggleTool(tool) }
        toolbar.onColor = { [weak self] index in self?.setColor(index) }
        toolbar.onSize = { [weak self] in self?.cycleSize(by: 1, wrap: true) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onCopy = { [weak self] in self.map { $0.controller?.copy(from: $0) } }
        toolbar.onSave = { [weak self] in self.map { $0.controller?.save(from: $0) } }
        toolbar.onCopyText = { [weak self] in self.map { $0.controller?.copyText(from: $0) } }
        toolbar.onCopyDescribed = { [weak self] in self.map { $0.controller?.copyWithDescription(from: $0) } }
        toolbar.onClose = { [weak self] in self?.controller?.cancel() }
        toolbar.onHover = { [weak self] control in
            self?.hoveredControl = control
            self?.needsDisplay = true
        }
        addSubview(toolbar)
        refreshToolbar()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clears everything (used when the user starts selecting on another display).
    func reset() {
        finishTextEditing()
        selection = nil
        annotations.removeAll()
        redoStack.removeAll()
        current = nil
        drag = .none
        toolbar.isHidden = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Tool state

    private var colorIndex: Int {
        tool == .highlighter ? Settings.highlightColorIndex : Settings.drawColorIndex
    }

    private var strokeSize: StrokeSize { StrokeSize(rawValue: Settings.strokeSize) ?? .medium }

    private func toggleTool(_ newTool: Tool) {
        setTool(tool == newTool && newTool != .select ? .select : newTool)
    }

    private func setTool(_ newTool: Tool) {
        finishTextEditing()
        tool = newTool
        refreshToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func setColor(_ index: Int) {
        guard Palette.colors.indices.contains(index) else { return }
        if tool == .highlighter { Settings.highlightColorIndex = index } else { Settings.drawColorIndex = index }
        if let textField {
            textStyle.color = Palette.colors[index]
            textField.textColor = textStyle.color
        }
        refreshToolbar()
    }

    private func cycleSize(by step: Int, wrap: Bool = false) {
        let count = StrokeSize.allCases.count
        let next = Settings.strokeSize + step
        Settings.strokeSize = wrap ? (next % count + count) % count : min(max(next, 0), count - 1)
        if let textField {
            textStyle.size = strokeSize
            textField.font = Annotation.font(for: strokeSize)
            sizeTextField(textField)
        }
        refreshToolbar()
    }

    private func refreshToolbar() {
        toolbar.update(tool: tool, colorIndex: colorIndex, size: strokeSize)
    }

    // MARK: - Annotations

    private func add(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
        needsDisplay = true
    }

    private func undo() {
        if textField != nil { finishTextEditing(); return }
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        annotations.append(next)
        needsDisplay = true
    }

    private var nextCounterNumber: Int {
        annotations.reduce(1) { n, a in
            if case .counter = a.shape { return n + 1 }
            return n
        }
    }

    // MARK: - Output

    var backingScale: CGFloat { shot.screen.backingScaleFactor }

    /// App/window the selected area came from.
    func sourceContext() -> SourceContext {
        selection.map { shot.context(for: $0) } ?? shot.fullScreenContext()
    }

    /// The selected area (or whole screen) in full-resolution image pixels, top-left origin.
    private var pixelRect: CGRect {
        let rect = selection ?? bounds
        let sx = CGFloat(shot.image.width) / bounds.width
        let sy = CGFloat(shot.image.height) / bounds.height
        return CGRect(x: rect.minX * sx, y: (bounds.height - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
    }

    /// Unannotated full-resolution pixels of the area (best input for text recognition).
    func originalImage() -> CGImage? {
        finishTextEditing()
        let pixels = pixelRect
        return pixels.isEmpty ? nil : shot.image.cropping(to: pixels)
    }

    func encode() -> EncodedImage? {
        finishTextEditing()
        let sx = CGFloat(shot.image.width) / bounds.width
        let sy = CGFloat(shot.image.height) / bounds.height
        let pixels = pixelRect
        guard !pixels.isEmpty, let composite = composite(pixels: pixels, sx: sx, sy: sy) else { return nil }
        return ImageEncoder.encode(composite, crop: CGRect(x: 0, y: 0, width: composite.width, height: composite.height),
                                   scale: shot.screen.backingScaleFactor, downscale: Settings.downscaleRetina)
    }

    /// Renders screenshot + annotations at full native resolution for the given pixel crop.
    private func composite(pixels: CGRect, sx: CGFloat, sy: CGFloat) -> CGImage? {
        guard !annotations.isEmpty else { return shot.image.cropping(to: pixels) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Context coordinates become full-image pixels (bottom-left origin), then view points.
        ctx.translateBy(x: -pixels.minX, y: -(CGFloat(shot.image.height) - pixels.maxY))
        ctx.interpolationQuality = .high
        ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        ctx.scaleBy(x: sx, y: sy)
        let renderer = AnnotationRenderer(image: shot.image, viewSize: bounds.size, drawsHighlightBackdrop: false)
        for annotation in annotations { renderer.draw(annotation, in: ctx) }
        return ctx.makeImage()
    }

    private func outputSize(for rect: CGRect) -> (Int, Int) {
        let scale = Settings.downscaleRetina ? 1 : shot.screen.backingScaleFactor
        return (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        for annotation in annotations { liveRenderer.draw(annotation, in: ctx) }
        if let current { liveRenderer.draw(current, in: ctx) }

        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.4).setFill()
        dim.fill()

        guard let selection else {
            drawLabel("Drag to select an area   ·   ⌘C copy whole screen   ·   Esc cancel",
                      centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 80))
            return
        }

        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        accent.setStroke()
        border.stroke()

        for handle in handleRects(for: selection) {
            NSColor.white.setFill()
            NSBezierPath(rect: handle).fill()
            accent.setStroke()
            NSBezierPath(rect: handle.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }

        let (w, h) = outputSize(for: selection)
        let sizeLabelY = selection.maxY + 18 < bounds.maxY ? selection.maxY + 14 : selection.maxY - 14
        drawLabel("\(w) × \(h)", centeredAt: CGPoint(x: selection.minX, y: sizeLabelY), leftAligned: true)

        if let hoveredControl, !toolbar.isHidden {
            let rect = hoveredControl.convert(hoveredControl.bounds, to: self)
            let above = toolbar.frame.maxY + 16 < bounds.maxY
            let y = above ? toolbar.frame.maxY + 14 : toolbar.frame.minY - 14
            drawLabel(hoveredControl.hint, centeredAt: CGPoint(x: rect.midX, y: y))
        }
    }

    private func drawLabel(_ text: String, centeredAt point: CGPoint, leftAligned: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = CGSize(width: 8, height: 4)
        var box = CGRect(x: point.x - size.width / 2 - padding.width, y: point.y - size.height / 2 - padding.height,
                         width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        if leftAligned { box.origin.x = point.x }
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }

    // MARK: - Toolbar placement

    private func layoutToolbar() {
        guard let selection else { toolbar.isHidden = true; return }
        let size = toolbar.fittingSize
        let margin: CGFloat = 8
        var y = selection.minY - size.height - margin
        if y < margin {
            y = selection.maxY + margin
            if y + size.height > bounds.height - margin { y = selection.minY + margin }
        }
        var x = selection.midX - size.width / 2
        x = min(max(x, margin), bounds.width - size.width - margin)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        toolbar.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Handles

    private func handlePositions(for rect: CGRect) -> [(Int, Int, CGPoint)] {
        var result: [(Int, Int, CGPoint)] = []
        for xe in -1...1 {
            for ye in -1...1 where !(xe == 0 && ye == 0) {
                let x = xe == -1 ? rect.minX : (xe == 1 ? rect.maxX : rect.midX)
                let y = ye == -1 ? rect.minY : (ye == 1 ? rect.maxY : rect.midY)
                result.append((xe, ye, CGPoint(x: x, y: y)))
            }
        }
        return result
    }

    private func handleRects(for rect: CGRect) -> [CGRect] {
        handlePositions(for: rect).map { _, _, p in
            CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> (Int, Int)? {
        for (xe, ye, p) in handlePositions(for: rect) where abs(p.x - point.x) <= 6 && abs(p.y - point.y) <= 6 {
            return (xe, ye)
        }
        return nil
    }

    // MARK: - Mouse

    private func location(of event: NSEvent, snapped: Bool = true) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let x = min(max(p.x, 0), bounds.width), y = min(max(p.y, 0), bounds.height)
        return snapped ? CGPoint(x: x.rounded(), y: y.rounded()) : CGPoint(x: x, y: y)
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            // A click outside the text box just finishes typing.
            finishTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let p = location(of: event)

        if let selection, let (xe, ye) = handle(at: p, in: selection) {
            drag = .resizing(xEdge: xe, yEdge: ye, original: selection)
            toolbar.isHidden = true
        } else if tool == .select || selection == nil {
            if let selection, event.clickCount == 2, selection.contains(p) {
                controller?.copy(from: self)
                return
            }
            if let selection, selection.contains(p) {
                drag = .moving(grab: p, original: selection)
            } else {
                controller?.selectionBegan(in: self)
                selection = nil
                drag = .creating(start: p)
            }
            toolbar.isHidden = true
        } else {
            startDrawing(at: location(of: event, snapped: false))
        }
        needsDisplay = true
    }

    private func startDrawing(at p: CGPoint) {
        let color = Palette.colors[colorIndex]
        let size = strokeSize
        let shape: Annotation.Shape
        switch tool {
        case .select: return
        case .text: beginText(at: p); return
        case .counter:
            add(Annotation(shape: .counter(nextCounterNumber, p), color: color, size: size))
            return
        case .pen: shape = .pen([p])
        case .line: shape = .line(p, p)
        case .arrow: shape = .arrow(p, p)
        case .rectangle: shape = .rectangle(CGRect(origin: p, size: .zero))
        case .highlighter: shape = .highlight(CGRect(origin: p, size: .zero))
        case .pixelate: shape = .pixelate(CGRect(origin: p, size: .zero))
        }
        current = Annotation(shape: shape, color: color, size: size)
        drag = .drawing(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(of: event)
        switch drag {
        case .none:
            return
        case .creating(let start):
            selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .moving(let grab, let original):
            var moved = original.offsetBy(dx: p.x - grab.x, dy: p.y - grab.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            selection = moved
        case .resizing(let xe, let ye, let original):
            let x1 = xe == -1 ? p.x : original.minX
            let x2 = xe == 1 ? p.x : original.maxX
            let y1 = ye == -1 ? p.y : original.minY
            let y2 = ye == 1 ? p.y : original.maxY
            selection = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        case .drawing(let start):
            updateDrawing(from: start, to: location(of: event, snapped: false),
                          constrained: event.modifierFlags.contains(.shift))
        }
        needsDisplay = true
    }

    private func updateDrawing(from start: CGPoint, to p: CGPoint, constrained: Bool) {
        guard var annotation = current else { return }
        switch annotation.shape {
        case .pen(var points):
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 { points.append(p) }
            annotation.shape = .pen(points)
        case .line:
            annotation.shape = .line(start, constrained ? Self.snapAngle(from: start, to: p) : p)
        case .arrow:
            annotation.shape = .arrow(start, constrained ? Self.snapAngle(from: start, to: p) : p)
        case .rectangle:
            annotation.shape = .rectangle(Self.rect(from: start, to: p, square: constrained))
        case .highlight:
            annotation.shape = .highlight(Self.rect(from: start, to: p, square: constrained))
        case .pixelate:
            annotation.shape = .pixelate(Self.rect(from: start, to: p, square: constrained))
        case .text, .counter:
            break
        }
        current = annotation
    }

    /// Shift snaps lines and arrows to 45° steps.
    private static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let length = hypot(b.x - a.x, b.y - a.y)
        let step = CGFloat.pi / 4
        let angle = (atan2(b.y - a.y, b.x - a.x) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }

    /// Shift makes rectangles square.
    private static func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    override func mouseUp(with event: NSEvent) {
        if case .drawing = drag, let current {
            if current.isMeaningful { add(current) }
            self.current = nil
        }
        if let selection, selection.width < 3 || selection.height < 3 { self.selection = nil }
        drag = .none
        layoutToolbar()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let drawing = tool != .select && selection != nil
        addCursorRect(bounds, cursor: drawing && tool == .text ? .iBeam : .crosshair)
        guard let selection else { return }
        if !drawing { addCursorRect(selection, cursor: .openHand) }
        for (xe, ye, p) in handlePositions(for: selection) {
            let rect = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            if xe == 0 { addCursorRect(rect, cursor: .resizeUpDown) }
            else if ye == 0 { addCursorRect(rect, cursor: .resizeLeftRight) }
            else { addCursorRect(rect, cursor: .crosshair) }
        }
    }

    // MARK: - Text

    private func beginText(at p: CGPoint) {
        textStyle = (Palette.colors[colorIndex], strokeSize)
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Annotation.font(for: textStyle.size)
        field.textColor = textStyle.color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        sizeTextField(field)
        field.setFrameOrigin(CGPoint(x: p.x - 2, y: p.y - field.frame.height / 2))
        textField = field
        window?.makeFirstResponder(field)
    }

    private func sizeTextField(_ field: NSTextField) {
        let origin = field.frame.origin
        field.sizeToFit()
        field.setFrameSize(CGSize(width: max(field.frame.width + 12, 40), height: field.frame.height))
        field.setFrameOrigin(origin)
    }

    func controlTextDidChange(_ notification: Notification) {
        if let textField { sizeTextField(textField) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishTextEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishTextEditing()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            escapePressed()
            return true
        }
        return false
    }

    private func finishTextEditing() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Borderless NSTextField draws its text inset by 2 pt horizontally.
            let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.minY)
            add(Annotation(shape: .text(text, origin), color: textStyle.color, size: textStyle.size))
        }
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        needsDisplay = true
    }

    // MARK: - Keyboard

    /// Esc always closes the overlay (Enter or a click finishes typing text instead).
    func escapePressed() {
        controller?.cancel()
    }

    /// Central key handling, called by the window before normal dispatch. Returns true when handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editingText = textField != nil

        // ⌘ shortcuts (⌃C / ⌃S also accepted) work everywhere, including while typing text.
        if mods.contains(.command) || mods.contains(.control) {
            switch (event.keyCode, mods.contains(.command)) {
            case (UInt16(kVK_ANSI_C), true) where mods.contains(.shift):
                controller?.copyWithDescription(from: self); return true
            case (UInt16(kVK_ANSI_C), _): controller?.copy(from: self); return true
            case (UInt16(kVK_ANSI_T), true): controller?.copyText(from: self); return true
            case (UInt16(kVK_ANSI_S), _): controller?.save(from: self); return true
            case (UInt16(kVK_ANSI_W), true), (UInt16(kVK_ANSI_Q), true): controller?.cancel(); return true
            case (UInt16(kVK_ANSI_Z), true):
                if editingText { finishTextEditing() } else if mods.contains(.shift) { redo() } else { undo() }
                return true
            default:
                return false // e.g. ⌘A / ⌘V inside the text box
            }
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            escapePressed()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if editingText { finishTextEditing() } else { controller?.copy(from: self) }
            return true
        default:
            break
        }
        if editingText { return false } // let the text box receive typing

        let step: CGFloat = mods.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete: undo(); return true
        case kVK_LeftArrow: nudge(dx: -step, dy: 0); return true
        case kVK_RightArrow: nudge(dx: step, dy: 0); return true
        case kVK_DownArrow: nudge(dx: 0, dy: -step); return true
        case kVK_UpArrow: nudge(dx: 0, dy: step); return true
        default: break
        }
        guard mods.subtracting(.shift).isEmpty else { return false }

        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            setTool(tool)
        } else if let digit = Int(key), (1...Palette.colors.count).contains(digit) {
            setColor(digit - 1)
        } else if key == "[" {
            cycleSize(by: -1)
        } else if key == "]" {
            cycleSize(by: 1)
        } else {
            return false
        }
        return true
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard var moved = selection?.offsetBy(dx: dx, dy: dy) else { return }
        moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
        moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
        selection = moved
        layoutToolbar()
        needsDisplay = true
    }
}
