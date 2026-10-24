import AppKit
import CoreText

// Keep the application and menu-bar icons on the same rounded kana outline.
enum ShioriIcon {
    private static let japanese = glyph(0x3042, fontName: "HiraMaruProN-W4")
    private static let applicationFrame = CGRect(x: 232, y: 218, width: 560, height: 600)

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
            NSGradient(starting: NSColor(srgbRed: 46 / 255.0, green: 115 / 255.0, blue: 105 / 255.0, alpha: 1),
                       ending: NSColor(srgbRed: 17 / 255.0, green: 61 / 255.0, blue: 64 / 255.0, alpha: 1))!
                .draw(in: tile, angle: -90)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            tile.lineWidth = 1.5; tile.stroke()
            context.setFillColor(NSColor(srgbRed: 249 / 255.0, green: 251 / 255.0, blue: 250 / 255.0, alpha: 1).cgColor)
            draw(japanese, in: applicationFrame, context: context)
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
        return "<path d=\"\(svgPath(path))\" transform=\"translate(\(x) \(y)) scale(\(scale))\" fill=\"#F9FBFA\"/>"
    }

    static var svg: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <defs><linearGradient id="jade" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#2E7369"/><stop offset="1" stop-color="#113D40"/></linearGradient></defs>
          <rect x="64" y="64" width="896" height="896" rx="200" fill="url(#jade)"/>
          <rect x="64" y="64" width="896" height="896" rx="200" fill="none" stroke="white" stroke-opacity="0.12" stroke-width="1.5"/>
          <g transform="translate(0 1024) scale(1 -1)">
            \(svgGlyph(japanese, frame: applicationFrame))
          </g>
        </svg>
        """
    }
}
