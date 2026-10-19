import AppKit
import Vision

/// Free, offline text recognition (Apple Vision). Rebuilds lines and paragraphs from the layout.
enum TextRecognizer {
    /// Vision loads its models on first use (~25 s once per app launch), so do that in the
    /// background at startup; afterwards recognition takes well under a second.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
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
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }

        struct Item { let text: String; let box: CGRect } // normalized, bottom-left origin
        let items = (request.results ?? []).compactMap { observation -> Item? in
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
