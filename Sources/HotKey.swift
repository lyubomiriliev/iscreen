import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(id: UInt32, action: @escaping () -> Void) {
        self.id = id
        HotKey.actions[id] = action
    }

    static func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = HotKey.actions[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        register(keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers)
    }

    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x6953_4352), id: id) // 'iSCR'
        return RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

enum CaptureMode: String, CaseIterable {
    case region
    case fullScreen

    var title: String {
        switch self {
        case .region: return "Select area"
        case .fullScreen: return "Full screen"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .region: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: .command, key: "3")
        case .fullScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: .command, key: "4")
        }
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var key: String

    var carbonModifiers: UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        return UInt32(result)
    }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    /// Key equivalent usable in an NSMenuItem, or nil for special keys.
    var menuKeyEquivalent: String? {
        guard Shortcut.specialKeys[Int(keyCode)] == nil, key.count == 1 else { return nil }
        return key.lowercased()
    }

    static let specialKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        (specialKeys[Int(keyCode)] ?? "").hasPrefix("F")
    }

    static func keyName(for event: NSEvent) -> String {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return chars.uppercased()
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static func registerDefaults() {
        var values: [String: Any] = ["downscaleRetina": true, "drawColor": 0, "highlightColor": 1, "strokeSize": 1]
        for mode in CaptureMode.allCases {
            let s = mode.defaultShortcut
            values["\(mode.rawValue).keyCode"] = Int(s.keyCode)
            values["\(mode.rawValue).modifiers"] = Int(s.modifiers.rawValue)
            values["\(mode.rawValue).key"] = s.key
        }
        defaults.register(defaults: values)
    }

    static var downscaleRetina: Bool {
        get { defaults.bool(forKey: "downscaleRetina") }
        set { defaults.set(newValue, forKey: "downscaleRetina") }
    }

    /// Palette index used by every annotation tool except the highlighter.
    static var drawColorIndex: Int {
        get { defaults.integer(forKey: "drawColor") }
        set { defaults.set(newValue, forKey: "drawColor") }
    }

    static var highlightColorIndex: Int {
        get { defaults.integer(forKey: "highlightColor") }
        set { defaults.set(newValue, forKey: "highlightColor") }
    }

    static var strokeSize: Int {
        get { defaults.integer(forKey: "strokeSize") }
        set { defaults.set(newValue, forKey: "strokeSize") }
    }

    static func shortcut(for mode: CaptureMode) -> Shortcut {
        let p = mode.rawValue
        return Shortcut(
            keyCode: UInt32(defaults.integer(forKey: "\(p).keyCode")),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "\(p).modifiers"))),
            key: defaults.string(forKey: "\(p).key") ?? mode.defaultShortcut.key
        )
    }

    static func setShortcut(_ shortcut: Shortcut, for mode: CaptureMode) {
        let p = mode.rawValue
        defaults.set(Int(shortcut.keyCode), forKey: "\(p).keyCode")
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: "\(p).modifiers")
        defaults.set(shortcut.key, forKey: "\(p).key")
    }
}
