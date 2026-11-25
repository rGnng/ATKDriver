import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mediumBlue = NSColor(srgbRed: 0.10, green: 0.32, blue: 0.78, alpha: 1)
let darkBlue = NSColor(srgbRed: 0.09, green: 0.16, blue: 0.47, alpha: 1)
let lightBlue = NSColor(srgbRed: 0.36, green: 0.66, blue: 0.99, alpha: 1)

func render(_ size: Int) throws -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let scale = rect.width / 1024
        let t = AffineTransform(scale: scale)
        func path(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.transform(using: t)
            return path
        }

        let tile = path(in: NSRect(x: 90, y: 90, width: 844, height: 844), radius: 190)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 29 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        mediumBlue.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [darkBlue, mediumBlue, lightBlue])!.draw(in: tile, angle: 52)

        let rim = path(in: NSRect(x: 92, y: 92, width: 840, height: 840), radius: 188)
        rim.lineWidth = 3 * scale
        NSColor.white.withAlphaComponent(0.24).setStroke()
        rim.stroke()

        let mouse = path(in: NSRect(x: 352, y: 240, width: 320, height: 544), radius: 160)
        NSGradient(starting: NSColor(srgbRed: 0.78, green: 0.87, blue: 1, alpha: 1), ending: .white)!
            .draw(in: mouse, angle: 80)
        let wheel = path(in: NSRect(x: 494, y: 579, width: 36, height: 94), radius: 18)
        darkBlue.setFill()
        wheel.fill()
        let groove = path(in: NSRect(x: 352, y: 554, width: 320, height: 10), radius: 5)
        mediumBlue.withAlphaComponent(0.52).setFill()
        groove.fill()
        return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 1 ? "" : "@2x"
        let destination = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try render(size * density).write(to: destination)
    }
}
