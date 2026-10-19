import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, SPUStandardUserDriverDelegate {
    private var statusItem: NSStatusItem!
    private var menuItems: [CaptureMode: NSMenuItem] = [:]
    private var hotKeys: [CaptureMode: HotKey] = [:]
    private var overlay: OverlayController?
    private var preferences: PreferencesWindowController?
    private var capturing = false
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        setupStatusItem()

        HotKey.installHandler()
        hotKeys[.region] = HotKey(id: 1) { [weak self] in self?.takeRegionScreenshot() }
        hotKeys[.fullScreen] = HotKey(id: 2) { [weak self] in self?.takeFullScreenshot() }
        applyShortcuts(showErrors: true)

        LoginItem.enableOnFirstLaunch()
        ScreenshotFiles.cleanUp()
        TextRecognizer.warmUp()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "iScreen")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        let region = NSMenuItem(title: "Capture area", action: #selector(regionFromMenu), keyEquivalent: "")
        let full = NSMenuItem(title: "Capture full screen", action: #selector(fullFromMenu), keyEquivalent: "")
        for item in [region, full] {
            item.target = self
            menu.addItem(item)
        }
        menuItems = [.region: region, .fullScreen: full]
        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = updaterController
        menu.addItem(updatesItem)

        let aboutItem = NSMenuItem(title: "About iScreen", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit iScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateMenuShortcuts() {
        for (mode, item) in menuItems {
            let shortcut = Settings.shortcut(for: mode)
            let base = mode == .region ? "Capture area" : "Capture full screen"
            if let equivalent = shortcut.menuKeyEquivalent {
                item.title = base
                item.keyEquivalent = equivalent
                item.keyEquivalentModifierMask = shortcut.modifiers
            } else {
                item.title = "\(base)  (\(shortcut.display))"
                item.keyEquivalent = ""
            }
        }
    }

    // MARK: - Hotkeys

    private func applyShortcuts(showErrors: Bool) {
        var failed: [Shortcut] = []
        for mode in CaptureMode.allCases {
            let shortcut = Settings.shortcut(for: mode)
            if hotKeys[mode]?.register(shortcut) == false { failed.append(shortcut) }
        }
        updateMenuShortcuts()
        guard showErrors, !failed.isEmpty else { return }

        let keys = failed.map(\.display).joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "\(keys) is already in use"
        alert.informativeText = "Another app (for example Lightshot) has registered \(keys). Quit that app, or pick a different shortcut in iScreen Preferences."
        alert.addButton(withTitle: "Open Preferences")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { showPreferences() }
    }

    // MARK: - Capture

    @objc private func regionFromMenu() {
        // Give the menu time to disappear so it is not in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.takeRegionScreenshot() }
    }

    @objc private func fullFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.takeFullScreenshot() }
    }

    func takeRegionScreenshot() {
        guard overlay == nil, !capturing else { return }
        capturing = true
        let previousApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor in
            defer { self.capturing = false }
            do {
                let shots = try await Capturer.captureAllScreens()
                guard !shots.isEmpty else { return }
                let controller = OverlayController(shots: shots, previousApp: previousApp)
                controller.onClose = { self.overlay = nil }
                self.overlay = controller
                controller.show()
            } catch {
                self.showPermissionAlert(error)
            }
        }
    }

    /// Captures the screen under the mouse, copies it, and shows a draggable thumbnail.
    func takeFullScreenshot() {
        guard overlay == nil, !capturing else { return }
        capturing = true

        Task { @MainActor in
            defer { self.capturing = false }
            do {
                guard let shot = try await Capturer.captureScreenUnderMouse() else { return }
                let all = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
                guard let encoded = ImageEncoder.encode(shot.image, crop: all, scale: shot.screen.backingScaleFactor,
                                                        downscale: Settings.downscaleRetina) else { return }
                let copied = Clipboard.write(png: encoded.data)
                let name = shot.fullScreenContext().fileBaseName()
                guard let url = ScreenshotFiles.write(encoded.data, baseName: name) else {
                    HUD.show("Couldn't save screenshot", symbol: "exclamationmark.triangle.fill")
                    return
                }
                ThumbnailController.show(image: shot.image, fileURL: url, png: encoded.data, on: shot.screen)
                if !copied { HUD.show("Copy failed", symbol: "exclamationmark.triangle.fill") }
            } catch {
                self.showPermissionAlert(error)
            }
        }
    }

    private func showPermissionAlert(_ error: Error) {
        // Makes sure iScreen is listed in System Settings (shows the system prompt only once).
        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "Allow iScreen to capture the screen"
        alert.informativeText = """
        1. Open System Settings → Privacy & Security → Screen & System Audio Recording.
        2. Turn iScreen on. If it's already on, turn it off and on again.
        3. Click “Relaunch iScreen”. macOS only applies the permission after a restart.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch iScreen")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Windows

    @objc private func showPreferences() {
        if preferences == nil {
            preferences = PreferencesWindowController(
                updater: updaterController.updater,
                onShortcutChange: { [weak self] in self?.updateMenuShortcuts() },
                onRecordingChange: { [weak self] recording in
                    guard let self else { return }
                    if recording {
                        self.hotKeys.values.forEach { $0.unregister() }
                    } else {
                        self.applyShortcuts(showErrors: true)
                    }
                }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Updates (Sparkle)

    // iScreen is a menu-bar app, so scheduled update alerts are shown right away and brought to the front.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
