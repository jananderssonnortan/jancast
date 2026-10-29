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
            // Faster latency probing only while someone is looking.
            if diagnosticsOpen != oldValue { setTelemetryLevel(diagnosticsOpen ? "detailed" : "basic") }
        }
    }
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
    /// Text recognition of the selected picture subtitle track (Setup).
    var ocrStatus: OCRStatus?
    @ObservationIgnored var ocrTask: Task<Void, Never>?
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
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollFailures = 0
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
        let mock = CommandLine.arguments.contains("--mock") || env["JANCAST_MOCK"] == "1"
        return AppModel(mock: mock)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await connect()
    }

    func restartBackend() async {
        pollTask?.cancel()
        backend.shutdown()
        backend = isMock ? MockBackend() : LiveBackend()
        lastSeq = 0
        telemetry.resetAll()
        live = nil
        await connect()
    }

    private func connect() async {
        backendStatus = .starting
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
        if let p = pendingOpenPath { pendingOpenPath = nil; await openFile(path: p) }
        else if !(isMock && ProcessInfo.processInfo.environment["JANCAST_MOCK_AUTOPLAY"] == "1") { await restoreLastSession() }
        else { await loadRecents() }
        await waitForPictures()
        ready = true
        Task { await Updater.shared.checkAtLaunch() }

        if isMock, ProcessInfo.processInfo.environment["JANCAST_MOCK_AUTOPLAY"] == "1" {
            await devicesLoaded.value
            await openFile(path: Self.sampleMoviePath)
            // JANCAST_MOCK_START=2600 starts near the end (Up Next) for snapshots.
            play(startPosition: ProcessInfo.processInfo.environment["JANCAST_MOCK_START"].flatMap(Double.init))
        }
    }

    /// At launch: the restored file's poster frame (or word that there are no
    /// pictures) before the window shows, at most `timeout`.
    private func waitForPictures(timeout: TimeInterval = 1.5) async {
        guard probe != nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, heroPoster == nil, !thumbs.paletteUnavailable {
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

    private func pollOnce() async {
        do {
            let r = try await backend.state(since: lastSeq)
            pollFailures = 0
            pollError = nil
            apply(r)
        } catch {
            pollFailures += 1
            if pollFailures >= 3 { pollError = error.localizedDescription }
        }
    }

    private func apply(_ r: StateResponse) {
        if r.seq < lastSeq {
            // Backend restarted; start over.
            telemetry.resetAll()
        }
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
        followCompletedDownload(r)
        trackTransitions(r)
        ensureSessionProbe(r)
        followThumbnails()
        nowPlaying.update()
        localPlayer.sync(r.localPlayer, subtitles: r.session?.subtitle != nil)

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
        if s.subtitle == nil, s.audio?.id != nil { return 0 }   // new backend: null subtitle = off
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
    var isPaused: Bool { phase == .paused }

    var selectedDevice: Device? { devices.first { $0.id == selectedDeviceID } }
    var selectedAudio: AudioTrack? { probe?.audioTracks.first { $0.id == audioID } }
    var selectedSubtitle: SubtitleTrack? { probe?.subtitleTracks.first { $0.id == subtitleID } }
    var willReencodeVideo: Bool { probe?.video?.mode == "reencode" || (selectedSubtitle?.burnsIn ?? false) }
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
        for ext in ["mkv", "m2ts", "ts", "avi", "webm", "part", "!qB", "!ut", "crdownload"] {
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
    func openFile(path: String, history: HistoryEntry? = nil, offerResume: Bool = true) async {
        probing = true
        probeError = nil
        upNextAfter = nil
        defer { probing = false }
        do {
            let p = try await backend.probe(path: path)
            probe = p
            audioID = p.defaultAudio ?? p.audioTracks.first?.id ?? 1
            subtitleID = p.defaultSubtitle ?? 0
            if !p.subtitleTracks.contains(where: { $0.id == subtitleID }) { subtitleID = 0 }
            stereo = false
            subtitleDelay = 0
            resumeEntry = nil
            UserDefaults.standard.set(path, forKey: "lastFilePath")
            if let h = p.resume ?? history { applyHistory(h, offerResume: offerResume) }
            if !Self.hasOwnChoices(p.resume ?? history) { applySeriesChoices(to: p) }
            followOCR()
            followThumbnails()
            await loadRecents()      // opened files are listed in Recents too (listed ones keep their place)
        } catch {
            probe = nil
            probeError = "Could not read “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)"
        }
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
            recents = []      // older backend without /api/recent: just no list
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
            await openFile(path: newest.path, history: newest)
        } else if recents.isEmpty, let last = UserDefaults.standard.string(forKey: "lastFilePath"),
                  FileManager.default.fileExists(atPath: last) {
            await openFile(path: last)
        }
        if probe == nil { launchLook = nil }        // nothing restored: no colours to keep
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
        guard let s = live?.session, let path = s.file?.path, let deviceID = s.device?.id else { return }
        let req = PlayRequest(path: path,
                              audio: sessionAudioID ?? sessionTracks?.defaultAudio ?? 1,
                              subtitle: sessionSubtitleID,
                              deviceId: deviceID,
                              stereo: sessionStereo,
                              startPosition: live?.playback?.position ?? s.startPosition,
                              subtitleDelay: sessionSubtitleDelay)
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

    func play(startPosition: Double? = nil) {
        guard let probe, let device = selectedDevice else { return }
        lastFailure = nil
        if device.needsPairing {
            playAfterPairing = true
            pendingStartPosition = startPosition
            startPairing(deviceID: device.id)
            return
        }
        startingPlayback = true
        rememberSeriesChoices(probe, audio: audioID, subtitle: subtitleID, stereo: stereo, delay: subtitleDelay)
        let req = PlayRequest(path: probe.path, audio: audioID, subtitle: subtitleID, deviceId: device.id,
                              stereo: stereo, startPosition: startPosition,
                              subtitleDelay: subtitleID != 0 && subtitleDelay != 0 ? subtitleDelay : nil)
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
                      subtitleDelay newDelay: Double? = nil) {
        guard let s = live?.session, let path = s.file?.path, let deviceID = s.device?.id else { return }
        // Baseline = what the backend says is playing, not local setup state.
        let req = PlayRequest(path: path,
                              audio: audio ?? sessionAudioID ?? sessionTracks?.defaultAudio ?? 1,
                              subtitle: subtitle ?? sessionSubtitleID,
                              deviceId: deviceID,
                              stereo: newStereo ?? sessionStereo,
                              startPosition: live?.playback?.position,
                              subtitleDelay: newDelay ?? sessionSubtitleDelay)
        if probeMatchesSession {
            audioID = req.audio; subtitleID = req.subtitle; stereo = req.stereo
            subtitleDelay = req.subtitleDelay ?? 0
        }
        rememberSeriesChoices(sessionTracks, audio: req.audio, subtitle: req.subtitle, stereo: req.stereo,
                              delay: req.subtitleDelay ?? 0)
        switchingTracks = true
        startingPlayback = true
        Task {
            defer { startingPlayback = false }
            do {
                let r = try await backend.play(req)
                if r.ok == false {
                    switchingTracks = false
                    alert = AlertInfo(title: "Couldn’t Switch Tracks", message: r.error ?? "Unknown error")
                }
                await pollOnce()
            } catch {
                switchingTracks = false
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
        control(ControlRequest(action: isPaused ? "resume" : "pause"))
    }

    func stop() {
        guard canControl else { return }
        control(ControlRequest(action: "stop"))
    }

    func seek(to position: Double) {
        guard canControl else { return }
        // Hold the target on the scrubber until the TV reports it: while it
        // seeks it briefly reports 0 or the old position, and the dot jumped there.
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
    /// Plain ← / → skip only when the player is what the user is looking at.
    /// Not while the Diagnostics drawer is open: its tables need the arrow keys
    /// (the key monitor in AppDelegate still skips when no table has focus).
    var playerHasKeyFocus: Bool { showsPlayer && mainWindowIsKey && pairingDeviceID == nil && !diagnosticsOpen }

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
        optimisticTimeout = 3
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
    /// every key-up made three quick → presses three requests, and the TV
    /// ended up +10 s instead of +30 s.
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

    /// Shown briefly by the TV pill: "TV volume ▲", or why it can't.
    var volumeHint: String?
    @ObservationIgnored private var volumeHintToken = 0

    /// The session plays on a real Apple TV (not This Mac or a simulator).
    var playsOnAppleTV: Bool {
        guard let id = live?.session?.device?.id else { return false }
        return !id.hasPrefix("LOCAL:") && !id.hasPrefix("SIM:")
    }

    /// One notch up or down on the TV, through the Apple TV. This Mac uses
    /// the Mac's own volume, so there it only says so.
    func changeTVVolume(up: Bool) {
        guard canControl else { return }
        // A held ⌘↑ repeats ~20× a second: one step per 0.15 s, so the volume
        // doesn't keep changing after the key is let go.
        guard Date().timeIntervalSince(lastVolumeStepAt) >= 0.15 else { return }
        lastVolumeStepAt = Date()
        guard playsOnAppleTV else {
            showVolumeHint("This Mac uses the Mac’s volume")
            return
        }
        showVolumeHint(up ? "TV volume ▲" : "TV volume ▼")
        Task {
            let r = try? await backend.control(ControlRequest(action: "volume", step: up ? "up" : "down"))
            if r?.ok != true { showVolumeHint(r?.error.map { "No TV volume: \($0)" } ?? "No TV volume") }
        }
    }

    @ObservationIgnored private var lastVolumeStepAt = Date.distantPast

    private func showVolumeHint(_ text: String) {
        volumeHint = text
        volumeHintToken += 1
        let token = volumeHintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.volumeHintToken == token else { return }
            self.volumeHint = nil
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

    /// The player offers the next episode during the last minutes (credits).
    var showUpNextCard: Bool {
        guard upNext != nil, canControl, let r = remaining, let sid = live?.session?.id else { return false }
        return r <= 150 && upNextDismissedFor != sid
    }

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

    /// Double-click in the playlist: open and start right away — at the saved
    /// position, on the TV it last played on (if it is reachable).
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
        mainWindowIsKey && backendStatus == .running && pairingDeviceID == nil && !diagnosticsOpen && keyFocus == .library
    }

    /// The row ↑ / ↓ moved to while its file is still being read.
    var libraryCursor: String?
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

    /// Enter on the ready screen: play what is selected (resumed), also when
    /// ↑ / ↓ just moved there and it is still being read.
    func playLibrarySelection() {
        if let path = libraryCursor {
            libraryMoveSeq += 1
            libraryCursor = nil
            if let e = recents.first(where: { $0.path == path }) { playNow(e); return }
            Task {
                await openFile(path: path)
                if probe?.path == path { play(startPosition: resumeEntry?.resumePosition) }
            }
        } else if canPlay {
            play(startPosition: resumeEntry?.resumePosition)
        }
    }

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
        Task { await openNext(next, carrying: choices, autoplay: true) }
    }

    private func openNext(_ next: NextEpisode, carrying c: Choices, autoplay: Bool) async {
        let finishedName = c.probe.map { Fmt.name($0.displayName, $0.nameInfo).title }
        await openFile(path: next.path)
        guard let p = probe, p.path == next.path else { return }
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
        guard let s = live?.session, let path = s.file?.path, s.device?.id != id,
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
                              subtitleDelay: sessionSubtitleDelay)
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
        var out: [String] = ["Jancast diagnostics — \(Fmt.time(Date()))"]
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
