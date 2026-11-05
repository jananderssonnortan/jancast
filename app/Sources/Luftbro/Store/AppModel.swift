import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Tabs of the opt-in Diagnostics drawer.
enum DiagSection: String, Hashable, CaseIterable {
    case overview, charts, segments, events
}

enum BackendStatus: Equatable {
    case starting
    case running
    case failed(message: String, log: String)
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored static weak var current: AppModel?

    @ObservationIgnored private(set) var backend: Backend
    var isMock: Bool { backend.isMock }
    var backendStatus: BackendStatus = .starting
    var diagSection: DiagSection = .overview
    /// Main window shows the player (true) or the setup form (false).
    var playerVisible = false
    /// The remote's natural height, so the Diagnostics drawer can take the
    /// library's space before the remote's (RootView).
    var remoteHeight: CGFloat = 0
    /// Where the remote starts in the window (below the toolbar), for the backdrop.
    var remoteTop: CGFloat = 0
    /// The Diagnostics drawer at the bottom of the main window.
    var diagnosticsOpen = false {
        didSet {
            guard diagnosticsOpen != oldValue else { return }
            // Faster latency probing only while someone is looking.
            setTelemetryLevel(diagnosticsOpen ? "detailed" : "basic")
            // A panel sliding out from beneath the window when the screen has
            // room beside it, else the drawer under the remote.
            if diagnosticsOpen {
                diagnosticsBeside = DiagnosticsSidePanel.shared.show(model: self)
            } else if diagnosticsBeside {
                DiagnosticsSidePanel.shared.hide()
                diagnosticsBeside = false
            }
        }
    }
    /// Diagnostics open as the panel beside the window (DiagnosticsSidePanel),
    /// not as the drawer under the remote.
    var diagnosticsBeside = false
    /// Bumped when the stream health worsens, to pulse the indicator once.
    var healthAlertTick = 0
    @ObservationIgnored private var lastHealth: Health = .neutral
    @ObservationIgnored private var lastPhase: Phase = .idle
    @ObservationIgnored private var switchingTracks = false

    // Setup
    var probe: ProbeResult?
    var probing = false
    var probeError: String?
    var audioID = 1
    var subtitleID = 0 {
        didSet { if subtitleID != oldValue { followOCR() } }
    }
    /// Subtitle delay chosen in Setup (seconds, + = later); see AppModel+Subtitles.
    var subtitleDelay = 0.0
    /// Subtitle stretch chosen in Setup (cue times × this; 1 = none).
    var subtitleScale = 1.0
    /// Mid-playback: the delay H / J have dialled in, shown at once and sent
    /// as one restart when the presses stop (until the backend reports it).
    var pendingSubtitleDelay: Double?
    /// Mid-playback: a stretch being applied, shown until the backend reports it.
    var pendingSubtitleScale: Double?
    @ObservationIgnored var subtitleDelayToken = 0
    /// Text recognition of the selected picture subtitle track (Setup).
    var ocrStatus: OCRStatus?
    @ObservationIgnored var ocrTask: Task<Void, Never>?
    /// Sync Automatically: the measurement under way, and its one-line outcome
    /// while it is shown (see AppModel+Subtitles).
    var subtitleSyncWorking = false
    var subtitleSyncNote: StatusHint?
    @ObservationIgnored var subtitleSyncTask: Task<Void, Never>?
    @ObservationIgnored var subtitleSyncToken = 0
    var stereo = false
    var recents: [HistoryEntry] = []
    /// Set when the selected file can be resumed (from probe `resume` or Recents).
    var resumeEntry: HistoryEntry?
    var devices: [Device] = []
    var scanning = false
    var devicesError: String?
    var selectedDeviceID: String?
    var startingPlayback = false
    var alert: AlertInfo?

    // Pairing sheet
    var pairingDeviceID: String?
    var pairingBusy = false
    var pairingError: String?
    var pairingAwaitingPin = false
    @ObservationIgnored private var dismissedPairingFor: String?
    @ObservationIgnored private var playAfterPairing = false
    /// "Play on" an unpaired TV: pair first, then move playback there.
    @ObservationIgnored private var switchAfterPairing: String?
    /// The device playback is moving to, shown in the TV pill until it lands.
    var pendingDeviceID: String?
    @ObservationIgnored private var pendingStartPosition: Double?

    // Live
    var live: StateResponse?
    var telemetry = Telemetry()
    /// Preview thumbnails of the file on screen (playing file in the player, else Setup's).
    let thumbs = Thumbnails()
    var pollError: String?
    /// The backend process is alive but hasn't answered a poll for 20 s
    /// (RemoteLayout's bar with Try Again); clears itself when it answers.
    var backendUnresponsive = false
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollFailures = 0
    @ObservationIgnored private var pollFailingSince: Date?
    @ObservationIgnored private var currentPoll: Task<Void, Never>?
    @ObservationIgnored private var pollAgain = false
    /// Bumped whenever a backend is (re)started: an answer from the one
    /// before is thrown away, and a lower seq from the same one is a stale
    /// answer, not a restart.
    @ObservationIgnored private var backendGeneration = 0
    @ObservationIgnored private var staleAnswers = 0
    @ObservationIgnored private(set) lazy var nowPlaying = NowPlaying(model: self)
    /// The "This Mac" player window (plays the stream locally instead of on a TV).
    @ObservationIgnored private(set) lazy var localPlayer = LocalPlayer(model: self)

    /// Last run's window colours, until this run's pictures load (SavedLook).
    var launchLook: SavedLook.Pictures?
    /// Launch is done: the backend runs and the restored file (if any) has its
    /// pictures. Until then the window shows only its background, so it opens
    /// complete instead of filling in piece by piece.
    var ready = false

    init(mock: Bool) {
        backend = mock ? MockBackend() : LiveBackend()
        launchLook = mock ? nil : SavedLook.load()
        if launchLook != nil {
            // Where last run's backdrop started (under the toolbar), so it is in place from the start.
            remoteTop = UserDefaults.standard.double(forKey: "lastRemoteTop")
        }
        AppModel.current = self
    }

    static func makeFromEnvironment() -> AppModel {
        let env = ProcessInfo.processInfo.environment
        let mock = CommandLine.arguments.contains("--mock") || env["LUFTBRO_MOCK"] == "1"
        return AppModel(mock: mock)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await connect()
    }

    /// "Try Again": stops the backend (awaited, so the window stays responsive
    /// while it cleans up) and starts a fresh one. The window shows
    /// "Starting…" as at launch rather than a blank remote meanwhile.
    func restartBackend() async {
        pollTask?.cancel()
        backendUnresponsive = false
        pollFailingSince = nil
        pollFailures = 0
        pollError = nil
        ready = false
        await backend.stop()
        backend = isMock ? MockBackend() : LiveBackend()
        lastSeq = 0
        telemetry.resetAll()
        live = nil
        await connect()
    }

    private func connect() async {
        backendStatus = .starting
        backendGeneration += 1
        backend.onUnexpectedExit = { [weak self] msg, log in
            self?.pollTask?.cancel()
            self?.backendStatus = .failed(message: msg, log: log)
        }
        do {
            try await backend.start()
            backendStatus = .running
        } catch let e as BackendError {
            backendStatus = .failed(message: e.localizedDescription, log: e.log)
            return
        } catch {
            backendStatus = .failed(message: error.localizedDescription, log: "")
            return
        }
        startPolling()
        // The first device list means a network scan (~4 s): run it alongside,
        // so the playlist and the last file show right away.
        let devicesLoaded = Task { await loadDevices(refresh: false) }
        // The last file is restored alongside too, and the window only waits
        // a moment for it (waitForPictures): a file on a sleeping NAS or an
        // unplugged disk can take the probe's whole minute to answer, and
        // the window shouldn't wait for that.
        restoring = true
        let mockAutoplay = isMock && ProcessInfo.processInfo.environment["LUFTBRO_MOCK_AUTOPLAY"] == "1"
        Task {
            defer { restoring = false }
            if let p = pendingOpenPath { pendingOpenPath = nil; await openFile(path: p) }
            else if !mockAutoplay { await restoreLastSession() }
            else { await loadRecents() }
        }
        await waitForPictures()
        ready = true
        Task { await Updater.shared.checkAtLaunch() }

        if mockAutoplay {
            await devicesLoaded.value
            await openFile(path: Self.sampleMoviePath)
            // LUFTBRO_MOCK_START=2600 starts near the end (Up Next) for snapshots.
            play(startPosition: ProcessInfo.processInfo.environment["LUFTBRO_MOCK_START"].flatMap(Double.init))
        }
    }

