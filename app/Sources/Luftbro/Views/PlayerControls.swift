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
    /// Skip Intro / Next Episode shows over the picture (above the bar): its
    /// button takes clicks while the bar is hidden, and subtitles make room.
    var markerShown = false
    /// Where that button is in the bar's host (top-left origin): while the bar
    /// is hidden only clicks there are taken, so double-click on the picture
    /// around it still goes full screen.
    @ObservationIgnored var markerFrame: CGRect = .zero
    /// The Picture & Sound popover is open: the bar stays under it too.
    var popoverOpen = false { didSet { if popoverOpen { show() } else { scheduleHide() } } }

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
        // Only an actual change: every mouse move lands here, and a needless
        // set would redraw the bar and rebuild an open menu.
        if !visible { visible = true }
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
            if self.hovering || self.menuOpen || self.popoverOpen || self.isPaused() { return }
            self.visible = false
            // Like QuickTime: the pointer goes too while it rests on the picture.
            if let w = self.window, w.frame.contains(NSEvent.mouseLocation) {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

/// The bar at the bottom of the This Mac window: the session's own controls
/// (AVKit's would act behind the session's back), the same commands as the remote.
struct PlayerControls: View {
    @Environment(AppModel.self) private var model
    let state: PlayerControlsState
    let adjustments: PlayerAdjustments
    let toggleFullScreen: () -> Void

    // The timeline and the track menus are views of their own: the playhead
    // changes with every poll, and redrawing the menus with it would rebuild
    // an open menu and close its Delay submenu.
    var body: some View {
        // Skip Intro / Next Episode at the bottom right, above the bar: it
        // stays while the bar comes and goes, so nothing moves.
        VStack(alignment: .trailing, spacing: 12) {
            MarkerButton()
                .background(GeometryReader { g in
                    Color.clear.preference(key: MarkerFrameKey.self, value: g.frame(in: .named(Self.space)))
                })
                .padding(.trailing, 20)
            bar
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MarkerFrameKey.self) { state.markerFrame = $0 }
        .environment(\.colorScheme, .dark)
    }

    private static let space = "controls"

    private var bar: some View {
        VStack(spacing: 8) {
            BarTimeline()

            ZStack {
                HStack(spacing: 26) {
                    button("gobackward.10", help: "Back 10 s (←)") { model.skip(-10) }
                    button(model.isPaused ? "play.fill" : "pause.fill", size: 26,
                           help: model.isPaused ? "Play (Space)" : "Pause (Space)") { model.togglePause() }
                    button("goforward.30", help: "Forward 30 s (⌘→)") { model.skip(30) }
                }
                HStack(spacing: 4) {
                    button("stop.fill", size: 17, help: "Stop (⌘.)") { model.stop() }
                    Spacer()
                    pictureAndSound
                    BarTrackMenus()
                    button("arrow.up.left.and.arrow.down.right", size: 17, help: "Full screen (double-click, Esc to leave)") { toggleFullScreen() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        // Solid, not a material: a live blur over playing video redraws every frame.
        // Dark enough to hold the white controls over a bright scene.
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)                   // centred under the trailing button
        .opacity(state.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: state.visible)
        .onHover { state.hovering = $0 }
        .disabled(!model.canControl)
        .allowsHitTesting(state.visible)              // the host takes clicks for the marker button too
        .accessibilityHidden(!state.visible)          // not reachable while it is hidden
    }

    /// Brightness, contrast, saturation, Fit / Fill and volume, in a popover.
    private var pictureAndSound: some View {
        @Bindable var state = state
        return Button { state.popoverOpen.toggle() } label: {
            Self.menuLabel("slider.horizontal.3")
                // A dot while the picture is adjusted, so a dim picture is explained.
                .overlay(alignment: .topTrailing) {
                    if !adjustments.pictureIsNeutral {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -4, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Picture & Sound")
        .accessibilityLabel("Picture and Sound")
        .popover(isPresented: $state.popoverOpen, arrowEdge: .top) {
            PictureSoundPanel(adjustments: adjustments, hdr: model.sessionTracks?.video?.hdr == true)
        }
    }

    static func menuLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 36)          // a generous target, easy to hit
            .contentShape(Rectangle())
    }

    private func button(_ symbol: String, size: CGFloat = 20, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
    }
}

private struct MarkerFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Skip Intro / Next Episode over the picture, as on the streaming services: during the
/// intro, and from the start of the credits when there is a next episode.
private struct MarkerButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let marker = model.activeMarker {
            let credits = marker == .credits
            Button { model.runMarker() } label: {
                HStack(spacing: 8) {
                    Image(systemName: credits ? "forward.end.alt.fill" : "forward.end.fill")
                    Text(credits ? "Next Episode" : "Skip Intro")
                    // Faded, not removed: the button keeps its size.
                    Text("Space")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.6)))
                        .opacity(model.markerTakesSpace ? 1 : 0)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(credits ? "Play the next episode (⏭)" : "Skip the intro (⏭)")
            .animation(.easeOut(duration: 0.3), value: model.markerTakesSpace)
        }
    }
}

/// Audio and subtitles, as on the remote: a change restarts the stream at
/// the current position.
private struct BarTrackMenus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
                PlayerControls.menuLabel("waveform")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio: \(model.currentAudioTitle)")
            Menu {
                SubtitleMenuContent(probe: probe, inPlayer: true)
            } label: {
                PlayerControls.menuLabel(model.sessionSubtitleID == 0 ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles: " + (model.sessionSubtitleID == 0 ? "Off" : model.currentSubtitleTitle))
        }
    }
}

/// The bar's time row: elapsed, scrubber, remaining.
private struct BarTimeline: View {
    @Environment(AppModel.self) private var model
    @State private var scrub: Double?          // fraction while dragging

    var body: some View {
        let duration = max(1, model.live?.session?.file?.durationS ?? model.live?.playback?.duration ?? 1)
        let position = scrub.map { $0 * duration } ?? model.displayPosition ?? 0
        HStack(spacing: 10) {
            Text(Fmt.clock(position))
            scrubber(fraction: min(1, max(0, position / duration)), duration: duration)
            Text("−" + Fmt.clock(max(0, duration - position)))
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
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

/// The Picture & Sound popover: brightness, contrast, saturation (Reset puts
/// the film back as it is), Fit / Fill, and the player's volume.
struct PictureSoundPanel: View {
    @Bindable var adjustments: PlayerAdjustments
    /// The film is HDR: say what an adjusted picture costs.
    var hdr = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PICTURE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { adjustments.resetPicture() }
                    .controlSize(.small)
                    .disabled(adjustments.pictureIsNeutral)
            }
            row("sun.max", "Brightness", $adjustments.brightness, PlayerAdjustments.brightnessRange, neutral: 0)
            row("circle.lefthalf.filled", "Contrast", $adjustments.contrast, PlayerAdjustments.contrastRange, neutral: 1)
            row("drop", "Saturation", $adjustments.saturation, PlayerAdjustments.saturationRange, neutral: 1)
            Picker("Size", selection: $adjustments.fill) {
                Text("Fit").tag(false)
                Text("Fill").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Fit shows the whole picture; Fill crops it to fill the window or screen")
            // Always there for an HDR film, so the popover doesn't grow when a slider moves.
            if hdr {
                Text("This film is HDR: its highlights are lost while the picture is adjusted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("SOUND").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            VolumeRow(adjustments: adjustments)
        }
        .padding(14)
        .frame(width: 280)
    }

    /// One slider; double-click its icon to put that one back.
    private func row(_ symbol: String, _ label: String, _ value: Binding<Double>,
                     _ range: ClosedRange<Double>, neutral: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 22, alignment: .leading)
                .foregroundStyle(.secondary)
                .help("\(label) (double-click to reset)")
                .onTapGesture(count: 2) { value.wrappedValue = neutral }
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(label)
            Text(Self.percent(value.wrappedValue, neutral: neutral, range: range))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// −100…+100 around the neutral point ("0" at the film as it is).
    private static func percent(_ v: Double, neutral: Double, range: ClosedRange<Double>) -> String {
        let span = v >= neutral ? range.upperBound - neutral : neutral - range.lowerBound
        // The same band PlayerAdjustments treats as unadjusted.
        if abs(v - neutral) < 0.025 { return "0" }
        let p = Int((100 * (v - neutral) / max(span, 0.0001)).rounded())
        return p > 0 ? "+\(p)" : "−\(-p)"
    }
}

/// The This Mac player's volume: mute and a slider (the popover here and the
/// remote's volume button).
struct VolumeRow: View {
    @Bindable var adjustments: PlayerAdjustments

    var body: some View {
        HStack(spacing: 8) {
            Button { adjustments.muted.toggle() } label: {
                Image(systemName: adjustments.volumeSymbol)
                    .frame(width: 22, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(adjustments.muted ? "Unmute (M)" : "Mute (M)")
            .accessibilityLabel(adjustments.muted ? "Unmute" : "Mute")
            // Dragging unmutes.
            Slider(value: Binding(get: { adjustments.volume },
                                  set: { adjustments.volume = $0; adjustments.muted = false }),
                   in: 0...1)
                .controlSize(.small)
                .accessibilityLabel("Volume")
            Text(adjustments.volumeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

/// Hosts the control bar: takes clicks only while it shows, and the first
/// click even when the window isn't key (it is shown without taking focus).
final class ControlsHostingView<Content: View>: NSHostingView<Content> {
    /// Whether a click at this point (top-left origin, in this view) is ours.
    var accepts: (CGPoint) -> Bool = { _ in true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        var p = convert(point, from: superview)
        if !isFlipped { p.y = bounds.height - p.y }
        return accepts(p) ? super.hitTest(point) : nil
    }
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
