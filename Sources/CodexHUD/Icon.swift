import AppKit

func makeIconSet(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
            let shape = NSBezierPath(roundedRect: NSRect(x: 14, y: 14, width: 484, height: 484), xRadius: 110, yRadius: 110)
            NSGradient(starting: NSColor(red: 0.15, green: 0.18, blue: 0.22, alpha: 1), ending: NSColor(red: 0.04, green: 0.06, blue: 0.08, alpha: 1))?.draw(in: shape, angle: -90)
            NSColor.white.withAlphaComponent(0.2).setStroke(); shape.lineWidth = 2; shape.stroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 74, y: 115, width: 364, height: 282), xRadius: 42, yRadius: 42)
            NSColor.white.withAlphaComponent(0.12).setFill(); frame.fill()
            ("W" as NSString).draw(at: NSPoint(x: 106, y: 292), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 50, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            ("HUD" as NSString).draw(at: NSPoint(x: 275, y: 307), withAttributes: [.font: NSFont.systemFont(ofSize: 25, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
            NSColor.white.withAlphaComponent(0.17).setFill(); NSBezierPath(roundedRect: NSRect(x: 108, y: 247, width: 296, height: 13), xRadius: 7, yRadius: 7).fill()
            NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: NSRect(x: 108, y: 247, width: 196, height: 13), xRadius: 7, yRadius: 7).fill()
            for x in [130, 250, 370] {
                NSColor.white.withAlphaComponent(0.65).setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: 177, width: 14, height: 14)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try data.write(to: directory.appendingPathComponent(filename))
            }
        }
    }
}
