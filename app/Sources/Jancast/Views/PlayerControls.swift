import AppKit
import SwiftUI

/// When the This Mac window's control bar shows: on mouse movement, hidden
/// again after a few idle seconds (with the pointer, over the picture), kept
/// while the pointer is on the bar, one of its menus is open, or playback is paused.
@MainActor @Observable
final class PlayerControlsState {
    private(set) var visible = false
    /// Pointer over the bar itself.
    var hovering = false { didSet { if hovering { show() } else { scheduleHide() } } }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var isPaused: () -> Bool = { false }
    @ObservationIgnored private var token = 0
    /// A menu (audio, subtitles) is open: the bar stays under it.
    @ObservationIgnored private var menuOpen = false

    static let idle: TimeInterval = 2.5

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                if self?.visible == true { self?.scheduleHide() }
            }
        }
    }

    func show() {
        visible = true
        scheduleHide()
    }

    func hideNow() {
        token += 1
        visible = false
    }

    private func scheduleHide() {
        token += 1
        let mine = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idle) { [weak self] in
            guard let self, self.token == mine else { return }
            if self.hovering || self.menuOpen || self.isPaused() { return }
            self.visible = false
            // Like QuickTime: the pointer goes too while it rests on the picture.
            if let w = self.window, w.frame.contains(NSEvent.mouseLocation) {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

/// The bar at the bottom of the This Mac window: the session's own controls
/// (AVKit's acted behind the session's back), the same commands as the remote.
struct PlayerControls: View {
    @Environment(AppModel.self) private var model
    let state: PlayerControlsState
    let toggleFullScreen: () -> Void
    @State private var scrub: Double?          // fraction while dragging

    var body: some View {
        let duration = max(1, model.live?.session?.file?.durationS ?? model.live?.playback?.duration ?? 1)
        let position = scrub.map { $0 * duration } ?? model.displayPosition ?? 0
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(Fmt.clock(position))
                scrubber(fraction: min(1, max(0, position / duration)), duration: duration)
                Text("−" + Fmt.clock(max(0, duration - position)))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            ZStack {
                HStack(spacing: 26) {
                    button("gobackward.10", help: "Back 10 s (←)") { model.skip(-10) }
                    button(model.isPaused ? "play.fill" : "pause.fill", size: 26,
                           help: model.isPaused ? "Play (Space)" : "Pause (Space)") { model.togglePause() }
                    button("goforward.30", help: "Forward 30 s (⌘→)") { model.skip(30) }
                }
                HStack(spacing: 4) {
                    button("stop.fill", size: 15, help: "Stop (⌘.)") { model.stop() }
                    Spacer()
                    trackMenus
                    button("arrow.up.left.and.arrow.down.right", size: 15, help: "Full screen (double-click, Esc to leave)") { toggleFullScreen() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        // Solid, not a material: a live blur over playing video redraws every frame.
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .opacity(state.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: state.visible)
        .onHover { state.hovering = $0 }
        .disabled(!model.canControl)
        .accessibilityHidden(!state.visible)          // not reachable while it is hidden
        .environment(\.colorScheme, .dark)
    }

    /// Audio and subtitles, as on the remote: a change restarts the stream at
    /// the current position.
    @ViewBuilder private var trackMenus: some View {
        if let probe = model.sessionTracks {
            Menu {
                Picker("Audio", selection: Binding(get: { model.sessionAudioID ?? -1 }, set: { model.switchTracks(audio: $0) })) {
                    ForEach(probe.audioTracks) { t in Text(Fmt.trackTitle(t)).tag(t.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Toggle("Downmix to Stereo", isOn: Binding(get: { model.sessionStereo }, set: { model.switchTracks(stereo: $0) }))
            } label: {
                menuLabel("waveform")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio: \(model.currentAudioTitle)")
            Menu {
                SubtitleMenuContent(probe: probe, inPlayer: true)
            } label: {
                menuLabel(model.sessionSubtitleID == 0 ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles: " + (model.sessionSubtitleID == 0 ? "Off" : model.currentSubtitleTitle))
        }
    }

    private func menuLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 30)
            .contentShape(Rectangle())
    }

    private func button(_ symbol: String, size: CGFloat = 20, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
    }

    /// Click or drag to jump; the seek is sent on release.
    private func scrubber(fraction: Double, duration: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: max(4, w * fraction))
            }
            .frame(height: scrub == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in scrub = min(1, max(0, g.location.x / max(1, w))) }
                    .onEnded { g in
                        model.seek(to: min(1, max(0, g.location.x / max(1, w))) * duration)
                        scrub = nil
                    }
            )
        }
        .frame(height: 16)
    }
}

/// Hosts the control bar: takes clicks only while it shows, and the first
/// click even when the window isn't key (it is shown without taking focus).
final class ControlsHostingView<Content: View>: NSHostingView<Content> {
    var isActive: () -> Bool = { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isActive() ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The player window's content: reports mouse movement anywhere over it
/// (also while the window isn't key, and in full screen).
final class MouseTrackingView: NSView {
    var onMove: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseEntered(with event: NSEvent) { onMove() }
}
