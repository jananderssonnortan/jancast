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
    private var player: AVPlayer?
    private var url: String?
    private var lastApplied = 0            // highest command id applied (acked in reports)
    private var ended = false
    private var reportTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var subtitlesWanted = false
    private var subtitlesChosen = false
    private var closing = false            // we close it ourselves: not a user Stop
    /// Stream the user closed the window on: not reopened while the backend
    /// is still winding that session down.
    private var dismissedURL: String?

    init(model: AppModel) {
        self.model = model
    }

    /// Called after every /api/state poll.
    func sync(_ state: LocalPlayerState?, subtitles: Bool) {
        guard let state, state.active == true else {
            teardown()
            return
        }
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
        teardown()
        guard let u = URL(string: state.url) else { return }
        url = state.url
        lastApplied = 0
        ended = false
        subtitlesChosen = false
        let item = AVPlayerItem(url: u)
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
        case "pause":
            player.pause()
            osd.show("pause.fill")
        case "resume":
            player.play()
            osd.show("play.fill")
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
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ThisMacPlayer")
            if !w.setFrameUsingName("ThisMacPlayer") { w.center() }
            window = w
        }
        // A fresh view per stream: a reused AVPlayerView kept showing the
        // previous stream's last subtitle until the next cue.
        let view = AVPlayerView()
        // Just the picture: the main window is the remote. AVKit's own controls
        // (subtitles, speed, Zoom/Fit, AirPlay, ±15 s) acted behind the
        // session's back. Double-click toggles full screen.
        view.controlsStyle = .none
        // Jancast publishes Now Playing itself (NowPlaying.swift); a second
        // entry from the view made a media key toggle playback twice.
        view.updatesNowPlayingInfoCenter = false
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFullScreen))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)
        view.player = player
        playerView?.player = nil
        // The picture with the cue layer on top.
        let container = NSView()
        let cues = PassThroughHostingView(rootView: PlayerOSD(state: osd))
        for v in [view, cues] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window?.contentView = container
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
        // Shown, not made key: Space and the arrows stay with the main window
        // (AVPlayerView would take them to step frames) until the user clicks here.
        window?.orderFront(nil)
    }

    @objc private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
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
