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
        var plain = "Describe this screenshot in one or two short, factual sentences (max 40 words). "
        plain += "Mention what app or website it is and the key information visible."
        if let label = context.label { plain += " It was taken from: \(label)." }
        var detailed = plain
        if let visibleText, !visibleText.isEmpty {
            detailed += "\n\nText recognized in the screenshot (copy names and titles exactly from here, in their original alphabet):\n"
            detailed += String(visibleText.prefix(1500))
        }
        return await ask(detailed, fallback: plain, image: image, purpose: "description")
    }

    /// A 3–6 word title for a file name, or nil.
    static func shortName(_ image: CGImage, context: SourceContext) async -> String? {
        var prompt = "Give this screenshot a short descriptive title of 3 to 6 words in Title Case. "
        prompt += "Reply with the title only: no quotes, no punctuation, no file extension."
        if let app = context.app { prompt += " Don't include the app name (\(app))." }
        guard let answer = await ask(prompt, fallback: prompt, image: image, purpose: "file name") else { return nil }
        let firstLine = answer.components(separatedBy: .newlines).first ?? answer
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.:*#").union(.whitespaces))
        return cleaned.isEmpty || cleaned.count > 60 ? nil : cleaned
    }

    /// The model can refuse or throttle requests now and then — especially from a background app like
    /// iScreen — so try up to three times: the full prompt twice, then a lighter prompt with a smaller image.
    private static func ask(_ prompt: String, fallback: String, image: CGImage, purpose: String) async -> String? {
        guard isAvailable else { return nil }
        let attempts: [(prompt: String, maxSide: Int, delay: Double)] = [
            (prompt, 1600, 0), (prompt, 1600, 1.5), (fallback, 1024, 1.5),
        ]
        for (index, attempt) in attempts.enumerated() {
            if attempt.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt.delay * 1_000_000_000)) }
            let input = limited(image, maxSide: attempt.maxSide)
            let answer = await withTimeout(seconds: 15) { await respond(attempt.prompt, image: input, purpose: purpose) }
            if let answer {
                if index > 0 { Log.write("AI \(purpose) succeeded on attempt \(index + 1)") }
                return answer
            }
        }
        Log.write("AI \(purpose): all attempts failed")
        return nil
    }

    private static func respond(_ prompt: String, image: CGImage, purpose: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                               instructions: "You look at screenshots and answer briefly and factually.")
            do {
                let response = try await session.respond(to: Prompt {
                    prompt
                    Attachment(image)
                })
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                Log.write("AI \(purpose) attempt failed: \(error)")
                return nil
            }
        }
        #endif
        return nil
    }

    /// Returns nil if `operation` takes longer than `seconds`.
    private static func withTimeout<T>(seconds: Double, _ operation: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { Log.write("AI request returned nothing within \(Int(seconds)) s") }
            return first
        }
    }

    /// Keeps the model input reasonably small for speed.
    private static func limited(_ image: CGImage, maxSide: Int) -> CGImage {
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
