import AppKit
import CoreText

enum ShioriIcon {
    static let resourceName = "ShioriAppIcon"
    private static let menuSize = NSSize(width: 22, height: 18)

    // Package the approved first Apple-style artwork without redrawing it.
    // The source rectangle excludes the presentation background; the outer
    // mask gives the installed icon the standard transparent Mac canvas.
    static func applicationImage(sourceURL: URL) throws -> NSImage {
        guard let source = NSImage(contentsOf: sourceURL),
              let pixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              pixels.width == 1254, pixels.height == 1254 else {
            throw NSError(domain: "ShioriIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot load the approved icon artwork"])
        }
        source.size = NSSize(width: pixels.width, height: pixels.height)
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 224, cornerHeight: 224, transform: nil))
            context.clip()
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: tile, from: CGRect(x: 139, y: 146, width: 976, height: 976),
                        operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private static func dialogue(x: CGFloat, y: CGFloat, right: Bool) -> CGPath {
        let w: CGFloat = 13.5, h: CGFloat = 10, r: CGFloat = 2.8
        let k: CGFloat = 0.5522847498307936
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r, y: h))
        p.addLine(to: CGPoint(x: w-r, y: h))
        p.addCurve(to: CGPoint(x: w, y: h-r),
                   control1: CGPoint(x: w-r+r*k, y: h), control2: CGPoint(x: w, y: h-r+r*k))
        p.addLine(to: CGPoint(x: w, y: r))
        p.addCurve(to: CGPoint(x: w-r, y: 0),
                   control1: CGPoint(x: w, y: r-r*k), control2: CGPoint(x: w-r+r*k, y: 0))
        p.addLine(to: CGPoint(x: 6.1, y: 0))
        p.addLine(to: CGPoint(x: 3.7, y: -1.95))
        p.addQuadCurve(to: CGPoint(x: 3.3, y: -1.7), control: CGPoint(x: 3.3, y: -2.3))
        p.addLine(to: CGPoint(x: 3.3, y: 0))
        p.addLine(to: CGPoint(x: r, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: r),
                   control1: CGPoint(x: r-r*k, y: 0), control2: CGPoint(x: 0, y: r-r*k))
        p.addLine(to: CGPoint(x: 0, y: h-r))
        p.addCurve(to: CGPoint(x: r, y: h),
                   control1: CGPoint(x: 0, y: h-r+r*k), control2: CGPoint(x: r-r*k, y: h))
        p.closeSubpath()
        var transform = CGAffineTransform(a: right ? -1 : 1, b: 0, c: 0, d: 1,
                                          tx: x + (right ? w : 0), ty: y)
        return p.copy(using: &transform)!
    }

    private static let front = dialogue(x: 1, y: 6.3, right: false)
    private static let rear = dialogue(x: 7.6, y: 3.6, right: true)
    private static let foregroundWithCutout: CGPath = {
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 1, nil)
        var character: UniChar = 0x3042, index: CGGlyph = 0
        precondition(CTFontGetGlyphsForCharacters(font, &character, &index, 1) && index != 0)
        let outline = CTFontCreatePathForGlyph(font, index, nil)!
        let bounds = outline.boundingBoxOfPath
        let scale = 7.8 / bounds.height
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: 7.75 - bounds.midX * scale, ty: 11.3 - bounds.midY * scale)
        let combined = CGMutablePath()
        combined.addPath(front)
        combined.addPath(outline.copy(using: &transform)!)
        return combined
    }()

    static func menuImage() -> NSImage {
        let image = NSImage(size: menuSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            // Keep the transparent kana and separation gap inside the image,
            // including when AppKit invokes the drawing handler in a view.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer() }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.2); context.setLineCap(.round); context.setLineJoin(.round)
            context.addPath(rear); context.strokePath()
            context.setBlendMode(.clear)
            context.addPath(front); context.setLineWidth(1.5); context.drawPath(using: .fillStroke)
            context.setBlendMode(.normal)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(foregroundWithCutout); context.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func svgPath(_ path: CGPath) -> String {
        var values: [String] = []
        func point(_ p: CGPoint) -> String { String(format: "%.5g %.5g", Double(p.x), Double(p.y)) }
        path.applyWithBlock { item in
            let e = item.pointee, p = e.points
            switch e.type {
            case .moveToPoint: values.append("M" + point(p[0]))
            case .addLineToPoint: values.append("L" + point(p[0]))
            case .addQuadCurveToPoint: values.append("Q" + point(p[0]) + " " + point(p[1]))
            case .addCurveToPoint: values.append("C" + point(p[0]) + " " + point(p[1]) + " " + point(p[2]))
            case .closeSubpath: values.append("Z")
            @unknown default: break
            }
        }
        return values.joined(separator: " ")
    }

    static var menuSVG: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="22" height="18" viewBox="0 0 22 18">
          <defs><mask id="rearMask" maskUnits="userSpaceOnUse" x="0" y="0" width="22" height="18">
            <rect width="22" height="18" fill="white"/>
            <path d="\(svgPath(front))" fill="black" stroke="black" stroke-width="1.5" stroke-linejoin="round"/>
          </mask></defs>
          <g transform="translate(0 18) scale(1 -1)">
            <g mask="url(#rearMask)">
              <path d="\(svgPath(rear))" fill="none" stroke="black" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
            </g>
            <path d="\(svgPath(foregroundWithCutout))" fill="black" fill-rule="evenodd"/>
          </g>
        </svg>
        """
    }
}
