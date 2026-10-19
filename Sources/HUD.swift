import AppKit

/// Small non-activating toast shown after a copy/save. With `reveal`, it shows a
/// "Show in Finder" button and stays up while the pointer is over it. `reveal` is a closure
/// because the file may be renamed (smart names) while the toast is visible.
enum HUD {
    private static var panel: NSPanel?
    private static var generation = 0
    private static var hovering = false

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: NSColor? = nil,
                     duration: TimeInterval = 1.4, reveal: (() -> URL)? = nil) {
        panel?.orderOut(nil)
        generation += 1
        hovering = false
        let current = generation

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = tint ?? (symbol.hasPrefix("checkmark") ? .systemGreen : .systemOrange)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)

        var views: [NSView] = [icon, label]
        if let reveal {
            let button = FirstClickButton(title: "Show in Finder", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.onClick = {
                NSWorkspace.shared.activateFileViewerSelecting([reveal()])
                dismiss(generation: current)
            }
            views.append(button)
        }

        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.setCustomSpacing(8, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: reveal == nil ? 16 : 10)

        let effect = HoverEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let size = stack.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = reveal == nil
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p

        effect.onHover = { inside in
            guard current == generation else { return }
            hovering = inside
            if !inside { scheduleDismiss(generation: current, after: 1.5) }
        }

        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        scheduleDismiss(generation: current, after: duration)
    }

    private static func scheduleDismiss(generation scheduled: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard scheduled == generation, !hovering else { return }
            dismiss(generation: scheduled)
        }
    }

    private static func dismiss(generation scheduled: Int) {
        guard scheduled == generation, let p = panel else { return }
        generation += 1
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
            p.orderOut(nil)
        }
    }
}

private final class HoverEffectView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Works on the first click even though the toast's panel never becomes key.
private final class FirstClickButton: NSButton {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event) // tracks the press until mouse up
        if bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
            onClick?()
        }
    }
}
