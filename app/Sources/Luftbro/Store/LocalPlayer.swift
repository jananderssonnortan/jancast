import AppKit
import AVFoundation
import AVKit

/// The "This Mac" player window: while a session plays to the local device,
/// the stream plays here with AVPlayer (the same AVFoundation stack as tvOS)
/// instead of on an Apple TV. It applies the backend's queued commands
/// (pause, resume, seek, stop) and reports what AVPlayer sees about once a
/// second, so phases, scrubber, resume and Diagnostics work as with a TV.
/// Closing the window counts as Stop. See docs/API.md ("This Mac").
@MainActor
final class LocalPlayer: NSObject, NSWindowDelegate {
    /// The player window's identifier: the app's key monitor sends Space and
    /// the arrows there to the session, like in the main window.
    static let windowID = "thismac"

    private weak var model: AppModel?
    private var window: NSWindow?
    private var playerView: AVPlayerView?
    /// Pause / play / skip cues over the picture.
    private let osd = PlayerOSDState()
    /// The control bar, shown when the mouse moves.
    private let controls = PlayerControlsState()
    /// The subtitle lines, drawn by Luftbro above the picture (not by AVKit).
    private let subtitles = PlayerSubtitleState()
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private static let silent = ProcessInfo.processInfo.environment["LUFTBRO_SNAPSHOT_DIR"] != nil
    /// Brightness, contrast, saturation, Fit / Fill, volume: kept across films.
    let adjustments = PlayerAdjustments()
    private var player: AVPlayer?
    private var url: String?
    private var lastApplied = 0            // highest command id applied (acked in reports)
    private var ended = false
    private var reportTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    /// The film's picture shape (pixel aspect applied), once AVPlayer knows it.
    private var pictureSize: CGSize?
    private var subtitlesWanted = false
    private var subtitlesChosen = false
    private var closing = false            // we close it ourselves: not a user Stop
    /// Stream the user closed the window on: not reopened while the backend
    /// is still winding that session down.
    private var dismissedURL: String?
    /// Next Episode was pressed: the window stays open (black) until then,
    /// so it doesn't drop out of full screen between the two streams.
    private var holdUntil: Date?

    init(model: AppModel) {
        self.model = model
        super.init()
        adjustments.onChange = { [weak self] in self?.applyAdjustments() }
    }

    /// Called after every /api/state poll.
    func sync(_ state: LocalPlayerState?, subtitles: Bool) {
        guard let state, state.active == true else {
            // Between two episodes (Next Episode): keep the window, and full
            // screen, until the next stream arrives.
            let holding = (holdUntil ?? .distantPast) > Date() && window?.isVisible == true
            teardown(closeWindow: !holding)
            if !holding { holdUntil = nil }
            // The session is gone, so the stream the user closed the window on
            // is too: the next session may reuse its URL and must open.
            dismissedURL = nil
            return
        }
        holdUntil = nil
        subtitlesWanted = subtitles
        if state.url == dismissedURL { return }
        if state.url != url { start(state) }
        for c in state.commands ?? [] where c.id > lastApplied {
            apply(c)
            lastApplied = c.id
        }
    }

    // MARK: - Playback

