import AVFoundation
import SwiftUI

/// The subtitle lines showing in the This Mac window. AVKit's own rendering
/// is switched off (AVPlayerItemLegibleOutput.suppressesPlayerRendering):
/// inside the picture the control bar would cover the lines and the picture
/// filters dim them; drawn here they move up above the bar while it shows.
@MainActor @Observable
final class PlayerSubtitleState {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: AttributedString
        /// Placed near the top by the cue (WebVTT line setting, e.g. a sign
        /// translation while dialogue runs at the bottom).
        let top: Bool
    }

    private(set) var lines: [Line] = []

    /// What AVFoundation says is due now; empty clears.
    func show(_ strings: [NSAttributedString]) {
        lines = strings.enumerated().compactMap { i, s in
            let line = Self.line(s)
            guard !line.text.characters.allSatisfy(\.isWhitespace) else { return nil }
            return Line(id: i, text: line.text, top: line.top)
        }
    }

    func clear() {
        if !lines.isEmpty { lines = [] }
    }

    private static func key(_ k: CFString) -> NSAttributedString.Key { NSAttributedString.Key(k as String) }

    /// The cue's text with italic, bold and underline kept (the rest of its
    /// CoreMedia markup, colours and fonts, is the player's look instead).
    private static func line(_ s: NSAttributedString) -> (text: AttributedString, top: Bool) {
        var out = AttributedString()
        var top = false
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            var run = AttributedString(s.attributedSubstring(from: range).string)
            var intent: InlinePresentationIntent = []
            if (attrs[key(kCMTextMarkupAttribute_ItalicStyle)] as? Bool) == true { intent.insert(.emphasized) }
            if (attrs[key(kCMTextMarkupAttribute_BoldStyle)] as? Bool) == true { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if (attrs[key(kCMTextMarkupAttribute_UnderlineStyle)] as? Bool) == true { run.underlineStyle = .single }
            if let p = attrs[key(kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection)] as? NSNumber,
               p.doubleValue < 50 {
                top = true
            }
            out += run
        }
        return (out, top)
    }
}

/// The lines over the picture: bottom centre, lifted above the control bar
/// while it shows; cues placed at the top stay there.
struct PlayerSubtitles: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: PlayerSubtitleState
    let controls: PlayerControlsState

    /// The control bar's height with its bottom margin (PlayerControls), plus a gap.
    static let barClearance: CGFloat = 124
    /// The Skip Intro / Next Episode button above the bar.
    static let markerClearance: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            // About 4 % of the height: a little larger than AVKit's.
            let size = min(52, max(14, geo.size.height * 0.042))
            let margin = geo.size.height * 0.05
            let bottom = state.lines.filter { !$0.top }
            let top = state.lines.filter(\.top)
            ZStack {
                VStack(spacing: size * 0.2) {
                    ForEach(top) { cue($0, size: size).frame(maxWidth: geo.size.width * 0.9) }
                    Spacer(minLength: 0)
                }
                .padding(.top, margin)
                VStack(spacing: size * 0.2) {
                    Spacer(minLength: 0)
                    ForEach(bottom) { cue($0, size: size).frame(maxWidth: geo.size.width * 0.9) }
                }
                // Above the bar while it shows; above Skip Intro / Next Episode
                // (which stays where it is) for as long as that shows.
                .padding(.bottom, controls.markerShown ? max(margin, Self.barClearance + Self.markerClearance)
                         : controls.visible ? max(margin, Self.barClearance) : margin)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Reduce Motion: the lines move at once instead of gliding.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: controls.visible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: controls.markerShown)
        }
        .allowsHitTesting(false)
    }

    private func cue(_ line: PlayerSubtitleState.Line, size: CGFloat) -> some View {
        Text(line.text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // An outline and a soft shadow: readable on white snow and black night.
            .shadow(color: .black.opacity(0.9), radius: 1)
            .shadow(color: .black.opacity(0.6), radius: max(2, size * 0.12))
    }
}
