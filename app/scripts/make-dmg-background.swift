// Renders the disk image window's background (640×440 pt) with AppKit:
// "Drag Jancast to Applications" with an arrow between the two icons, and
// what to do when macOS won't open Jancast the first time.
// Usage: swift make-dmg-background.swift <out.png> <scale>   (1 or 2)
// The icons sit where package-app.sh (dmg-settings.py) puts them: centres at
// x 170 and 470, y 170 from the top. Everything stays in the top 375 pt: the
// window is 440 pt with its title bar, and macOS 26 Finder adds a path bar.
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "background.png"
let scale = args.count > 2 ? CGFloat(Double(args[2]) ?? 1) : 1
let w: CGFloat = 640, h: CGFloat = 440

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The icon's blue to violet, lighter: Finder writes the file names under the
// icons in black (light mode) or white (dark mode), and both read on this.
NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.44, blue: 0.92, alpha: 1),
    NSColor(srgbRed: 0.50, green: 0.37, blue: 0.88, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -60)

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, in rect: NSRect, lineSpacing: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = lineSpacing
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: style,
    ]).draw(in: rect)
}

draw("Drag Jancast to Applications", size: 22, weight: .semibold, alpha: 1,
     in: NSRect(x: 0, y: h - 72, width: w, height: 34))

// Arrow between the icons (y 170 from the top).
let y = h - 170
NSColor.white.withAlphaComponent(0.85).set()
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 262, y: y))
shaft.line(to: NSPoint(x: 361, y: y))
shaft.lineWidth = 5
shaft.lineCapStyle = .butt
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 384, y: y))
head.line(to: NSPoint(x: 360, y: y + 15))
head.line(to: NSPoint(x: 360, y: y - 15))
head.close()
head.fill()

// The first open: macOS's warning and the way past it.
let panel = NSRect(x: 36, y: h - 370, width: w - 72, height: 104)
NSColor.black.withAlphaComponent(0.24).setFill()
NSBezierPath(roundedRect: panel, xRadius: 14, yRadius: 14).fill()
draw("The first time, macOS won’t open Jancast",
     size: 13.5, weight: .semibold, alpha: 1, in: panel.insetBy(dx: 20, dy: 0).offsetBy(dx: 0, dy: -12))
draw("Open it once and click Done when macOS refuses (it isn’t notarized by Apple).\n"
     + "Then System Settings → Privacy & Security → Open Anyway, and confirm.\n"
     + "The source is open: github.com/jananderssonnortan/jancast",
     size: 12, weight: .regular, alpha: 0.92, in: panel.insetBy(dx: 20, dy: 0).offsetBy(dx: 0, dy: -33), lineSpacing: 2)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
