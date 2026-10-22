import AppKit
import Vision

/// Free, offline text recognition (Apple Vision). Rebuilds lines and paragraphs from the layout.
enum TextRecognizer {
    private static var keepWarmTimer: DispatchSourceTimer?

    /// Vision loads its models on first use (~30 s), and macOS may unload them again after a long idle.
    /// So warm up at startup and refresh every 20 minutes (a ~0.1 s job when warm); recognition then
    /// stays instant.
    static func warmUp() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 20 * 60, leeway: .seconds(60))
        timer.setEventHandler {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: 160, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 40))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Warm up", attributes: [
                .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black,
            ]))
            ctx.textPosition = CGPoint(x: 10, y: 12)
            CTLineDraw(line, ctx)
            if let image = ctx.makeImage() { _ = recognize(image) }
        }
        timer.resume()
        keepWarmTimer = timer
    }

    /// Recognizes text, trying progressively simpler settings if a pass fails or finds nothing.
    static func recognize(_ image: CGImage) -> String {
        guard let input = normalized(image) else {
            Log.write("OCR: couldn't prepare a \(image.width)×\(image.height) image")
            return ""
        }
        let passes: [(name: String, configure: (VNRecognizeTextRequest) -> Void)] = [
            ("accurate, auto language", {
                $0.recognitionLevel = .accurate
                $0.usesLanguageCorrection = true
                $0.automaticallyDetectsLanguage = true
            }),
            ("accurate, en+ru", {
                $0.recognitionLevel = .accurate
                $0.usesLanguageCorrection = false
                $0.recognitionLanguages = ["en-US", "ru-RU"]
            }),
            ("fast", {
                $0.recognitionLevel = .fast
                $0.usesLanguageCorrection = false
            }),
        ]
        for (index, pass) in passes.enumerated() {
            let request = VNRecognizeTextRequest()
            pass.configure(request)
            do {
                try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
            } catch {
                Log.write("OCR pass '\(pass.name)' failed on \(input.width)×\(input.height): \(error)")
                continue
            }
            let text = layout(request.results ?? [])
            if !text.isEmpty {
                if index > 0 { Log.write("OCR succeeded with fallback pass '\(pass.name)'") }
                return text
            }
            Log.write("OCR pass '\(pass.name)' found no text in \(input.width)×\(input.height)")
        }
        return ""
    }

    /// Redraws into a plain 8-bit sRGB bitmap (screen captures can be IOSurface-backed or in formats
    /// Vision handles poorly) and enlarges small crops so small text is legible to the recognizer.
    private static func normalized(_ image: CGImage) -> CGImage? {
        let scale = max(image.width, image.height) < 600 ? 2 : 1
        let w = image.width * scale, h = image.height * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Item { let text: String; let box: CGRect } // normalized, bottom-left origin
        let items = observations.compactMap { observation -> Item? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Item(text: text, box: observation.boundingBox)
        }
        .sorted { $0.box.midY > $1.box.midY }

        // Group fragments whose vertical centers fall inside the same line band.
        var lines: [[Item]] = []
        for item in items {
            if let last = lines.last?.first,
               abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }

        var output: [String] = []
        var previousLine: [Item]?
        for line in lines {
            let sorted = line.sorted { $0.box.minX < $1.box.minX }
            // Keep a blank line between paragraphs (a vertical gap bigger than a line height).
            if let previousLine, let above = previousLine.first, let current = sorted.first,
               above.box.minY - current.box.maxY > above.box.height * 1.2 {
                output.append("")
            }
            var text = sorted[0].text
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                // Large horizontal gaps (table columns) become tabs.
                let charWidth = a.box.width / CGFloat(max(a.text.count, 1))
                text += (b.box.minX - a.box.maxX) > charWidth * 4 ? "\t" : " "
                text += b.text
            }
            output.append(text)
            previousLine = sorted
        }
        return output.joined(separator: "\n")
    }
}