    /// The launch restore (or the file the app was opened with) is still being read.
    @ObservationIgnored private var restoring = false

    /// At launch: the restored file's poster frame (or word that there are no
    /// pictures) before the window shows, at most `timeout`. A file that
    /// takes longer to read than that isn't waited for: the window opens and
    /// the file appears if and when it answers.
    private func waitForPictures(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !restoring && probe == nil { return }                           // nothing to wait for
            if probe != nil && (heroPoster != nil || thumbs.paletteUnavailable) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func shutdown() {
        pollTask?.cancel()
        backend.shutdown()
        if !isMock { saveLook() }
    }

    static let sampleMoviePath = "/Users/Shared/Movies/Night.Train.S01E03.1080p.WEB-DL.mkv"

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// One request at a time: the 1 s loop and the poll after a command
    /// (play, pause, a seek) would otherwise overlap, and an older answer
    /// arriving last would show an older state. A poll asked for while one
    /// runs makes exactly one more run right after it, and its caller waits
    /// for that one: Play clears "starting" when this returns, so it must not
    /// return before the fresh state is in.
    private func pollOnce() async {
        if let running = currentPoll {
            pollAgain = true
            await running.value
            return
        }
        let poll = Task {
            await pollRuns()
            currentPoll = nil      // on the main actor, right after the last run: no caller can slip in between
        }
        currentPoll = poll
        await poll.value
    }

    private func pollRuns() async {
        repeat {
            pollAgain = false
            let gen = backendGeneration
            do {
                let r = try await backend.state(since: lastSeq)
                guard gen == backendGeneration else { continue }       // from the backend before a restart
                pollFailures = 0
                pollFailingSince = nil
                pollError = nil
                backendUnresponsive = false
                apply(r)
            } catch {
                guard gen == backendGeneration else { continue }
                pollFailures += 1
                if pollFailures >= 3 { pollError = error.localizedDescription }
                // Alive but not answering (a hung Python): say so where the
                // user looks once it has gone on for 20 s, with Try Again.
                if let since = pollFailingSince {
                    if Date().timeIntervalSince(since) >= 20 { backendUnresponsive = true }
                } else {
                    pollFailingSince = Date()
                }
            }
        } while pollAgain
    }

    private func apply(_ r: StateResponse) {
        if r.seq < lastSeq {
            // A restart of our own backend bumps the generation and resets
            // lastSeq, so a lower seq here is a late, older answer: dropped,
            // instead of rolling the remote back and wiping the telemetry.
            // Only a backend the app attached to (LUFTBRO_API_PORT) can restart
            // behind its back: a lower seq that persists is taken as that.
            staleAnswers += 1
            guard staleAnswers >= 5 else { return }
            telemetry.resetAll()
        }
        staleAnswers = 0
        lastSeq = r.seq
        let sid = r.session?.id
        if sid != telemetry.sessionID {
            telemetry.resetSession(id: sid, startedAt: r.session?.startedAt)
        }
        telemetry.ingest(r)
        var trimmed = r
        trimmed.samples = []
        trimmed.requests = []
        trimmed.events = []
        live = trimmed
        reconcileOptimisticPosition()
        reconcilePendingPause()
        reconcileLibraryCursor()
        followCompletedDownload(r)
        trackTransitions(r)
        ensureSessionProbe(r)
        followThumbnails()
        nowPlaying.update()
        localPlayer.sync(r.localPlayer, subtitles: r.session?.subtitle != nil)
        followMarker()

        // Pairing driven by the backend (e.g. pairing started as part of Play).
        if let p = r.pairing, p.awaitingPin == true, let id = p.deviceId {
            pairingAwaitingPin = true
            if p.error != nil { pairingError = p.error }
            if pairingDeviceID == nil && dismissedPairingFor != id { pairingDeviceID = id }
        } else if r.pairing == nil {
            dismissedPairingFor = nil
        }
    }

    /// The loaded file was a download in progress and the backend now plays it
    /// under its finished name ("movie.mkv.part" → "movie.mkv"): the same file,
    /// so Setup follows the rename instead of treating it as another one.
    private func followCompletedDownload(_ r: StateResponse) {
        guard var p = probe, p.downloading == true, let file = r.session?.file, let path = file.path,
              path != p.path, path == (p.path as NSString).deletingPathExtension else { return }
        p.path = path
        p.name = file.name ?? p.name
        p.nameInfo = file.nameInfo ?? p.nameInfo
        p.downloading = false
        probe = p
        UserDefaults.standard.set(path, forKey: "lastFilePath")
        Task { await loadRecents() }
    }

    private func trackTransitions(_ r: StateResponse) {
        let ph = Phase(r.phase)
        SleepGuard.shared.update(streaming: ph.isActive && ph != .paused && r.session != nil)
        if let pending = pendingDeviceID, r.session?.device?.id == pending || !ph.isActive {
            pendingDeviceID = nil
        }
        if ph != lastPhase {
            if ph == .failed, let path = r.session?.file?.path {
                lastFailure = LastFailure(path: path, position: r.playback?.position ?? r.session?.startPosition,
                                          message: failureReason)
            }
            if lastPhase.isActive && (ph == .stopped || ph == .finished) && !switchingTracks {
                playerVisible = false            // back to Setup, same file still selected
                // Browsing ended with what played (not when Return is starting
                // the highlighted file: the old one stops on the way).
                if cursorPlayPath == nil { libraryCursor = nil }
                setSleepTimer(minutes: nil)      // it belonged to what played
                // Watched to the end: Setup gets the next episode, ready to play (never autoplays).
                let watched = ph == .finished || r.playback.map { ($0.position ?? 0) >= ($0.duration ?? .infinity) * 0.95 } == true
                let next = watched ? upNext : nil
                let choices = currentChoices()
                Task {
                    await refreshResumeAfterPlayback()
                    if let next { await openNext(next, carrying: choices, autoplay: false) }
                }
            }
            // A failed session saved its position too: Recents and the offer follow.
            if ph == .failed { Task { await refreshResumeAfterPlayback() } }
            // Something plays: "Up next after …" described the previous Setup only.
            if ph.isActive && !lastPhase.isActive { upNextAfter = nil }
            if ph.isActive && !lastPhase.isActive && r.session != nil && lastPhase == .idle && !playerVisible && !startingPlayback {
                // Session already running when the app (re)connected.
                playerVisible = true
                if probe == nil, let path = r.session?.file?.path { Task { await openFile(path: path) } }
            }
            if ph.isActive { switchingTracks = false }
            lastPhase = ph
        }
        let h = streamHealth
        if h > lastHealth && h >= .warning {
            healthAlertTick += 1
            if h >= .serious && UserDefaults.standard.bool(forKey: "autoOpenDiagnostics") {
                showDiagnostics(.overview)
            }
        }
        lastHealth = h
    }

    /// Overall health shown by the player's indicator.
    var streamHealth: Health {
        guard hasSession else { return .neutral }
        if phase == .failed || live?.session?.error != nil || live?.playback?.error != nil || live?.prep?.error != nil { return .critical }
        return DiagStatus(live?.diagnosis?.status).health
    }

    func showDiagnostics(_ section: DiagSection? = nil) {
        if let section { diagSection = section }
        diagnosticsOpen = true
    }

    func toggleDiagnostics() {
        diagnosticsOpen.toggle()
    }

    // MARK: - Derived

    /// Probe tracks apply to the running session only if it is the same file.
    private var probeMatchesSession: Bool { probe != nil && probe?.path == live?.session?.file?.path }

    /// Track list for the running session's file (Setup's probe if it is the
    /// same file, else a separate probe fetched when attaching to a session).
    var sessionTracks: ProbeResult? { probeMatchesSession ? probe : (sessionProbe?.path == live?.session?.file?.path ? sessionProbe : nil) }

    /// Active tracks come from the backend (session.audio.id etc.) so they are
    /// right even when another client or an earlier app run started the session.
    var sessionAudioID: Int? { live?.session?.audio?.id ?? (probeMatchesSession ? audioID : nil) }
    var sessionSubtitleID: Int {
        guard let s = live?.session else { return subtitleID }
        if let id = s.subtitle?.id { return id }
        if s.subtitle == nil, s.audio?.id != nil { return 0 }   // the backend reports tracks: null subtitle = off
        return probeMatchesSession ? subtitleID : 0
    }
    var sessionStereo: Bool { live?.session?.stereo ?? (probeMatchesSession ? stereo : false) }

    var currentAudioTitle: String {
        let suffix = sessionStereo ? " · stereo downmix" : ""
        if let id = sessionAudioID, let t = sessionTracks?.audioTracks.first(where: { $0.id == id }) { return Fmt.trackTitle(t) + suffix }
        return (Fmt.tidy(live?.session?.audio?.label) ?? "Audio") + suffix
    }

    var currentSubtitleTitle: String {
        let id = sessionSubtitleID
        if id == 0 { return "Subtitles off" }
        if let t = sessionTracks?.subtitleTracks.first(where: { $0.id == id }) { return Fmt.trackTitle(t) }
        return Fmt.tidy(live?.session?.subtitle?.label) ?? "Subtitles"
    }

    func setTelemetryLevel(_ level: String) {
        Task { _ = try? await backend.setTelemetry(level: level) }
    }

    var phase: Phase { Phase(live?.phase) }
    /// The main window shows the player: when asked to, or whenever the loaded
    /// file is the one playing (it is never shown as "ready to play" then).
    var showsPlayer: Bool {
        guard hasSession else { return false }
        return playerVisible || (canControl && probe?.path == live?.session?.file?.path)
    }
    /// ffmpeg is still preparing the stream while the TV already plays it.
    var prepInProgress: Bool {
        guard let p = live?.prep, phase.isActive, phase != .preparing, p.onDemand != true else { return false }
        return p.done != true && p.error == nil && (p.progress ?? 0) < 1
    }
    var hasSession: Bool { live?.session != nil }
    var canControl: Bool { phase.isActive && hasSession }
    /// Before the first picture: preparing, connecting, pairing, or the first
    /// buffering (a rebuffer after a seek has readyToPlay already).
    var isStarting: Bool {
        switch phase {
        case .preparing, .connecting, .pairing: return true
        case .buffering: return live?.playback?.readyToPlay != true
        default: return false
        }
    }
    /// Paused as the user sees it: right after Play / Pause the button
    /// shows the new state at once; the TV confirms within a second or so
    /// (waiting for that would make the button lag and the click feel lost).
    var isPaused: Bool { pendingPaused ?? (phase == .paused) }
    /// The state Play / Pause asked for, until the TV reports it (or 4 s pass).
    var pendingPaused: Bool?
    @ObservationIgnored var pendingPausedAt = Date.distantPast

    var selectedDevice: Device? { devices.first { $0.id == selectedDeviceID } }
    var selectedAudio: AudioTrack? { probe?.audioTracks.first { $0.id == audioID } }
    var selectedSubtitle: SubtitleTrack? { probe?.subtitleTracks.first { $0.id == subtitleID } }
    var willReencodeVideo: Bool { probe?.video?.mode == "reencode" || (selectedSubtitle?.burnsIn ?? false) }
    /// Something plays while another file is on screen (RemoteLayout's bar).
    var showsNowPlayingBar: Bool {
        canControl && !showsPlayer && live?.session?.file != nil
    }

    /// Under the ready screen's tiles, only when something about the TV
    /// needs saying. Not while the first scan runs (the pill says
    /// "Looking…"), or the line would come and go at every launch.
    var deviceHint: String? {
        guard let d = selectedDevice else {
            return scanning ? nil : "Choose an Apple TV in the pill above."
        }
        switch d.reachability {
        case .offline: return "\(d.displayName) is offline — choose another Apple TV, or switch it on and scan."
        case .notResponding: return "\(d.displayName) isn’t responding; Play will try to wake it."
        case .online: return nil
        }
    }

    var canPlay: Bool {
        backendStatus == .running && probe != nil && !startingPlayback
            && selectedDevice.map { $0.reachability != .offline } == true
    }

    // MARK: - File

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        // Downloads in progress ("movie.mkv.part") play too.
        for ext in ["mkv", "m2ts", "ts", "avi", "webm", "mpg", "mpeg", "vob", "mts", "m2t", "wmv", "asf", "flv",
                    "ogv", "ogm", "3gp", "dv", "rm", "rmvb", "divx", "part", "!qB", "!ut", "crdownload"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        // Leave the player only once a file is chosen (Cancel keeps it).
        if panel.runModal() == .OK, let url = panel.url {
            playerVisible = false
            Task { await openFile(path: url.path) }
        }
    }

    /// - history: entry from Recents (used if the probe doesn't carry `resume`).
    /// - offerResume: false for "Start Over" — tracks are still restored.
    /// - restoring: the launch restore — gives up on the probe after a few
    ///   seconds (a sleeping NAS) and says nothing: the file simply isn't restored.
    func openFile(path: String, history: HistoryEntry? = nil, offerResume: Bool = true, restoring: Bool = false) async {
        // Each open supersedes the one before, so a slower probe of an
        // earlier file can't replace the newer one.
        openSeq += 1
        let seq = openSeq
        probing = true
        probeError = nil
        upNextAfter = nil
        defer { if seq == openSeq { probing = false } }
        do {
            let p = try await probe(path: path, within: restoring ? 4 : nil)
            guard seq == openSeq else { return }
            probe = p
            audioID = p.defaultAudio ?? p.audioTracks.first?.id ?? 1
            subtitleID = p.defaultSubtitle ?? 0
            if !p.subtitleTracks.contains(where: { $0.id == subtitleID }) { subtitleID = 0 }
            stereo = false
            subtitleDelay = 0
            subtitleScale = 1
            resumeEntry = nil
            UserDefaults.standard.set(path, forKey: "lastFilePath")
            if let h = p.resume ?? history { applyHistory(h, offerResume: offerResume) }
            if !Self.hasOwnChoices(p.resume ?? history) { applySeriesChoices(to: p) }
            // A delay picked for this very file (also one never played) wins.
            if subtitleID != 0, let saved = Self.savedSubtitleTiming(for: p.path) {
                (subtitleDelay, subtitleScale) = saved
            }
            followOCR()
            followThumbnails()
            await loadRecents()      // opened files are listed in Recents too (listed ones keep their place)
        } catch {
            guard seq == openSeq else { return }
            probe = nil
            if !restoring {
                probeError = "Could not read “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)"
            }
        }
    }

    @ObservationIgnored private var openSeq = 0

    /// The probe, given up after `timeout` (nil: the backend's own, a minute).
    private func probe(path: String, within timeout: TimeInterval?) async throws -> ProbeResult {
        let backend = backend
        let work = Task { try await backend.probe(path: path) }
        guard let timeout else { return try await work.value }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            work.cancel()
        }
        defer { timer.cancel() }
        return try await work.value
    }

