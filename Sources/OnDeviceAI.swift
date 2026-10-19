import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's free on-device model (Apple Intelligence, macOS 27+ with image understanding).
/// Everything stays on the Mac; when it isn't available the app falls back to app/window info.
enum OnDeviceAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let model = SystemLanguageModel.default
            return model.availability == .available && model.capabilities.contains(.vision)
        }
        #endif
        return false
    }

    /// Human-readable status for Preferences.
    static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return SystemLanguageModel.default.capabilities.contains(.vision)
                    ? "On — descriptions and smart names use on-device AI"
                    : "This Mac's model can't read images"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Off — turn on Apple Intelligence in System Settings"
            case .unavailable(.deviceNotEligible):
                return "Not supported on this Mac"
            case .unavailable(.modelNotReady):
                return "Downloading model… try again later"
            default:
                return "Not available"
            }
        }
        #endif
        return "Requires macOS 27 or later"
    }

    /// One or two sentences describing the screenshot.
    /// `visibleText` (from text recognition) lets the model quote names and titles exactly,
    /// e.g. Cyrillic text that it would otherwise misspell.
    static func describe(_ image: CGImage, context: SourceContext, visibleText: String? = nil) async -> String? {
        var prompt = "Describe this screenshot in one or two short, factual sentences (max 40 words). "
        prompt += "Mention what app or website it is and the key information visible."
        if let label = context.label { prompt += " It was taken from: \(label)." }
        if let visibleText, !visibleText.isEmpty {
            prompt += "\n\nText recognized in the screenshot (copy names and titles exactly from here, in their original alphabet):\n"
            prompt += String(visibleText.prefix(1500))
        }
        return await ask(prompt, image: image)
    }

    /// A 3–6 word title for a file name, or nil.
    static func shortName(_ image: CGImage, context: SourceContext) async -> String? {
        var prompt = "Give this screenshot a short descriptive title of 3 to 6 words in Title Case. "
        prompt += "Reply with the title only: no quotes, no punctuation, no file extension."
        if let app = context.app { prompt += " Don't include the app name (\(app))." }
        guard let answer = await ask(prompt, image: image) else { return nil }
        let firstLine = answer.components(separatedBy: .newlines).first ?? answer
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.:*#").union(.whitespaces))
        return cleaned.isEmpty || cleaned.count > 60 ? nil : cleaned
    }

    private static func ask(_ instruction: String, image: CGImage) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            guard isAvailable else { return nil }
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                               instructions: "You look at screenshots and answer briefly and factually.")
            do {
                let response = try await session.respond(to: Prompt {
                    instruction
                    Attachment(limited(image))
                })
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                NSLog("iScreen: on-device AI failed: \(error)")
                return nil
            }
        }
        #endif
        return nil
    }

    /// Keeps the model input reasonably small for speed.
    private static func limited(_ image: CGImage, maxSide: Int = 1600) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let factor = CGFloat(maxSide) / CGFloat(longest)
        let w = Int(CGFloat(image.width) * factor), h = Int(CGFloat(image.height) * factor)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
