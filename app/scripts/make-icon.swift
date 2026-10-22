// Renders the Jancast app icon (1024×1024 PNG) with AppKit.
// Usage: swift make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle-ish rounded rect centred in 1024 with shadow.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
path.fill()
ctx.restoreGState()

path.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.45, green: 0.22, blue: 0.85, alpha: 1),
])!
gradient.draw(in: rect, angle: -60)

// Subtle "signal" waves.
NSColor.white.withAlphaComponent(0.10).setStroke()
for i in 0..<4 {
    let r = CGFloat(260 + i * 110)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: size / 2, y: 300), radius: r, startAngle: 35, endAngle: 145)
    arc.lineWidth = 26
    arc.stroke()
}

// SF Symbol glyph.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = sym.size
    let r = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height)
    sym.draw(in: r)
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
