import AppKit
import ServiceManagement
import Sparkle

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("iScreen: login item change failed: \(error)")
            return false
        }
    }

    /// Turns "launch at login" on the first time the app runs.
    static func enableOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if set(true) { UserDefaults.standard.set(true, forKey: key) }
    }
}

final class PreferencesWindowController: NSWindowController {
    private let updater: SPUUpdater
    private let onShortcutChange: () -> Void
    private let onRecordingChange: (Bool) -> Void
    private var loginCheckbox: NSButton!

    init(updater: SPUUpdater, onShortcutChange: @escaping () -> Void, onRecordingChange: @escaping (Bool) -> Void) {
        self.updater = updater
        self.onShortcutChange = onShortcutChange
        self.onRecordingChange = onRecordingChange
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 290),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "iScreen Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        super.showWindow(sender)
    }

    private func buildContent() {
        var rows: [[NSView]] = []
        for mode in CaptureMode.allCases {
            let recorder = ShortcutRecorder(shortcut: Settings.shortcut(for: mode))
            recorder.onChange = { [weak self] shortcut in
                Settings.setShortcut(shortcut, for: mode)
                self?.onShortcutChange()
            }
            recorder.onRecordingChange = { [weak self] recording in self?.onRecordingChange(recording) }
            rows.append([label("\(mode.title):"), recorder])
        }

        let downscale = NSButton(checkboxWithTitle: "Downscale Retina screens", target: self, action: #selector(toggleDownscale(_:)))
        downscale.state = Settings.downscaleRetina ? .on : .off
        rows.append([NSGridCell.emptyContentView, downscale])

        let note = NSTextField(wrappingLabelWithString: "Saves at 1× size: 4× fewer pixels, much smaller files, still crisp.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        rows.append([NSGridCell.emptyContentView, note])

        loginCheckbox = NSButton(checkboxWithTitle: "Launch iScreen at login", target: self, action: #selector(toggleLogin(_:)))
        rows.append([NSGridCell.emptyContentView, loginCheckbox])

        let updates = NSButton(checkboxWithTitle: "Automatically check for updates", target: self, action: #selector(toggleUpdates(_:)))
        updates.state = updater.automaticallyChecksForUpdates ? .on : .off
        rows.append([NSGridCell.emptyContentView, updates])

        let aiStatus = NSTextField(wrappingLabelWithString: OnDeviceAI.status)
        aiStatus.font = .systemFont(ofSize: 12)
        aiStatus.textColor = OnDeviceAI.isAvailable ? .labelColor : .secondaryLabelColor
        rows.append([label("On-device AI:"), aiStatus])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for i in 0..<CaptureMode.allCases.count { grid.row(at: i).yPlacement = .center }
        grid.row(at: CaptureMode.allCases.count + 1).topPadding = -6

        let content = NSView()
        content.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            note.widthAnchor.constraint(equalToConstant: 260),
            aiStatus.widthAnchor.constraint(equalToConstant: 260),
        ])
        window?.contentView = content
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        return field
    }

    @objc private func toggleUpdates(_ sender: NSButton) {
        updater.automaticallyChecksForUpdates = sender.state == .on
    }

    @objc private func toggleDownscale(_ sender: NSButton) {
        Settings.downscaleRetina = sender.state == .on
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        if !LoginItem.set(sender.state == .on) {
            sender.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "Move iScreen into the Applications folder and try again."
            alert.beginSheetModal(for: window!)
        }
    }
}

/// Click, then press a key combination to record a new global shortcut. Esc cancels.
final class ShortcutRecorder: NSView {
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var shortcut: Shortcut { didSet { needsDisplay = true } }
    private var recording = false {
        didSet {
            guard oldValue != recording else { return }
            needsDisplay = true
            onRecordingChange?(recording)
        }
    }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 180),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && mods.isEmpty {
            window?.makeFirstResponder(nil)
            return
        }
        guard !mods.subtracting(.shift).isEmpty || Shortcut.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, key: Shortcut.keyName(for: event))
        onChange?(shortcut)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = recording ? "Type shortcut…" : shortcut.display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