    @ObservationIgnored private var pendingOpenPath: String?

    /// Opens now if the backend is up, otherwise right after it has started.
    func requestOpen(path: String) {
        if backendStatus == .running { Task { await openFile(path: path) } } else { pendingOpenPath = path }
    }

    /// Restores tracks and stereo from a history entry. Not the TV: the one
    /// picked in the toolbar is where everything plays.
    private func applyHistory(_ h: HistoryEntry, offerResume: Bool) {
        guard let p = probe else { return }
        if let a = h.audio, p.audioTracks.contains(where: { $0.id == a }) { audioID = a }
        if let sub = h.subtitle, sub == 0 || p.subtitleTracks.contains(where: { $0.id == sub }) { subtitleID = sub }
        stereo = h.stereo ?? false
        subtitleDelay = h.subtitleDelay ?? 0
        subtitleScale = h.subtitleScale ?? 1
        resumeEntry = (offerResume && h.resumePosition != nil) ? h : nil
    }

    func loadRecents() async {
        do {
            let fresh = try await backend.recent(limit: 20).items ?? []
            // Rows keep the order they had while the app runs (what was played
            // moves up at the next launch); files new to the list go on top.
            let known = recents.map(\.path)
            let byPath = Dictionary(fresh.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            recents = fresh.filter { !known.contains($0.path) } + known.compactMap { byPath[$0] }
        } catch {
            recents = []      // a backend without /api/recent: just no list
        }
        followLastPlayed()
    }

    /// The file played most recently (not only opened).
    var lastPlayed: HistoryEntry? {
        recents.filter { ($0.position ?? 0) > 0 || $0.watched == true }.max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
    }
    /// Its probe, for its next episode: read quietly, not listed as opened.
    var lastPlayedProbe: ProbeResult?
    @ObservationIgnored private var lastPlayedProbePath: String?

    private func followLastPlayed() {
        guard let path = lastPlayed?.path, path != lastPlayedProbePath else { return }
        lastPlayedProbePath = path
        Task {
            let p = try? await backend.peek(path: path)
            if lastPlayedProbePath == path { lastPlayedProbe = p }
        }
    }

    /// On launch: restore the newest unfinished item into Setup (never auto-plays).
    private func restoreLastSession() async {
        await loadRecents()
        if let newest = recents.first, newest.resumePosition != nil {
            await openFile(path: newest.path, history: newest, restoring: true)
        } else if recents.isEmpty, let last = UserDefaults.standard.string(forKey: "lastFilePath"),
                  await Self.exists(last) {
            await openFile(path: last, restoring: true)
        }
        if probe == nil { launchLook = nil }        // nothing restored: no colours to keep
    }

    /// Off the main thread: asking after a file on a sleeping NAS or an
    /// unplugged disk can take seconds, and would hold the window.
    private static func exists(_ path: String) async -> Bool {
        await Task.detached { FileManager.default.fileExists(atPath: path) }.value
    }

    /// After a stop/finish the saved position changed: refresh Recents and the offer.
    private func refreshResumeAfterPlayback() async {
        await loadRecents()
        guard let path = probe?.path else { return }
        let e = recents.first { $0.path == path }
        resumeEntry = (e?.resumePosition != nil) ? e : nil
    }

    func closeFile() {
        launchLook = nil
        probe = nil
        probeError = nil
        upNextAfter = nil
    }

    // MARK: - Devices

    func loadDevices(refresh: Bool) async {
        await loadDevices(refresh ? .refresh : .cached)
    }

    func loadDevices(_ query: DeviceQuery) async {
        if query == .probe && scanning { return }   // a full scan is already running
        if query != .probe { scanning = true; devicesError = nil }
        defer { if query != .probe { scanning = false } }
        do {
            let r = try await backend.devices(query)
            let fresh = r.devices ?? []
            devices = query == .probe ? Self.stableMerge(old: devices, new: fresh) : fresh
            devicesError = nil
            autoSelectDevice()
        } catch {
            if query != .probe { devicesError = error.localizedDescription }
        }
    }

    /// Keeps rows from jumping around on every 5 s re-probe: rows are grouped by
    /// reachability (as the API orders them) but keep their previous relative order.
    private static func stableMerge(old: [Device], new: [Device]) -> [Device] {
        let oldIndex = Dictionary(old.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return new.enumerated().sorted { a, b in
            let ra = a.element.reachability.rawValue, rb = b.element.reachability.rawValue
            if ra != rb { return ra < rb }
            let ia = oldIndex[a.element.id] ?? (1000 + a.offset), ib = oldIndex[b.element.id] ?? (1000 + b.offset)
            return ia < ib
        }.map(\.element)
    }

    @ObservationIgnored private var userPickedDevice = false

    /// The TV picked in the toolbar: used for every file, and kept for the next launch.
    func selectDevice(_ id: String) {
        guard let d = devices.first(where: { $0.id == id }), d.reachability != .offline else { return }
        selectedDeviceID = id
        userPickedDevice = true
        UserDefaults.standard.set(id, forKey: Self.pickedDeviceKey)
        // Picking an Apple TV that isn't paired yet pairs it right away, rather
        // than leaving it to Play ("Pair & Play" still does, after a Cancel).
        if d.needsPairing, d.reachability == .online, pairingDeviceID == nil {
            startPairing(deviceID: id)
        }
    }

    private static let pickedDeviceKey = "pickedDeviceID"

    private func autoSelectDevice() {
        if let cur = selectedDevice, cur.reachability != .offline, userPickedDevice || cur.lastUsed == true || cur.reachability == .online {
            return
        }
        let online = devices.filter { $0.reachability == .online }
        let picked = UserDefaults.standard.string(forKey: Self.pickedDeviceKey)
        let pick = online.first { $0.id == picked }
            ?? online.first { $0.lastUsed == true }
            ?? online.first { !$0.needsPairing }
            ?? online.first
            ?? devices.first { $0.reachability == .notResponding && ($0.id == picked || $0.lastUsed == true) }
        if let pick, pick.id != selectedDeviceID {
            selectedDeviceID = pick.id
            userPickedDevice = pick.id == picked
        } else if pick == nil, selectedDevice?.reachability == .offline {
            selectedDeviceID = nil
        }
    }

    /// Re-probes reachability every ~5 s while the device list is on screen.
    func runDeviceProbeLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled || backendStatus != .running { break }
            await loadDevices(.probe)
        }
    }