    private func start(_ state: LocalPlayerState) {
        teardown(closeWindow: false)        // the window is reused (it stays full screen)
        guard let u = URL(string: state.url) else { return }
        url = state.url
        lastApplied = 0
        ended = false
        subtitlesChosen = false
        let item = AVPlayerItem(url: u)
        // The session's subtitles come here as text instead of being drawn
        // into the picture (PlayerSubtitles).
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output)
        legibleOutput = output
        let player = AVPlayer(playerItem: item)
        self.player = player
        if let start = state.startPosition, start > 0 {
            item.seek(to: CMTime(seconds: start, preferredTimescale: 600), completionHandler: nil)
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if item.status == .readyToPlay { self?.chooseSubtitles(item) }
                    self?.report()
                }
            }
        }
        // Paused or 1×, nothing else: Luftbro has no speed control, and the
        // remote and the session's position assume real time. AVKit's own
        // shuttle (L, J) would set 2× or reverse behind the session's back.
        rateObservation = player.observe(\.rate, options: [.new]) { player, change in
            guard let rate = change.newValue, rate != 0, rate != 1 else { return }
            DispatchQueue.main.async { player.rate = 1 }
        }
        // The window takes the film's shape (2.39:1 without bars in a window).
        sizeObservation = item.observe(\.presentationSize) { [weak self] item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let size = item.presentationSize
                    guard size.width > 0, size.height > 0, self?.player?.currentItem === item else { return }
                    self?.pictureSize = size
                    self?.fitWindow()
                }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended = true; self?.report() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        })
        // In the common modes: a scheduledTimer (default mode only) stops while a
        // menu is open or a modal panel (⌘O) runs, and after 10 s without a
        // report the backend fails the session although the video plays on.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reportTimer = timer
        showWindow(player)
        player.play()
    }

    private func apply(_ c: LocalCommand) {
        guard let player else { return }
        switch c.action {
        // Usually already done locally (pauseNow): then no second cue.
        case "pause":
            if player.timeControlStatus != .paused { osd.show("pause.fill") }
            player.pause()
        case "resume":
            if player.timeControlStatus == .paused { osd.show("play.fill") }
            player.play()
        case "seek":
            if let p = c.position {
                osd.seek(from: player.currentTime().seconds, to: p)
                // Keep playing after the jump if it was playing (it could end up paused).
                let wasPlaying = player.timeControlStatus != .paused
                player.seek(to: CMTime(seconds: p, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] done in
                    guard done, wasPlaying else { return }
                    DispatchQueue.main.async { player?.play() }
                }
            }
        case "stop": teardown()
        default: break
        }
        report()
    }

    /// The master's subtitle rendition is FORCED/AUTOSELECT (for tvOS); here it
    /// is selected explicitly when the session has subtitles, and switched off
    /// when it has none.
    private func chooseSubtitles(_ item: AVPlayerItem) {
        guard !subtitlesChosen else { return }
        subtitlesChosen = true
        let wanted = subtitlesWanted
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            await MainActor.run {
                guard self?.player?.currentItem === item else { return }
                item.select(wanted ? group.options.first : nil, in: group)
            }
        }
    }

    private func report() {
        guard let model, let player, let item = player.currentItem else { return }
        let duration = item.duration.isNumeric ? item.duration.seconds : nil
        let position = player.currentTime().seconds
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue).map {
            LocalReport.LoadedRange(start: $0.start.seconds, duration: $0.duration.seconds)
        }
        let failed = item.status == .failed ? (item.error?.localizedDescription ?? "playback failed") : nil
        // isPlaybackBufferEmpty goes stale after a seek (empty and full at once
        // while playing), so "waiting for data" comes from timeControlStatus,
        // and the rate is the actual one (0 while waiting), as an Apple TV reports.
        let status = player.timeControlStatus
        let waiting = status == .waitingToPlayAtSpecifiedRate
            && player.reasonForWaitingToPlay != .noItemToPlay
        let r = LocalReport(position: position.isFinite ? position : nil, duration: duration,
                            rate: status == .playing ? Double(player.rate) : 0,
                            readyToPlay: item.status == .readyToPlay,
                            bufferEmpty: waiting, bufferFull: item.isPlaybackBufferFull,
                            likelyToKeepUp: item.isPlaybackLikelyToKeepUp, loadedRanges: ranges,
                            ack: lastApplied > 0 ? lastApplied : nil, ended: ended, error: failed)
        send(r, via: model)
    }

    private func send(_ r: LocalReport, via model: AppModel) {
        Task { _ = try? await model.backend.localReport(r) }
    }

    // MARK: - Window

    private func showWindow(_ player: AVPlayer) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
            w.collectionBehavior.insert(.fullScreenPrimary)     // green button = real full screen
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            // The control bar's three groups need this much before they overlap.
            w.contentMinSize = NSSize(width: 600, height: 200)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ThisMacPlayer")
            if !w.setFrameUsingName("ThisMacPlayer") { w.center() }
            window = w
        }
        // A fresh view per stream: a reused AVPlayerView keeps showing the
        // previous stream's last subtitle until the next cue.
        let view = KeylessPlayerView()
        // The picture only: AVKit's own controls (subtitles, speed, Zoom/Fit,
        // AirPlay, ±15 s) act behind the session's back. Luftbro's control
        // bar (PlayerControls) shows on mouse movement instead, and sends the
        // same commands as the remote. Double-click toggles full screen.
        view.controlsStyle = .none
        // Luftbro publishes Now Playing itself (NowPlaying.swift); a second
        // entry from the view would make a media key toggle playback twice.
        view.updatesNowPlayingInfoCenter = false
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFullScreen))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)
        view.player = player
        playerView?.player = nil
        let container = MouseTrackingView()
        let lines = PassThroughHostingView(rootView: PlayerSubtitles(state: subtitles, controls: controls))
        let cues = PassThroughHostingView(rootView: PlayerOSD(state: osd))
        // The picture, the subtitles and the cues fill the window; the bar
        // sits at the bottom, only as tall as it is.
        let fullSize: [NSView] = [view, lines, cues]
        var layers = fullSize
        if let model {
            let bar = ControlsHostingView(rootView: PlayerControls(state: controls, adjustments: adjustments) { [weak self] in self?.toggleFullScreen() }
                .environment(model))
            // Clicks while the bar shows; else only on the Skip Intro / Next Episode button.
            bar.accepts = { [weak self] p in
                guard let c = self?.controls else { return false }
                return c.visible || (c.markerShown && c.markerFrame.insetBy(dx: -4, dy: -4).contains(p))
            }
            // Only its height: the default min/max sizes would constrain the window
            // (it couldn't grow past the bar's widest and would change shape).
            bar.sizingOptions = .intrinsicContentSize
            bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
            bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            layers.append(bar)
        }
        for v in layers {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            if fullSize.contains(where: { $0 === v }) {
                v.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
            }
        }
        controls.window = window
        controls.isPaused = { [weak self] in self?.model?.isPaused == true }
        container.onMove = { [weak self] in self?.controls.show() }
        window?.contentView = container
        controls.show()
        // What plays, like the main window ("Night Train S6 · E1 — Title"); the
        // device as the subtitle.
        if let file = model?.live?.session?.file, let name = file.name {
            let n = Fmt.name(name, file.nameInfo)
            window?.title = [n.title, n.episodeTitle].compactMap { $0 }.joined(separator: " — ")
        } else {
            window?.title = "This Mac"
        }
        window?.subtitle = "This Mac"
        playerView = view
        applyAdjustments()
        // Shown, not made key: Space and the arrows stay with the main window
        // (AVPlayerView would take them to step frames) until the user clicks here.
        window?.orderFront(nil)
    }

    /// Picture and sound settings onto the view and the player.
    private func applyAdjustments() {
        // Silent while the app runs for screenshots (development aid).
        player?.volume = Self.silent ? 0 : adjustments.effectiveVolume
        guard let view = playerView else { return }
        view.videoGravity = adjustments.fill ? .resizeAspectFill : .resizeAspect
        let filters = adjustments.filters
        if filters.isEmpty {
            // No filters at all, not neutral ones: a filtered layer is drawn
            // through Core Image and loses HDR highlights.
            view.contentFilters = []
        } else {
            view.wantsLayer = true
            view.layerUsesCoreImageFilters = true
            view.contentFilters = filters
        }
    }

    /// ⌘↑ / ⌘↓ while playing here: the player's volume, with a cue over the picture.
    func stepVolume(up: Bool) {
        adjustments.stepVolume(up: up)
        flash(adjustments.volumeSymbol, adjustments.volumeText)
    }

    /// M: mute or unmute, with a cue over the picture.
    func toggleMute() {
        adjustments.muted.toggle()
        flash(adjustments.volumeSymbol, adjustments.volumeText)
    }

    /// The window's content takes the film's shape, keeping its width and top
    /// edge (in full screen only the shape, applied when it leaves).
    private func fitWindow() {
        guard let window, let size = pictureSize else { return }
        // Clamped: a broken size must not make a sliver of a window.
        let ratio = min(3, max(0.5, size.width / size.height))
        window.contentAspectRatio = NSSize(width: (ratio * 1000).rounded(), height: 1000)
        guard !window.styleMask.contains(.fullScreen) else { return }
        var content = window.contentRect(forFrameRect: window.frame)
        let height = (content.width / ratio).rounded()
        guard abs(height - content.height) > 1 else { return }
        content.origin.y += content.height - height
        content.size.height = height
        var frame = window.frameRect(forContentRect: content)
        if let screen = window.screen { frame = window.constrainFrameRect(frame, to: screen) }
        window.setFrame(frame, display: true)
    }

    nonisolated func windowDidExitFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { fitWindow() }
    }

    /// Play / Pause pressed: the picture stops or goes on at once, not when
    /// the command comes back from the backend (a round trip of up to a
    /// second, long enough for the click to feel lost). The command still follows.
    func pauseNow(_ pause: Bool) {
        guard let player, window?.isVisible == true else { return }
        if pause {
            player.pause()
            osd.show("pause.fill")
        } else {
            player.play()
            osd.show("play.fill")
        }
    }

    /// Next Episode or a track change: keep the window up for the next stream
    /// (it takes a few seconds to start), or close it after a while if none comes.
    func holdForNextStream(cue: (symbol: String, text: String)? = nil) {
        guard window?.isVisible == true else { return }
        holdUntil = Date().addingTimeInterval(45)
        if let cue { osd.show(cue.symbol, cue.text) }
    }

    /// Stop while holding: close as usual.
    func cancelHold() {
        holdUntil = nil
    }

    /// A handled key in this window (Space, ← / →) brings the bar up, as a
    /// mouse move does.
    func revealControls() {
        if window?.isVisible == true { controls.show() }
    }

    /// Skip Intro / Next Episode is showing (AppModel.followMarker).
    func setMarkerShown(_ shown: Bool) {
        if controls.markerShown != shown { controls.markerShown = shown }
    }

    /// A cue over the picture for a change made elsewhere (the subtitle delay).
    func flash(_ symbol: String, _ text: String? = nil) {
        if window?.isVisible == true { osd.show(symbol, text) }
    }

    @objc private func toggleFullScreen() {
        guard let window else { return }
        // In full screen it is what the user looks at: keys (Space, ←/→, Esc) go here.
        if !window.styleMask.contains(.fullScreen) { window.makeKeyAndOrderFront(nil) }
        window.toggleFullScreen(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            holdUntil = nil
            guard !closing, let model else { return }
            dismissedURL = url
            // The user closed the window: like Stop (position kept, not "watched").
            if let player, let item = player.currentItem {
                send(LocalReport(position: player.currentTime().seconds, duration: nil, rate: 0, readyToPlay: item.status == .readyToPlay,
                                 bufferEmpty: false, bufferFull: false, likelyToKeepUp: false, loadedRanges: [],
                                 ack: lastApplied > 0 ? lastApplied : nil, closed: true), via: model)
            }
            teardown(closeWindow: false)
        }
    }

    private func teardown(closeWindow: Bool = true) {
        reportTimer?.invalidate()
        reportTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        statusObservation = nil
        sizeObservation = nil
        rateObservation = nil
        pictureSize = nil
        legibleOutput?.setDelegate(nil, queue: nil)
        legibleOutput = nil
        subtitles.clear()
        player?.pause()
        playerView?.player = nil
        player = nil
        url = nil
        if closeWindow, let w = window, w.isVisible {
            closing = true
            w.close()
            closing = false
        }
    }
}

extension LocalPlayer: AVPlayerItemLegibleOutputPushDelegate {
    /// The subtitle text due now (empty when a cue ends), on the main queue.
    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                   didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        MainActor.assumeIsolated {
            guard output === legibleOutput else { return }
            subtitles.show(strings)
        }
    }
}

/// The picture never takes the keys: AVPlayerView would step frames on ↑ / ↓
/// and play or pause AVPlayer on Space behind the session's back. The app's key
/// monitor handles the window's keys instead.
final class KeylessPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}
