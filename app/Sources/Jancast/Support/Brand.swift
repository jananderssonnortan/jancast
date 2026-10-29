import AppKit
import SwiftUI

/// Jancast's own look, from the icon: a dark room at night lit only by a
/// screen's warm glow (amber to rose). It shows where no film sets the colours
/// (nothing loaded yet, starting, Settings) and in the disk image; a loaded
/// film's colours still take over the window (Ambience).
@MainActor
enum Brand {
    /// The icon's screen, top and bottom.
    static let amber = NSColor(srgbRed: 0.91, green: 0.59, blue: 0.29, alpha: 1)
    static let rose = NSColor(srgbRed: 0.76, green: 0.44, blue: 0.54, alpha: 1)
    /// The room.
    static let night = NSColor(srgbRed: 0.06, green: 0.10, blue: 0.22, alpha: 1)

    /// The accent: the glow, bright on dark; in light mode deep enough for
    /// white text on it and for itself as text (as Ambience's film tints).
    static let tint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.93, green: 0.58, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.34, blue: 0.24, alpha: 1)
    })

    /// The window's look with no film: the room, lit from the top.
    static let look = Ambience.Look(backdrop: backdrop, tint: tint)

    /// Small on purpose, like Ambience's washes: drawn scaled up, it is all
    /// soft gradients anyway.
    private static let backdrop: NSImage = {
        let size = NSSize(width: 48, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            night.setFill()
            rect.fill()
            // The screen's light from above, warm in the middle. Strong: the
            // window veils its backdrop for the text on it (AmbientBackdrop).
            let glow = NSGradient(colors: [amber, rose.withAlphaComponent(0.8), night.withAlphaComponent(0)],
                                  atLocations: [0, 0.4, 1], colorSpace: .sRGB)!
            glow.draw(fromCenter: NSPoint(x: rect.midX, y: rect.maxY + 4), radius: 0,
                      toCenter: NSPoint(x: rect.midX, y: rect.maxY + 4), radius: rect.height * 0.95, options: [])
            return true
        }
    }()
}