    func startPairing(deviceID: String) {
        pairingDeviceID = deviceID
        pairingError = nil
        pairingAwaitingPin = false
        pairingBusy = true
        Task {
            defer { pairingBusy = false }
            do {
                let r = try await backend.pair(deviceID: deviceID)
                if r.ok == false {
                    pairingError = r.error ?? "Pairing could not be started."
                } else {
                    pairingAwaitingPin = true
                }
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    func submitPin(_ pin: String) {
        pairingBusy = true
        pairingError = nil
        Task {
            defer { pairingBusy = false }
            do {
                let r = try await backend.submitPin(pin)
                if r.ok == true {
                    let id = pairingDeviceID
                    pairingDeviceID = nil
                    pairingAwaitingPin = false
                    await loadDevices(refresh: false)
                    if let id, let i = devices.firstIndex(where: { $0.id == id }) { devices[i].paired = true }
                    if playAfterPairing { playAfterPairing = false; play(startPosition: pendingStartPosition) }
                    if let target = switchAfterPairing { switchAfterPairing = nil; switchDevice(target) }
                } else {
                    pairingError = r.error ?? "Pairing failed."
                }
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    func cancelPairing() {
        dismissedPairingFor = pairingDeviceID
        pairingDeviceID = nil
        playAfterPairing = false
        pairingAwaitingPin = false
        if switchAfterPairing != nil {
            switchAfterPairing = nil
            selectedDeviceID = live?.session?.device?.id ?? selectedDeviceID   // still playing where it was
            if let id = selectedDeviceID { UserDefaults.standard.set(id, forKey: Self.pickedDeviceKey) }
        }
    }

    // MARK: - Playback

    /// The last failed playback, kept for the ready view after "Done".
    struct LastFailure: Equatable {
        var path: String
        var position: Double?
        var message: String
    }
    var lastFailure: LastFailure?

    /// The raw reason the session failed, for the failure card.
    var failureReason: String {
        let l = live
        return l?.session?.error ?? l?.playback?.error ?? l?.prep?.error ?? l?.diagnosis?.headline ?? "unknown error"
    }

    /// After a failure: start the same file, tracks and device again where it stopped.
    func retryPlayback() {
        guard !startingPlayback, let s = live?.session, let path = s.file?.path, let deviceID = s.device?.id else { return }
        let req = PlayRequest(path: path,
                              audio: sessionAudioID ?? sessionTracks?.defaultAudio ?? 1,
                              subtitle: sessionSubtitleID,
                              deviceId: deviceID,
                              stereo: sessionStereo,
                              startPosition: live?.playback?.position ?? s.startPosition,
                              subtitleDelay: sessionSubtitleDelay, subtitleScale: sessionSubtitleScale)
        lastFailure = nil
        startingPlayback = true
        Task {
            defer { startingPlayback = false }
            do {
                let r = try await backend.play(req)
                if r.ok == false { alert = AlertInfo(title: "Couldn’t Start Playback", message: r.error ?? "Unknown error") }
                playerVisible = true
                await pollOnce()
            } catch {
                alert = AlertInfo(title: "Couldn’t Start Playback", message: error.localizedDescription)
            }
        }
    }

    /// One Play at a time (`startingPlayback`, cleared when the backend has
    /// answered, also on failure): a double-click, Return and a Play Now
    /// arriving together would otherwise send /api/play twice.
    func play(startPosition: Double? = nil) {
        guard !startingPlayback, let probe, let device = selectedDevice else { return }
        lastFailure = nil
        if device.needsPairing {
            playAfterPairing = true
            pendingStartPosition = startPosition
            startPairing(deviceID: device.id)
            return
        }
        startingPlayback = true
        rememberSeriesChoices(probe, audio: audioID, subtitle: subtitleID, stereo: stereo, delay: subtitleDelay,
                              scale: subtitleScale)
        let req = PlayRequest(path: probe.path, audio: audioID, subtitle: subtitleID, deviceId: device.id,
                              stereo: stereo, startPosition: startPosition,
                              subtitleDelay: subtitleID != 0 && subtitleDelay != 0 ? subtitleDelay : nil,
                              subtitleScale: subtitleID != 0 && subtitleScale != 1 ? subtitleScale : nil)
        Task {
            defer { startingPlayback = false }
            do {
                let r = try await backend.play(req)
                if r.ok == false {
                    alert = AlertInfo(title: "Couldn’t Start Playback", message: r.error ?? "Unknown error")
                } else {
                    playerVisible = true
                    upNextAfter = nil
                    await pollOnce()
                }
            } catch {
                alert = AlertInfo(title: "Couldn’t Start Playback", message: error.localizedDescription)
            }
        }
    }

    /// Mid-playback audio/subtitle change: re-POST /api/play at the current position.
    func switchTracks(audio: Int? = nil, subtitle: Int? = nil, stereo newStereo: Bool? = nil,
                      subtitleDelay newDelay: Double? = nil, subtitleScale newScale: Double? = nil,
                      then done: (() -> Void)? = nil) {
        guard !startingPlayback, let s = live?.session, let path = s.file?.path, let deviceID = s.device?.id else { done?(); return }
        // Baseline = what the backend says is playing, not local setup state.
        let req = PlayRequest(path: path,
                              audio: audio ?? sessionAudioID ?? sessionTracks?.defaultAudio ?? 1,
                              subtitle: subtitle ?? sessionSubtitleID,
                              deviceId: deviceID,
                              stereo: newStereo ?? sessionStereo,
                              startPosition: live?.playback?.position,
                              subtitleDelay: newDelay ?? sessionSubtitleDelay,
                              subtitleScale: newScale ?? sessionSubtitleScale)
        if probeMatchesSession {
            audioID = req.audio; subtitleID = req.subtitle; stereo = req.stereo
            subtitleDelay = req.subtitleDelay ?? 0
            subtitleScale = req.subtitleScale ?? 1
        }
        rememberSeriesChoices(sessionTracks, audio: req.audio, subtitle: req.subtitle, stereo: req.stereo,
                              delay: req.subtitleDelay ?? 0, scale: req.subtitleScale ?? 1)
        switchingTracks = true
        startingPlayback = true
        // This Mac: the stream restarts; the window (and full screen) stays.
        if playsOnThisMac { localPlayer.holdForNextStream() }
        Task {
            defer { startingPlayback = false; done?() }
            do {
                let r = try await backend.play(req)
                if r.ok == false {
                    switchingTracks = false
                    localPlayer.cancelHold()
                    alert = AlertInfo(title: "Couldn’t Switch Tracks", message: r.error ?? "Unknown error")
                }
                await pollOnce()
            } catch {
                switchingTracks = false
                localPlayer.cancelHold()
                alert = AlertInfo(title: "Couldn’t Switch Tracks", message: error.localizedDescription)
            }
        }
    }

    /// Probe of the running session's file when it differs from Setup's file.
    var sessionProbe: ProbeResult?
    @ObservationIgnored private var sessionProbePath: String?

    private func ensureSessionProbe(_ r: StateResponse) {
        guard let path = r.session?.file?.path, path != probe?.path, path != sessionProbePath else { return }
        sessionProbePath = path
        Task {
            if let p = try? await backend.probe(path: path) { sessionProbe = p } else { sessionProbePath = nil }
        }
    }

    func togglePause() {
        guard canControl else { return }
        let pause = !isPaused
        pendingPaused = pause
        pendingPausedAt = Date()
        if playsOnThisMac { localPlayer.pauseNow(pause) }
        control(ControlRequest(action: pause ? "pause" : "resume"))
    }

    /// After each state update: the TV reached the state asked for, or it
    /// didn't in time (then the real state shows again).
    private func reconcilePendingPause() {
        guard let want = pendingPaused else { return }
        let reached = phase == .paused ? want : (phase == .playing && !want)
        if reached || !phase.isActive || Date().timeIntervalSince(pendingPausedAt) > 4 {
            pendingPaused = nil
        }
    }

    func stop() {
        guard canControl else { return }
        localPlayer.cancelHold()
        control(ControlRequest(action: "stop"))
    }

    func seek(to position: Double) {
        guard canControl else { return }
        // Hold the target on the scrubber until the TV reports it: while it
        // seeks it briefly reports 0 or the old position, and the dot would jump there.
        optimisticPosition = position
        optimisticSetAt = Date()
        optimisticTimeout = 10
        control(ControlRequest(action: "seek", position: position))
    }

    // MARK: Skip (relative, in place on the TV)

    /// Main window is key (kept up to date by AppDelegate).
    var mainWindowIsKey = false
    /// Which control Tab has moved to (KeyFocus.swift); the library by default.
    var keyFocus: KeyFocus = .library
    /// The focusable controls on screen and what Return / Space do on them.
    @ObservationIgnored var keyActions: [KeyFocus: KeyFocusAction] = [:]
    /// The This Mac window is key (kept up to date by AppDelegate).
    var playerWindowIsKey = false
    /// ⌘← / ⌘→ skip only where the playing picture is what the user looks at.
    var skipKeysApply: Bool { playerHasKeyFocus || playerWindowIsKey }
    /// Plain ← / → skip only when the player is what the user is looking at,
    /// also with Diagnostics open (the key monitor leaves text fields alone, and
    /// a focused table keeps only ↑ / ↓).
    var playerHasKeyFocus: Bool { showsPlayer && mainWindowIsKey && pairingDeviceID == nil }

    /// Optimistic playhead after a skip until /api/state catches up.
    var optimisticPosition: Double?
    @ObservationIgnored private var optimisticSetAt = Date.distantPast
    /// How long to trust the optimistic position without a matching report
    /// (a seek can rebuffer for a few seconds; a skip lands quickly).
    @ObservationIgnored private var optimisticTimeout: TimeInterval = 3
    /// Total of the current burst of skips, shown as a "+20 s" bubble.
    var skipHint: Double?
    var skipHintTick = 0
    @ObservationIgnored private var pendingSkip = 0.0
    @ObservationIgnored private var skipFlushScheduled = false
    @ObservationIgnored private var skipFlushToken = 0
    /// An arrow key is held down: keep accumulating, send the skip on release.
    @ObservationIgnored private var skipKeyHeld = false

    /// Position to display: optimistic target (advancing while playing) or the TV's report.
    var displayPosition: Double? {
        if let o = optimisticPosition {
            let elapsed = phase == .playing ? Date().timeIntervalSince(optimisticSetAt) : 0
            return o + max(0, elapsed)
        }
        return live?.playback?.position
    }

    private var mediaDuration: Double {
        live?.session?.file?.durationS ?? live?.playback?.duration ?? .greatestFiniteMagnitude
    }

    /// Quick relative skip. Presses within 0.3 s are merged into one request.
    func skip(_ delta: Double) {
        guard canControl, let base = displayPosition else { return }
        let target = max(0, min(mediaDuration - 1, base + delta))
        let applied = target - base
        guard abs(applied) > 0.01 else { return }
        optimisticPosition = target
        optimisticSetAt = Date()
        // Long enough for a seek that has to restart the stream (a jump back
        // past what's prepared), so the playhead doesn't fall back to the old
        // position meanwhile and then jump again when the TV gets there.
        optimisticTimeout = 8
        pendingSkip += applied
        skipHint = (skipHint ?? 0) + applied
        skipHintTick += 1
        let tick = skipHintTick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { if self?.skipHintTick == tick { self?.skipHint = nil } }
        }
        // Only the playhead and the "+1:30" bubble move while skipping; the TV
        // gets one jump once the presses stop (key repeats keep resetting it).
        skipFlushScheduled = true
        let token = scheduleSkipFlush()
        // Key repeat starts within ~1.8 s at most (macOS's longest "delay until
        // repeat"); if nothing came for 2.5 s the key-up was lost (e.g. the
        // window lost focus): send anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.skipFlushToken == token, self.skipFlushScheduled else { return }
                self.skipKeyHeld = false
                self.flushSkip()
            }
        }
    }

    /// Sends the pending skip 0.3 s after the last press or arrow-key release,
    /// unless an arrow key is held then (a newer call supersedes this one).
    @discardableResult
    private func scheduleSkipFlush() -> Int {
        skipFlushToken += 1
        let token = skipFlushToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.skipFlushToken == token, !self.skipKeyHeld, self.skipFlushScheduled else { return }
                self.flushSkip()
            }
        }
        return token
    }

    /// Arrow key down (from the key monitor), so a held key sends nothing until released.
    func skipKeyPressed() { skipKeyHeld = true }

    /// Arrow key up: send once the presses stop, as with clicks. Sending on
    /// every key-up would make three quick → presses three requests, and the
    /// TV would land at +10 s instead of +30 s.
    func skipKeyReleased() {
        guard skipKeyHeld else { return }
        skipKeyHeld = false
        if skipFlushScheduled { scheduleSkipFlush() }
    }

    private func flushSkip() {
        skipFlushScheduled = false
        let seconds = (pendingSkip * 10).rounded() / 10
        pendingSkip = 0
        guard abs(seconds) > 0.01 else { return }
        // The wait for the TV starts now; carry the playhead on from where it
        // is shown (while playing it has advanced since the last press).
        if let o = optimisticPosition, phase == .playing {
            optimisticPosition = o + max(0, Date().timeIntervalSince(optimisticSetAt))
        }
        optimisticSetAt = Date()
        control(ControlRequest(action: "skip", seconds: seconds))
    }

    private func reconcileOptimisticPosition() {
        guard let o = optimisticPosition else { return }
        let reported = live?.playback?.position
        let age = Date().timeIntervalSince(optimisticSetAt)
        if skipFlushScheduled { return }
        // The TV has arrived when it reports the target or a little after it
        // (it may have played on since); anything else is the old position.
        if let reported, reported >= o - 2.5, reported <= o + age + 2.5 {
            optimisticPosition = nil
        } else if age > optimisticTimeout {
            optimisticPosition = nil
        }
    }

    // MARK: - TV volume

    /// Shown briefly in the remote's status line: "TV volume ▲" (or why it
    /// can't), "Intro skipped": what a key press just did.
    struct StatusHint: Equatable {
        var text: String
        var symbol: String
    }
    var statusHint: StatusHint?
    @ObservationIgnored private var statusHintToken = 0

    /// The session plays on a real Apple TV (not This Mac or a simulator).
    var playsOnAppleTV: Bool {
        guard let id = live?.session?.device?.id else { return false }
        return !id.hasPrefix("LOCAL:") && !id.hasPrefix("SIM:")
    }

    /// The session plays in the This Mac window.
    var playsOnThisMac: Bool {
        (live?.session?.device?.id ?? "").hasPrefix("LOCAL:")
    }

    /// M mutes This Mac: where the remote or the This Mac window has the keys
    /// (no PIN sheet; not in text fields), as H / J.
    var muteKeyApplies: Bool {
        playsOnThisMac && canControl && pairingDeviceID == nil
            && (playerWindowIsKey || mainWindowIsKey)
    }

    /// One notch up or down on the TV, through the Apple TV; on This Mac the
    /// player's own volume. A simulated device has none, so it only says so.
    func changeTVVolume(up: Bool) {
        guard canControl else { return }
        // A held ⌘↑ repeats ~20× a second: one step per 0.15 s, so the volume
        // doesn't keep changing after the key is let go.
        guard Date().timeIntervalSince(lastVolumeStepAt) >= 0.15 else { return }
        lastVolumeStepAt = Date()
        if playsOnThisMac {
            localPlayer.stepVolume(up: up)
            showThisMacVolume()
            return
        }
        guard playsOnAppleTV else {
            showVolumeHint("No volume on a simulated device")
            return
        }
        showVolumeHint(up ? "TV volume ▲" : "TV volume ▼")
        Task {
            let r = try? await backend.control(ControlRequest(action: "volume", step: up ? "up" : "down"))
            if r?.ok != true { showVolumeHint(r?.error.map { "No TV volume: \($0)" } ?? "No TV volume") }
        }
    }

    @ObservationIgnored private var lastVolumeStepAt = Date.distantPast

    /// M: mute or unmute This Mac.
    func toggleThisMacMute() {
        guard playsOnThisMac, canControl else { return }
        localPlayer.toggleMute()
        showThisMacVolume()
    }

    private func showThisMacVolume() {
        let a = localPlayer.adjustments
        showVolumeHint(a.muted ? "Muted" : "Volume " + a.volumeText)
    }

    private func showVolumeHint(_ text: String) {
        showStatusHint(text, symbol: "speaker.wave.2.fill")
    }

    func showStatusHint(_ text: String, symbol: String, seconds: Double = 1.6) {
        statusHint = StatusHint(text: text, symbol: symbol)
        statusHintToken += 1
        let token = statusHintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.statusHintToken == token else { return }
            self.statusHint = nil
        }
    }

