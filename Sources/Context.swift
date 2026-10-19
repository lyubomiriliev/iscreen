import AppKit

/// An on-screen app window, recorded at capture time (before the overlay covers everything).
struct WindowInfo {
    let app: String
    let title: String
    /// Global Core Graphics coordinates (top-left origin of the primary display).
    let frame: CGRect

    static func onScreen() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let app = info[kCGWindowOwnerName as String] as? String,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 50, frame.height > 50
            else { return nil }
            return WindowInfo(app: app, title: info[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }
}

/// Where a screenshot came from: used for smart file names and description captions.
struct SourceContext {
    let app: String?
    let title: String?
    let date: Date

    /// "Safari — Stripe Payments"
    var label: String? {
        let parts = [app, cleanTitle].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// "Safari — Stripe Payments · 20 Oct 2026, 14:32"
    var captionLine: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return [label, formatter.string(from: date)].compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// "Screenshot-2026-10-20-at-14.32.05": no spaces, so the pasted path needs no quoting.
    var pathSafeBaseName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-'at'-HH.mm.ss"
        return "Screenshot-\(formatter.string(from: date))"
    }

    /// "Safari – Stripe Payments 2026-10-20 at 14.32.05" (subject replaces the window title when given).
    func fileBaseName(subject: String? = nil) -> String {
        let main = Self.nonEmpty(subject) ?? cleanTitle
        var base = [app, main].compactMap { $0 }.joined(separator: " – ")
        if base.isEmpty { base = "Screenshot" }
        base = String(Self.sanitize(base).prefix(80)).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(base) \(formatter.string(from: date))"
    }

    /// Window title without a trailing " - Google Chrome"-style app suffix.
    private var cleanTitle: String? {
        guard var title = Self.nonEmpty(title) else { return nil }
        if let app {
            for separator in [" - ", " — ", " – "] where title.hasSuffix(separator + app) {
                title = String(title.dropLast(separator.count + app.count))
            }
        }
        return Self.nonEmpty(title)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func sanitize(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters).union(.newlines)
        return s.components(separatedBy: forbidden).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }
}

extension ScreenShot {
    /// Context for an area given in this screen's view coordinates (points, bottom-left origin).
    func context(for rect: CGRect) -> SourceContext {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: screen.frame.minX + rect.midX, y: primaryHeight - (screen.frame.minY + rect.midY))
        let window = windows.first { $0.frame.contains(center) }
        return SourceContext(app: window?.app ?? frontApp, title: window?.title, date: capturedAt)
    }

    /// Context for a whole-screen capture: the frontmost app's front window.
    func fullScreenContext() -> SourceContext {
        let window = windows.first { $0.app == frontApp } ?? windows.first
        return SourceContext(app: frontApp ?? window?.app, title: window?.title, date: capturedAt)
    }
}
