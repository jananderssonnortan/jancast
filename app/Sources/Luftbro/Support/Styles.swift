import SwiftUI

extension AnyTransition {
    /// Rows that come in from below (Now Playing bar, Up Next): sliding, or
    /// only fading when Reduce Motion is on (System Settings → Accessibility
    /// → Display).
    static func slideUp(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}

extension ShapeStyle where Self == Color {
    /// Secondary text on the film's wash (remote, library, player rows): the
    /// system grey. A plain colour, not a hierarchy level:
    /// `Text.foregroundStyle(.secondary)` ignores levels set further up.
    static var washSecondary: Color { Color(nsColor: .secondaryLabelColor) }
}
