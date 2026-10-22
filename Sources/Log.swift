import Foundation

/// Small diagnostics log at ~/Library/Logs/iScreen.log (kept under ~1 MB), so failures in text
/// recognition or on-device AI can be investigated after the fact.
enum Log {
    private static let queue = DispatchQueue(label: "com.iscreen.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/iScreen.log")

    static func write(_ message: String) {
        NSLog("iScreen: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                let old = url.appendingPathExtension("old")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}
