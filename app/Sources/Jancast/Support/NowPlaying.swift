import AppKit
import MediaPlayer

/// Media keys, Control Center and AirPods controls drive the TV (MediaPlayer
/// now-playing integration). Owned by AppModel; `update()` runs after every poll.
///
/// Commands are only enabled while a session exists, so an idle Jancast never
/// takes the media keys away from Music or a browser.
@MainActor
final class NowPlaying {
    private weak var model: AppModel?
    private var commandsEnabled = false
    /// What was last written to MPNowPlayingInfoCenter, to avoid rewriting it every poll.
    private var last: Snapshot?

    private struct Snapshot: Equatable {
        var title: String
        var device: String
        var duration: Double
        var elapsed: Double
        var rate: Double
        var state: MPNowPlayingPlaybackState
        var writtenAt: Date
    }

    init(model: AppModel) {
        self.model = model
        registerCommands()
        setCommandsEnabled(false)
    }

    func update() {
        guard let m = model, let session = m.live?.session, m.phase.isActive else {
            clear()
            return
        }
        setCommandsEnabled(true)
        let rate: Double = m.phase == .playing ? 1 : 0
        // Preparing/connecting/buffering count as playing: that is what the user asked for.
        let state: MPNowPlayingPlaybackState = m.isPaused ? .paused : .playing
        let next = Snapshot(title: Fmt.name(session.file?.name ?? "Video", session.file?.nameInfo).title,
                            device: session.device?.name ?? "Apple TV",
                            duration: session.file?.durationS ?? m.live?.playback?.duration ?? 0,
                            elapsed: m.displayPosition ?? 0,
                            rate: rate, state: state, writtenAt: Date())
        if let last, !needsWrite(old: last, new: next) { return }
        write(next)
    }

    // MARK: - Info center

    private func needsWrite(old: Snapshot, new: Snapshot) -> Bool {
        if old.title != new.title || old.device != new.device || old.rate != new.rate || old.state != new.state { return true }
        if abs(old.duration - new.duration) > 1 { return true }
        // The system extrapolates elapsed time from the rate; only correct real drift.
        let expected = old.elapsed + old.rate * new.writtenAt.timeIntervalSince(old.writtenAt)
        return abs(expected - new.elapsed) > 1.5
    }

    private func write(_ s: Snapshot) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: "Playing on \(s.device)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: s.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: s.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if s.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = s.duration }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = s.state      // required on macOS for the media keys to route here
        if last == nil {
            model?.telemetry.note("info", "app", "Now Playing published to macOS (Control Center, media keys): \(s.title)")
        }
        last = s
    }

    private func clear() {
        guard last != nil || commandsEnabled else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        last = nil
        setCommandsEnabled(false)
    }

    // MARK: - Remote commands

    private var allCommands: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.stopCommand,
                c.skipForwardCommand, c.skipBackwardCommand, c.nextTrackCommand, c.previousTrackCommand,
                c.changePlaybackPositionCommand]
    }

    private func setCommandsEnabled(_ on: Bool) {
        guard on != commandsEnabled else { return }
        commandsEnabled = on
        for c in allCommands { c.isEnabled = on }
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [10]

        handle(c.playCommand, "play") { m, _ in if m.isPaused { m.togglePause() } }
        handle(c.pauseCommand, "pause") { m, _ in if !m.isPaused { m.togglePause() } }
        handle(c.togglePlayPauseCommand, "play/pause") { m, _ in m.togglePause() }
        handle(c.stopCommand, "stop") { m, _ in m.stop() }
        handle(c.skipForwardCommand, "skip forward") { m, _ in m.skip(30) }
        handle(c.skipBackwardCommand, "skip back") { m, _ in m.skip(-10) }
        // Keyboard ⏮ / ⏭ (F7 / F9) arrive as track commands; for a single video they skip.
        handle(c.nextTrackCommand, "next track") { m, _ in m.skip(30) }
        handle(c.previousTrackCommand, "previous track") { m, _ in m.skip(-10) }
        handle(c.changePlaybackPositionCommand, "change position") { m, event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { m.seek(to: e.positionTime) }
        }
    }

    /// Runs `action` on the main actor. Handlers may be called off the main
    /// thread; the status is decided from a main-thread read when possible.
    private func handle(_ command: MPRemoteCommand, _ name: String,
                        _ action: @escaping @MainActor (AppModel, MPRemoteCommandEvent) -> Void) {
        command.addTarget { [weak self] event in
            let run: @MainActor () -> MPRemoteCommandHandlerStatus = {
                guard let m = self?.model else { return .noActionableNowPlayingItem }
                // Logged so Diagnostics ▸ Events shows whether macOS delivers them at all.
                m.telemetry.note("info", "app", "Media control from macOS: \(name)"
                                 + (m.canControl ? "" : " (ignored: nothing to control)"))
                guard m.canControl else { return .commandFailed }
                action(m, event)
                return .success
            }
            if Thread.isMainThread {
                return MainActor.assumeIsolated { run() }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = run() } }
            return .success
        }
    }
}
