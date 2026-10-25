import AppKit

@main
enum GenerateIcons {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ShioriIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: generate-icons REPOSITORY_PATH"])
        }
        let files = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = files.temporaryDirectory.appendingPathComponent("shiori-icons-" + UUID().uuidString)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        let iconset = temporary.appendingPathComponent("Shiori.iconset")
        try files.createDirectory(at: iconset, withIntermediateDirectories: true)
        let artwork = try ShioriIcon.applicationImage(sourceURL: root.appendingPathComponent("Resources/ShioriArtwork.png"))
        for (name, pixels) in [("16x16",16), ("16x16@2x",32), ("32x32",32), ("32x32@2x",64),
                               ("128x128",128), ("128x128@2x",256), ("256x256",256), ("256x256@2x",512),
                               ("512x512",512), ("512x512@2x",1024)] {
            try png(artwork, pixels: pixels).write(to: iconset.appendingPathComponent("icon_" + name + ".png"))
        }
        let artworkData = try png(artwork, pixels: 1024)
        try artworkData.write(to: root.appendingPathComponent("Resources/" + ShioriIcon.resourceName + ".png"))
        try png(artwork, pixels: 256).write(to: root.appendingPathComponent("Design/ShioriIcon-preview.png"))
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <image width="1024" height="1024" href="data:image/png;base64,\(artworkData.base64EncodedString())"/>
        </svg>
        """
        try svg.write(to: root.appendingPathComponent("Design/ShioriIcon.svg"), atomically: true, encoding: .utf8)
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        command.arguments = ["-c", "icns", iconset.path, "-o",
                             root.appendingPathComponent("Resources/" + ShioriIcon.resourceName + ".icns").path]
        try command.run(); command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw NSError(domain: "ShioriIcon", code: 2) }

        let menu = ShioriIcon.menuImage()
        try png(menu, pixels: 22).write(to: root.appendingPathComponent("Design/ShioriIcon-menubar-1x.png"))
        try png(menu, pixels: 44).write(to: root.appendingPathComponent("Design/ShioriIcon-menubar.png"))
        try ShioriIcon.menuSVG.write(to: root.appendingPathComponent("Design/ShioriIcon-menubar.svg"),
                                    atomically: true, encoding: .utf8)
        let preview = NSImage(size: NSSize(width: 320, height: 80), flipped: false) { _ in
            NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 160, height: 80).fill()
            NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1).setFill()
            NSRect(x: 160, y: 0, width: 160, height: 80).fill()
            for (x, color) in [(CGFloat(69), NSColor.black), (CGFloat(229), NSColor.white)] {
                guard let mask = menu.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let context = NSGraphicsContext.current?.cgContext else { return false }
                let rect = CGRect(x: x, y: 31, width: 22, height: 18)
                context.saveGState()
                context.clip(to: rect, mask: mask)
                context.setFillColor(color.cgColor); context.fill(rect)
                context.restoreGState()
            }
            return true
        }
        try png(preview, pixels: 640).write(to: root.appendingPathComponent("Design/ShioriIcon-menubar-preview.png"))
        print("Generated approved app artwork and 22×18 pt template menu icon.")
    }

    private static func png(_ image: NSImage, pixels: Int) throws -> Data {
        let height = Int(CGFloat(pixels) * image.size.height / image.size.width)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "ShioriIcon", code: 3) }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "ShioriIcon", code: 4) }
        return data
    }
}
