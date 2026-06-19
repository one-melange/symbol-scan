import Vision
import AppKit

struct OCREngine {

    struct RecognizedText {
        let fullText: String
        let lines: [String]
        let boundingBoxes: [(String, CGRect)] // (text, normalized rect)
    }

    /// Extract all text from a CGImage using Vision's accurate recognition.
    static func recognize(image: CGImage) async throws -> RecognizedText {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: RecognizedText(fullText: "", lines: [], boundingBoxes: []))
                    return
                }

                var lines: [String] = []
                var boxes: [(String, CGRect)] = []

                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    lines.append(candidate.string)
                    boxes.append((candidate.string, obs.boundingBox))
                }

                let full = lines.joined(separator: "\n")
                continuation.resume(returning: RecognizedText(fullText: full, lines: lines, boundingBoxes: boxes))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // faster; we want raw text, not autocorrected
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Extract the partial symbol name after @ or # on the current line.
    /// e.g. "@AuthM" → "AuthM", "#src/u" → "src/u"
    static func extractSymbolQuery(from lines: [String], prefix: String) -> String? {
        for line in lines.reversed() { // most recent line first
            if let range = line.range(of: prefix) {
                let after = String(line[range.upperBound...])
                    .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "/" || $0 == "." || $0 == "-" })
                if !after.isEmpty {
                    return String(after)
                }
            }
        }
        return nil
    }
}