    private func control(_ req: ControlRequest) {
        Task {
            do {
                let r = try await backend.control(req)
                if r.ok == false { alert = AlertInfo(title: "Couldn’t \(req.action.capitalized)", message: r.error ?? "Unknown error") }
                await pollOnce()
            } catch {
                alert = AlertInfo(title: "Couldn’t \(req.action.capitalized)", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Thumbnails

    private func followThumbnails() {
        let path = showsPlayer ? live?.session?.file?.path : (probe?.path ?? live?.session?.file?.path)
        thumbs.track(path: path, backend: backend)
    }

    // MARK: - Up next

    /// Next episode of the playing file, from its probe.
    var upNext: NextEpisode? { sessionTracks?.next }
    /// Title of the episode that finished when Setup was filled with the next one.
    var upNextAfter: String?

    /// Sleep timer (AppModel+Sleep.swift): playback stops at this time.
    var sleepAt: Date?
    @ObservationIgnored var sleepTask: Task<Void, Never>?
    /// Session for which the user closed the Up Next card.
    var upNextDismissedFor: String?

    var remaining: Double? {
        guard let p = displayPosition, let d = live?.session?.file?.durationS ?? live?.playback?.duration, d > 0 else { return nil }
        return max(0, d - p)
    }

    /// The player offers the next episode from the start of the credits when
    /// they are known (chapters, or found in the picture), else during the
    /// last 2½ minutes. Not before known credits: with short credits that
    /// would cover the final scene (and Space would play the next episode).
    var showUpNextCard: Bool {
        guard upNext != nil, canControl, let r = remaining, let sid = live?.session?.id,
              upNextDismissedFor != sid else { return false }
        return sessionMarkers?.credits != nil ? inCredits : r <= 150
    }

    /// The marker shown now (AppModel+Markers): the first seconds after it
    /// appears, Space runs it instead of pausing.
    var markerTakesSpace = false
    @ObservationIgnored var shownMarker: PlaybackMarker?
    @ObservationIgnored var markerSpaceToken = 0
    @ObservationIgnored var markerRanAt = Date.distantPast
    /// Markers the backend found without chapters, per file (AppModel+Markers).
    var detectedMarkers: [String: Markers] = [:]
    @ObservationIgnored var markersPollingPath: String?
    @ObservationIgnored var markersTask: Task<Void, Never>?

    /// What is playing now, to carry over to the next episode.
    struct Choices {
        var probe: ProbeResult?
        var audio: Int?
        var subtitle: Int
        var stereo: Bool
        var deviceID: String?
    }

    private func currentChoices() -> Choices {
        Choices(probe: sessionTracks, audio: sessionAudioID, subtitle: sessionSubtitleID,
                stereo: sessionStereo, deviceID: live?.session?.device?.id)
    }

    // MARK: - Library (keyboard)

    /// What is playing, if anything (also while another file is on screen).
    var nowPlayingPath: String? {
        guard hasSession, phase.isActive else { return nil }
        return live?.session?.file?.path
    }

    /// The library's Up Next: the next episode of what is playing, else of
    /// what was played last. Not of the file clicked or arrowed to: the list
    /// would change under the user while browsing.
    var libraryNext: NextEpisode? {
        if nowPlayingPath != nil { return upNext }
        guard let last = lastPlayed?.path else { return nil }
        if probe?.path == last { return probe?.next }
        return lastPlayedProbe?.path == last ? lastPlayedProbe?.next : nil
    }

    /// Recent, what plays included (in its place). The suggestion stays in its
    /// row too if it is listed; it only gets a row below when it isn't, so
    /// starting something never moves a file out of the list.
    var libraryRecents: [HistoryEntry] { Array(recents.prefix(10)) }

    /// The suggestion's own row at the bottom: only for an episode not listed.
    var librarySuggestion: NextEpisode? {
        guard let next = libraryNext, next.path != nowPlayingPath,
              !libraryRecents.contains(where: { $0.path == next.path }) else { return nil }
        return next
    }

    /// ↑ / ↓ go to the library: the main window has the keys, no sheet, and
    /// the Diagnostics drawer (whose tables use the arrows) is closed.
    var libraryHasKeyFocus: Bool {
        mainWindowIsKey && backendStatus == .running && pairingDeviceID == nil && keyFocus == .library
    }

    /// The row ↑ / ↓ moved to: while its file is still being read, or, while
    /// something plays, the row being browsed (the player stays on screen;
    /// Return plays it, Esc goes back to what plays).
    var libraryCursor: String?

    /// Something plays and the remote shows it: ↑ / ↓ browse instead of
    /// opening each file (that would swap the player for another file's ready
    /// screen and timeline, and Stop would then stop something not on screen).
    var libraryBrowsesOnly: Bool { showsPlayer && hasSession && phase.isActive }

    /// Return on a highlighted row: that file, until it plays.
    @ObservationIgnored var cursorPlayPath: String?
    @ObservationIgnored var cursorPlayAt = Date.distantPast

    /// After each state update: the highlighted row Return started now plays
    /// (the playing row is highlighted anyway), or it didn't start.
    private func reconcileLibraryCursor() {
        guard let path = cursorPlayPath else { return }
        let plays = nowPlayingPath == path
        let failed = phase == .failed && live?.session?.file?.path == path
        if plays || failed || Date().timeIntervalSince(cursorPlayAt) > 30 {
            cursorPlayPath = nil
            if libraryCursor == path { libraryCursor = nil }
        }
    }
    @ObservationIgnored private var libraryMoveSeq = 0

    /// ↑ / ↓: the next or previous row in the library, as on screen (Recent,
    /// then Suggested), also while something plays. A file is loaded as a click
    /// would (playback carries on); the playing row brings the player back. A
    /// held key steps through without reading every file on the way.
    func moveLibrarySelection(by step: Int) {
        moveLibrarySelection { i, count in i.map { $0 + step } ?? (step > 0 ? 0 : count - 1) }
    }

    /// Rows Page Up / Page Down move.
    static let libraryPage = 5

    /// ⌥↑ / ⌥↓, Home / End: the first or last row.
    func moveLibrarySelection(toLast: Bool) {
        moveLibrarySelection { _, count in toLast ? count - 1 : 0 }
    }

    /// target: the row to go to, from the current one (nil: none) and the row count.
    private func moveLibrarySelection(_ target: (Int?, Int) -> Int) {
        var order = libraryRecents.map(\.path)
        if let playing = nowPlayingPath, !order.contains(playing) { order.insert(playing, at: 0) }
        if let next = librarySuggestion { order.append(next.path) }
        guard !order.isEmpty else { return }
        let current = libraryCursor ?? (showsPlayer ? nowPlayingPath : probe?.path)
        let i = current.flatMap { order.firstIndex(of: $0) }
        let j = max(0, min(order.count - 1, target(i, order.count)))
        let path = order[j]
        guard path != current else { return }
        if libraryBrowsesOnly {
            libraryMoveSeq += 1
            libraryCursor = path == nowPlayingPath ? nil : path
            return
        }
        if path == nowPlayingPath {
            libraryMoveSeq += 1
            libraryCursor = nil
            playerVisible = true
            return
        }
        libraryCursor = path
        libraryMoveSeq += 1
        let seq = libraryMoveSeq
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard seq == libraryMoveSeq else { return }
            playerVisible = false
            await openFile(path: path, history: recents.first { $0.path == path })
            if seq == libraryMoveSeq { libraryCursor = nil }
        }
    }

    /// Space: the library's selected row plays (resumed), or pauses /
    /// resumes when it is what is playing. False when there is nothing to do.
    func playOrPauseLibrarySelection() -> Bool {
        // While browsing during playback the player is what's on screen:
        // Space pauses it (Return plays the browsed row).
        let selectedIsPlaying = showsPlayer
            || (libraryCursor == nil && probe?.path != nil && probe?.path == nowPlayingPath)
        if selectedIsPlaying {
            guard canControl else { return false }
            if spaceRunsMarker() { return true }       // Skip Intro / Next Episode just appeared
            togglePause()
            return true
        }
        guard libraryCursor != nil || canPlay else { return false }
        playLibrarySelection()
        return true
    }

    /// Enter on the ready screen: play what is selected (resumed), also when
    /// ↑ / ↓ just moved there and it is still being read.
    func playLibrarySelection() {
        if let path = libraryCursor {
            libraryMoveSeq += 1
            // The highlight stays on this row until it plays (or fails): cleared
            // at once, it would fall back to what still plays and jump back.
            cursorPlayPath = path
            cursorPlayAt = Date()
            if let e = recents.first(where: { $0.path == path }) { playNow(e); return }
            Task {
                await openFile(path: path)
                if probe?.path == path { play(startPosition: resumeEntry?.resumePosition) }
            }
        } else if canPlay {
            play(startPosition: resumeEntry?.resumePosition)
        }
    }

    /// Double-click in the playlist: open and start right away, at the saved position.
    func playNow(_ entry: HistoryEntry) {
        Task {
            await openFile(path: entry.path, history: entry)
            guard probe?.path == entry.path else { return }
            play(startPosition: resumeEntry?.resumePosition)
        }
    }

    /// "Play Now" on the Up Next card: same TV, matching audio and subtitles.
    func playNext() {
        guard let next = upNext else { return }
        let choices = currentChoices()
        // This Mac: the window (and full screen) stays for the next episode.
        if playsOnThisMac { localPlayer.holdForNextStream(cue: ("forward.end.alt.fill", "Next episode")) }
        Task { await openNext(next, carrying: choices, autoplay: true) }
    }

    private func openNext(_ next: NextEpisode, carrying c: Choices, autoplay: Bool) async {
        let finishedName = c.probe.map { Fmt.name($0.displayName, $0.nameInfo).title }
        await openFile(path: next.path)
        guard let p = probe, p.path == next.path else {
            localPlayer.cancelHold()                // couldn't open it: no stream is coming
            return
        }
        // Opening a file lists it in Recents, so the probe nearly always has a
        // history entry (without tracks). Only an episode left part-way with
        // tracks of its own keeps them; otherwise match the ones just played.
        if !Self.hasOwnChoices(p.resume), let old = c.probe {
            (audioID, subtitleID) = Self.carryOver(from: old, audio: c.audio, subtitle: c.subtitle, to: p)
            stereo = c.stereo
        }
        if let id = c.deviceID, devices.contains(where: { $0.id == id && $0.reachability != .offline }) {
            selectedDeviceID = id
            userPickedDevice = true
        }
        if autoplay {
            play(startPosition: resumeEntry?.resumePosition)
        } else {
            upNextAfter = finishedName
        }
    }

    /// Track ids in `new` that best match the ones chosen in `old`: same
    /// language, preferring the same title (e.g. "Commentary", "SDH") and codec.
    /// Subtitles keep forced-ness first (a forced track shows only the foreign
    /// lines, so it never stands in for full subtitles, nor the other way
    /// round), then text vs. burned-in pictures, then title and codec.
    static func carryOver(from old: ProbeResult, audio: Int?, subtitle: Int, to new: ProbeResult) -> (audio: Int, subtitle: Int) {
        carryOver(audio: old.audioTracks.first { $0.id == audio },
                  subtitle: subtitle == 0 ? nil : old.subtitleTracks.first { $0.id == subtitle },
                  // Turned off on purpose (the old file offered a default) → keep off.
                  keepOff: subtitle == 0 && (old.defaultSubtitle ?? 0) != 0,
                  to: new)
    }

    /// The same, from the tracks themselves (also what a series remembers).
    static func carryOver(audio oa: AudioTrack?, subtitle os: SubtitleTrack?, keepOff: Bool,
                          to new: ProbeResult) -> (audio: Int, subtitle: Int) {
        func lang(_ l: String?) -> String { (l ?? "").lowercased() }
        func title(_ t: String?) -> String { (t ?? "").lowercased() }
        let defaultAudio = new.defaultAudio ?? new.audioTracks.first?.id ?? 1
        var a = defaultAudio
        if let oa {
            let same = new.audioTracks.filter { lang($0.lang) == lang(oa.lang) }
            a = (same.first { title($0.title) == title(oa.title) && $0.codec == oa.codec }
                 ?? same.first { title($0.title) == title(oa.title) }
                 ?? same.first { $0.codec == oa.codec }
                 ?? same.first)?.id ?? defaultAudio
        }
        let newDefaultSub = new.subtitleTracks.contains { $0.id == new.defaultSubtitle } ? (new.defaultSubtitle ?? 0) : 0
        var s = newDefaultSub
        if keepOff {
            s = 0
        } else if let os {
            func score(_ t: SubtitleTrack) -> Int {
                ((t.forced ?? false) == (os.forced ?? false) ? 8 : 0)
                    + (t.burnsIn == os.burnsIn ? 4 : 0)
                    + (title(t.title) == title(os.title) ? 2 : 0)
                    + (t.codec == os.codec ? 1 : 0)
            }
            // Highest score wins; the earlier track on a tie.
            let best = new.subtitleTracks.filter { lang($0.lang) == lang(os.lang) }
                .enumerated().max { (score($0.element), -$0.offset) < (score($1.element), -$1.offset) }
            s = best?.element.id ?? newDefaultSub
        }
        return (a, s)
    }

    // MARK: - Moving playback to another device

    /// Move what is playing to another Apple TV (or This Mac), continuing at
    /// the current position with the same tracks.
    func switchDevice(_ id: String) {
        guard !startingPlayback, let s = live?.session, let path = s.file?.path, s.device?.id != id,
              let d = devices.first(where: { $0.id == id }), d.reachability != .offline else { return }
        selectedDeviceID = id
        userPickedDevice = true
        UserDefaults.standard.set(id, forKey: Self.pickedDeviceKey)
        if d.needsPairing {
            switchAfterPairing = id         // submitPin moves playback once paired
            startPairing(deviceID: id)
            return
        }
        pendingDeviceID = id
        let req = PlayRequest(path: path,
                              audio: sessionAudioID ?? sessionTracks?.defaultAudio ?? 1,
                              subtitle: sessionSubtitleID,
                              deviceId: id,
                              stereo: sessionStereo,
                              startPosition: live?.playback?.position,
                              subtitleDelay: sessionSubtitleDelay, subtitleScale: sessionSubtitleScale)
        switchingTracks = true
        startingPlayback = true
        Task {
            defer { startingPlayback = false }
            do {
                let r = try await backend.play(req)
                if r.ok == false {
                    switchingTracks = false
                    alert = AlertInfo(title: "Couldn’t Switch to \(d.displayName)", message: r.error ?? "Unknown error")
                }
                await pollOnce()
            } catch {
                switchingTracks = false
                alert = AlertInfo(title: "Couldn’t Switch to \(d.displayName)", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Sharing

    func diagnosticsReport() -> String {
        var out: [String] = ["Luftbro diagnostics — \(Fmt.time(Date()))"]
        if let s = live?.session {
            out.append("File: \(s.file?.name ?? "?") (\(Fmt.bytes(s.file?.sizeBytes)), \(Fmt.clock(s.file?.durationS)))")
            out.append("Device: \(s.device?.name ?? "?") \(s.device?.model ?? "") \(s.device?.address ?? "")")
            out.append("Video: \(Fmt.codec(s.video?.codec)) \(s.video?.mode ?? "")\(s.video?.reason.map { " (\($0))" } ?? "") · Audio: \(s.audio?.label ?? "?") \(s.audio?.mode ?? "") · Subtitles: \(s.subtitle?.label ?? "off")")
            out.append("Stream bitrate: \(Fmt.mbit(s.streamBitrateBps)) · segments \(s.segmentsReady ?? 0)/\(s.segmentsTotal ?? 0)")
        }
        out.append("Phase: \(phase.title)")
        if let e = live?.session?.error { out.append("Error: \(e)") }
        if let d = live?.diagnosis {
            out.append("")
            out.append("Diagnosis: \(DiagStatus(d.status).title) — \(d.headline ?? "")")
            for l in d.details ?? [] { out.append("  • \(l)") }
            for s in d.suspects ?? [] {
                out.append("  \(Cause(s.cause).title): \(Fmt.percent(s.confidence)) — \(s.evidence ?? "")")
            }
        }
        if let pb = live?.playback {
            out.append("")
            out.append("Playback: \(Fmt.clock(pb.position)) / \(Fmt.clock(pb.duration)), buffer \(Fmt.seconds(pb.bufferedAheadS)), stalls \(pb.stallCount ?? 0) (\(Fmt.seconds(pb.stalledSTotal)))\(pb.error.map { ", player error: \($0)" } ?? "")")
        }
        if let p = live?.prep {
            out.append("Prep: \(Fmt.percent(p.progress)) at \(Fmt.speed(p.speed))\(p.done == true ? " (done)" : "")\(p.error.map { ", error: \($0)" } ?? "")")
        }
        if let n = live?.network {
            out.append("Network: now \(Fmt.mbit(n.txBpsNow)), avg10 \(Fmt.mbit(n.txBpsAvg10)), RTT \(Fmt.ms(n.rttMs)) (avg \(Fmt.ms(n.rttMsAvg)), loss \(Fmt.percent(n.rttLoss))), HTTP errors \(n.httpErrors ?? 0), aborts \(n.clientAborts ?? 0)")
        }
        let notable = telemetry.events.filter { LogLevel($0.level) != .info }.suffix(25)
        if !notable.isEmpty {
            out.append("")
            out.append("Recent warnings/errors:")
            for e in notable { out.append("  \(Fmt.time(e.t)) [\(e.level ?? "")/\(e.source ?? "")] \(e.message ?? "")") }
        }
        return out.joined(separator: "\n")
    }

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
