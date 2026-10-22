import AppKit
import SwiftUI

/// What the This Mac window flashes over the picture when a command lands:
/// pause / play, a skip with its size, or the time jumped to.
@MainActor @Observable
final class PlayerOSDState {
    struct Cue: Equatable {
        var symbol: String
        var text: String?
        var id = UUID()
    }

    private(set) var cue: Cue?
    @ObservationIgnored private var token = 0

    func show(_ symbol: String, _ text: String? = nil) {
        cue = Cue(symbol: symbol, text: text)
        token += 1
        let mine = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.token == mine else { return }
            self.cue = nil
        }
    }

    /// A seek from `from` to `to`: a skip (±N s) when short, else the time.
    func seek(from: Double, to: Double) {
        let delta = to - from
        guard from.isFinite, abs(delta) >= 1 else { return }
        if abs(delta) <= 300 {
            // Skips are whole 5 s steps; the playhead moved on a little while
            // they were collected ("29 s" for three presses of +10).
            let step = (abs(delta) / 5).rounded() * 5
            let size = abs(abs(delta) - step) < 2.5 && step > 0 ? step : abs(delta)
            show(delta > 0 ? "goforward" : "gobackward", Fmt.skipAmount(size))
        } else {
            show(delta > 0 ? "forward.fill" : "backward.fill", Fmt.clock(to))
        }
    }
}

/// The cue itself: a dark rounded square in the middle of the picture.
struct PlayerOSD: View {
    let state: PlayerOSDState

    var body: some View {
        ZStack {
            if let cue = state.cue {
                VStack(spacing: 6) {
                    Image(systemName: cue.symbol)
                        .font(.system(size: 44, weight: .semibold))
                    if let text = cue.text {
                        Text(text).font(.title3.weight(.semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 120, minHeight: 120)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.55)))
                .id(cue.id)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: state.cue)
        .allowsHitTesting(false)
    }
}

/// Hosts the cue over the player without taking clicks (double-click for
/// full screen stays with the player view underneath).
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
