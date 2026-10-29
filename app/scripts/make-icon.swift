// Renders the Jancast app icon (1024×1024 PNG) with AppKit: a night-navy
// tile with a TV whose picture is a film's colour timeline (vertical bands
// from amber through rose to blue), its light glowing around it and spilling
// onto the floor below. Bold enough to read at 16 px in a list.
// Usage: swift make-icon.swift <out.png>     (build-app.sh uses Resources/AppIcon.png made by it)
import AppKit
import CoreImage

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// The colour timeline on the screen.
let bands: [UInt32] = [0xFFB547, 0xFF9150, 0xFF6F73, 0xE466AE, 0x3FA9B5, 0x2A9BE3, 0x2F6BEA]

// macOS icon grid: an 824 pt tile centred in 1024, with its shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// The TV (AppKit coordinates: y up).
let bezel = CGRect(x: 250, y: 372, width: 524, height: 334)
let screen = bezel.insetBy(dx: 18, dy: 18)

/// The bands as an image of the screen's size, for drawing and for the glow.
func bandsImage(_ rect: CGRect, radius: CGFloat) -> NSImage {
    NSImage(size: rect.size, flipped: false) { r in
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        let w = r.width / CGFloat(bands.count)
        for (i, hex) in bands.enumerated() {
            let band = CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: r.height)
            NSGradient(colors: [rgb(hex).blended(withFraction: 0.05, of: .black)!,
                                rgb(hex).blended(withFraction: 0.12, of: .white)!])!
                .draw(in: band, angle: 90)
        }
        return true
    }
}

func blurred(_ image: NSImage, radius: Double) -> CGImage? {
    guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
    // Not clamped: past the picture's edge the light fades out instead of
    // repeating the edge colours across the tile.
    let padded = ci.applyingGaussianBlur(sigma: radius)
        .cropped(to: ci.extent.insetBy(dx: -radius * 3, dy: -radius * 3))
    return CIContext().createCGImage(padded, from: padded.extent)
}

let screenBands = bandsImage(screen, radius: 16)

let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // Tile and its shadow.
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    rgb(0x111D3A).setFill()
    tilePath.fill()
    ctx.restoreGState()

    ctx.saveGState()
    tilePath.addClip()
    // Night navy, a little lighter at the top.
    NSGradient(colors: [rgb(0x1B2B52), rgb(0x0E1832)])!.draw(in: tile, angle: -90)

    // The screen's light: a wide soft glow behind the TV...
    if let glow = blurred(bandsImage(screen.insetBy(dx: -10, dy: -10), radius: 30), radius: 46) {
        let r = CGRect(x: screen.midX - CGFloat(glow.width) / 2, y: screen.midY - CGFloat(glow.height) / 2,
                       width: CGFloat(glow.width), height: CGFloat(glow.height))
        ctx.setAlpha(0.7)
        ctx.draw(glow, in: r)
        ctx.setAlpha(1)
    }
    // ...and its spill on the floor under the stand.
    if let spill = blurred(bandsImage(CGRect(x: 0, y: 0, width: screen.width * 0.9, height: 40), radius: 20),
                           radius: 26) {
        let w = CGFloat(spill.width), h = CGFloat(spill.height)
        ctx.setAlpha(0.6)
        ctx.draw(spill, in: CGRect(x: screen.midX - w / 2, y: 300 - h / 2, width: w, height: h))
        ctx.setAlpha(1)
    }

    // Stand: neck and foot.
    rgb(0x0B1326).setFill()
    NSBezierPath(rect: CGRect(x: bezel.midX - 26, y: bezel.minY - 30, width: 52, height: 34)).fill()
    NSBezierPath(roundedRect: CGRect(x: bezel.midX - 130, y: bezel.minY - 48, width: 260, height: 20),
                 xRadius: 8, yRadius: 8).fill()

    // Bezel with a faint rim, then the picture.
    let bezelPath = NSBezierPath(roundedRect: bezel, xRadius: 28, yRadius: 28)
    rgb(0x0A1124).setFill()
    bezelPath.fill()
    NSColor.white.withAlphaComponent(0.08).setStroke()
    bezelPath.lineWidth = 3
    bezelPath.stroke()
    screenBands.draw(in: screen)
    // A soft sheen across the top of the glass.
    NSBezierPath(roundedRect: screen, xRadius: 16, yRadius: 16).addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: screen.height / 2), angle: -90)
    ctx.restoreGState()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
