import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    /// App windows on screen at capture time (front to back), for smart names and captions.
    var windows: [WindowInfo] = []
    var frontApp: String?
    var capturedAt = Date()
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum Capturer {
    /// Freezes every screen at full native resolution before any overlay is shown.
    @MainActor
    static func captureAllScreens() async throws -> [ScreenShot] {
        try await capture(NSScreen.screens)
    }

    /// The screen the mouse pointer is on.
    @MainActor
    static func captureScreenUnderMouse() async throws -> ScreenShot? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return nil }
        return try await capture([screen]).first
    }

    @MainActor
    private static func capture(_ screens: [NSScreen]) async throws -> [ScreenShot] {
        let windows = WindowInfo.onScreen()
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []
        for screen in screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image, windows: windows, frontApp: frontApp))
        }
        return shots
    }
}

enum ScreenshotFiles {
    /// Screenshots used for drag & drop and ⇧⌘C paths live here; files older than a week are cleaned up on launch.
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("com.iscreen.app/Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ png: Data, baseName: String) -> URL? {
        let url = uniqueURL(in: directory, baseName: baseName)
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    /// "<baseName>.png", or "<baseName> 2.png" etc. when taken.
    static func uniqueURL(in folder: URL, baseName: String) -> URL {
        var url = folder.appendingPathComponent(baseName + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName)-\(n).png")
            n += 1
        }
        return url
    }

    static func cleanUp() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }
}

struct EncodedImage {
    let data: Data
    let width: Int
    let height: Int
    /// The final (cropped, downscaled) image the PNG was made from.
    let image: CGImage
}

enum ImageEncoder {
    /// Crops, optionally downscales Retina pixels to 1x, flattens to opaque sRGB and encodes a lean PNG.
    static func encode(_ image: CGImage, crop: CGRect, scale: CGFloat, downscale: Bool) -> EncodedImage? {
        guard let cropped = image.cropping(to: crop) else { return nil }
        let factor: CGFloat = (downscale && scale > 1) ? 1 / scale : 1
        let width = max(1, Int((CGFloat(cropped.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(cropped.height) * factor).rounded()))

        // Opaque RGB (no alpha channel) keeps the PNG noticeably smaller.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return EncodedImage(data: PNGOptimizer.stripMetadata(data as Data), width: width, height: height, image: output)
    }
}

enum PNGOptimizer {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let droppedChunks: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "iTXt", "tEXt", "zTXt", "eXIf", "iDOT"]

    /// Replaces the embedded ~3 KB ICC profile with a 13-byte sRGB chunk and removes text/EXIF/Apple chunks.
    static func stripMetadata(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return data }
        var out = signature
        var i = 8
        while i + 12 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let end = i + 12 + length
            guard end <= bytes.count else { return data }
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            if !droppedChunks.contains(type) { out += bytes[i..<end] }
            if type == "IHDR" { out += chunk("sRGB", [0]) } // perceptual intent
            i = end
            if type == "IEND" { return Data(out) }
        }
        return data
    }

    private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let n = UInt32(payload.count)
        var out: [UInt8] = [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        out += typeBytes + payload
        let crc = crc32(typeBytes + payload)
        out += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        return out
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

enum Clipboard {
    static func write(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        for _ in 0..<3 {
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text { return true }
        }
        return false
    }

    /// Writes the PNG bytes eagerly (no lazy promise) and reads them back to make sure
    /// the pasteboard really holds the image before we hand focus back to the previous app.
    static func write(png: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        for _ in 0..<3 {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if pasteboard.writeObjects([item]), pasteboard.data(forType: .png)?.count == png.count {
                return true
            }
        }
        return false
    }
}
