import Foundation
import CoreGraphics
import CoreImage
import CoreText
import Vision

// Deliberately independent of App/Core/OCR worker code. Keeping this helper's
// executable identity stable lets macOS reuse its compiled recognition models
// when an unrelated part of the app is updated.
enum VisionRecognition {
    typealias Perform = (VNRequest, () throws -> Void) -> Bool

    static func defaultPerform(_ request: VNRequest, _ work: () throws -> Void) -> Bool {
        do { try work(); return true } catch { return false }
    }

    static func visionPreparationImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 320, height: 96, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 96))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W3" as CFString, 30, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "今日は晴れです。", attributes: attributes))
        context.textPosition = CGPoint(x: 10, y: 34)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func prepare(isCancelled: () -> Bool = { false }, perform: Perform = defaultPerform) {
        guard !isCancelled(), let image = visionPreparationImage(), !isCancelled() else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        _ = perform(request) {
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
    }

    static func textHints(in image: CGImage, isCancelled: () -> Bool = { false }, perform: Perform = defaultPerform) -> [[String: Any]] {
        guard !isCancelled() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        guard perform(request, {
            try VNImageRequestHandler(cgImage: image).perform([request])
        }) else { return [] }
        var refinements = 0
        var hints: [[String: Any]] = []
        for observation in request.results ?? [] {
            guard !isCancelled() else { return [] }
            guard var candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                  candidate.string.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }) else { continue }
            let rect = observation.boundingBox
            // Small slanted signs benefit from a level, enlarged line crop. Keep
            // ordinary dialogue on the single full-page pass.
            if candidate.confidence < 0.7, rect.width * CGFloat(image.width) > rect.height * CGFloat(image.height) * 1.6,
               rect.height < 0.10, candidate.string.count >= 3, refinements < 6 {
                refinements += 1
                func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * CGFloat(image.width), y: p.y * CGFloat(image.height)) }
                let straight = CIImage(cgImage: image).applyingFilter("CIPerspectiveCorrection", parameters: [
                    "inputTopLeft": point(observation.topLeft), "inputTopRight": point(observation.topRight),
                    "inputBottomLeft": point(observation.bottomLeft), "inputBottomRight": point(observation.bottomRight)
                ]).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
                let line = VNRecognizeTextRequest()
                line.recognitionLevel = .accurate; line.recognitionLanguages = ["ja-JP"]; line.usesLanguageCorrection = true
                if perform(line, {
                    try VNImageRequestHandler(ciImage: straight).perform([line])
                }),
                   let improved = line.results?.first?.topCandidates(1).first,
                   improved.confidence > candidate.confidence, improved.string.count >= candidate.string.count / 2 {
                    candidate = improved
                }
            }
            guard !isCancelled() else { return [] }
            hints.append(["text": candidate.string, "confidence": candidate.confidence,
                    "box": [rect.minX * Double(image.width), (1-rect.maxY) * Double(image.height),
                            rect.maxX * Double(image.width), (1-rect.minY) * Double(image.height)]])
        }
        return isCancelled() ? [] : hints
    }

}
