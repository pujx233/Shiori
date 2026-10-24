import AppKit
import CoreText

// A single Japanese kana, with a small-size menu-bar face and an editorial app face.
enum ShioriIcon {
    private static let japanese = glyph(0x3042, fontName: "HiraginoSans-W6")
    private static let editorialJapanese = glyph(0x3042, fontName: "YuMin-Extrabold")
    private static let applicationFrame = CGRect(x: 240, y: 220, width: 544, height: 600)

    private static func glyph(_ character: UniChar, fontName: String) -> CGPath {
        for name in [fontName, "HiraginoSans-W6"] {
            guard let face = NSFont(name: name, size: 1) else { continue }
            let font = CTFontCreateWithName(face.fontName as CFString, 1, nil)
            var value = character, glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font, &value, &glyph, 1), glyph != 0,
               let outline = CTFontCreatePathForGlyph(font, glyph, nil) { return outline }
        }
        return CGMutablePath()
    }

    private static func fitting(_ path: CGPath, in frame: CGRect) -> (CGFloat, CGFloat, CGFloat) {
        let bounds = path.boundingBoxOfPath
        let scale = min(frame.width / max(bounds.width, 0.001), frame.height / max(bounds.height, 0.001))
        return (frame.midX - bounds.midX * scale, frame.midY - bounds.midY * scale, scale)
    }

    private static func draw(_ path: CGPath, in frame: CGRect, context: CGContext) {
        let (x, y, scale) = fitting(path, in: frame)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: x, y: y); context.scaleBy(x: scale, y: scale)
        context.addPath(path); context.fillPath()
    }

    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            context.setFillColor(NSColor.black.cgColor)
            draw(japanese, in: CGRect(x: 2, y: 2.2, width: 14, height: 13.6), context: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func applicationImage() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                    xRadius: 200, yRadius: 200)
            NSGradient(starting: NSColor(srgbRed: 0.985, green: 0.981, blue: 0.958, alpha: 1),
                       ending: NSColor(srgbRed: 0.882, green: 0.945, blue: 0.910, alpha: 1))!
                .draw(in: tile, angle: -70)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            tile.lineWidth = 1.5; tile.stroke()
            context.setFillColor(NSColor(srgbRed: 0.10, green: 0.31, blue: 0.28, alpha: 1).cgColor)
            draw(editorialJapanese, in: applicationFrame, context: context)
            return true
        }
    }

    private static func svgPath(_ path: CGPath) -> String {
        var result: [String] = []
        func point(_ value: CGPoint) -> String {
            String(format: "%.5g %.5g", Double(value.x), Double(value.y))
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee, p = pointer.pointee.points
            switch element.type {
            case .moveToPoint: result.append("M" + point(p[0]))
            case .addLineToPoint: result.append("L" + point(p[0]))
            case .addQuadCurveToPoint: result.append("Q" + point(p[0]) + " " + point(p[1]))
            case .addCurveToPoint: result.append("C" + point(p[0]) + " " + point(p[1]) + " " + point(p[2]))
            case .closeSubpath: result.append("Z")
            @unknown default: break
            }
        }
        return result.joined(separator: " ")
    }

    private static func svgGlyph(_ path: CGPath, frame: CGRect) -> String {
        let (x, y, scale) = fitting(path, in: frame)
        return "<path d=\"\(svgPath(path))\" transform=\"translate(\(x) \(y)) scale(\(scale))\" fill=\"#1A4F47\"/>"
    }

    static var svg: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <defs><linearGradient id="jade" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#FBFAF4"/><stop offset="1" stop-color="#E1F1E8"/></linearGradient></defs>
          <rect x="64" y="64" width="896" height="896" rx="200" fill="url(#jade)"/>
          <g transform="translate(0 1024) scale(1 -1)">
            \(svgGlyph(editorialJapanese, frame: applicationFrame))
          </g>
        </svg>
        """
    }
}
