import AppKit

/// In-process simulation of the backend, used with `--mock` / JANCAST_MOCK=1.
///
/// Scenario (sim seconds after Play): preparing → connecting → buffering →
/// playing; at ~60 s the Wi-Fi degrades (segment delivery falls below the
/// stream bitrate, RTT spikes and times out, the TV buffer drains, one stall,
/// a client abort), at ~102 s it recovers. Selecting the PGS subtitle (or a
/// file whose name contains "av1") switches to a re-encode with ~1.4× prep
/// speed so the encoder side can be seen too.
///
/// JANCAST_MOCK_SPEED=N runs the simulation N× faster than wall time.
@MainActor
final class MockBackend: Backend {
    let isMock = true
    var onUnexpectedExit: ((String, String) -> Void)?

    private let speed: Double
    private let failAt: Int? = ProcessInfo.processInfo.environment["JANCAST_MOCK_FAIL"].flatMap(Int.init)
    private var seq = 1000
    private var rng = LCG(seed: 0x5EED)
    private var devices: [Device] = {
        let now = Date().timeIntervalSince1970
        return [
            Device(id: "AA:BB:CC:00:00:01", name: "Living Room", address: "192.168.1.20",
                   model: "Apple TV 4K (gen 3)", paired: true, pairingRequired: true, lastUsed: true,
                   status: "online", reachable: true, rttMs: 3.1, lastSeen: now, probedAt: now),
            Device(id: "AA:BB:CC:00:00:02", name: "Bedroom", address: "192.168.1.31",
                   model: "Apple TV 4K (gen 2)", paired: false, pairingRequired: true, lastUsed: false,
                   status: "online", reachable: true, rttMs: 7.8, lastSeen: now, probedAt: now),
            Device(id: "AA:BB:CC:00:00:03", name: "Office", address: "192.168.1.44",
                   model: "Apple TV HD", paired: true, pairingRequired: true, lastUsed: false,
                   status: "not_responding", reachable: false, rttMs: nil, lastSeen: now - 40, probedAt: now),
            Device(id: "AA:BB:CC:00:00:04", name: "Kitchen", address: "192.168.1.52",
                   model: "Apple TV 4K (gen 1)", paired: true, pairingRequired: true, lastUsed: false,
                   status: "offline", reachable: false, rttMs: nil, lastSeen: now - 2 * 3600 - 300, probedAt: now),
        ]
    }()
    private var pairing: PairingState?
    private var sim: Sim?
    private var history: [HistoryEntry] = {
        let now = Date().timeIntervalSince1970
        let dir = "/Users/Shared/Movies/"
        return [
            HistoryEntry(path: dir + "Night.Train.S01E03.1080p.WEB-DL.mkv", name: "Night.Train.S01E03.1080p.WEB-DL.mkv",
                         sizeBytes: 3_458_200_000, mtime: now - 9 * 86400, position: 1630, duration: 2700, watched: false,
                         resumePosition: 1630, audio: 3, subtitle: 3, deviceId: "AA:BB:CC:00:00:01", stereo: false,
                         updatedAt: now - 26 * 3600),
            HistoryEntry(path: dir + "Night.Train.S01E02.1080p.WEB-DL.mkv", name: "Night.Train.S01E02.1080p.WEB-DL.mkv",
                         sizeBytes: 3_301_000_000, mtime: now - 9 * 86400, position: 2700, duration: 2700, watched: true,
                         resumePosition: nil, audio: 1, subtitle: 0, deviceId: "AA:BB:CC:00:00:01", stereo: false,
                         updatedAt: now - 2 * 86400 - 3600),
            HistoryEntry(path: dir + "Deep.Water.2021.2160p.HDR.WEB.mkv", name: "Deep.Water.2021.2160p.HDR.WEB.mkv",
                         sizeBytes: 9_120_000_000, mtime: now - 30 * 86400, position: 270, duration: 2700, watched: false,
                         resumePosition: 270, audio: 1, subtitle: 1, deviceId: "AA:BB:CC:00:00:02", stereo: true,
                         updatedAt: now - 5 * 86400),
        ]
    }()
    private var lastWall: Date?
    private var telemetryLevel = "basic"
    private var simCarry: Double = 0

    private var samples: [Sample] = []
    private var requests: [RequestRecord] = []
    private var events: [Event] = []

    init() {
        let s = ProcessInfo.processInfo.environment["JANCAST_MOCK_SPEED"].flatMap(Double.init) ?? 1
        speed = max(0.1, min(s, 50))
    }

    func start() async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
        log("info", "app", "Mock backend started (simulated data, nothing is sent to a TV)")
    }

    func shutdown() {}

    func recent(limit: Int) async throws -> RecentResponse {
        RecentResponse(items: Array(history.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }.prefix(limit)))
    }

    /// Mirrors the backend: saved every 10 s while playing and on stop/finish.
    private func saveHistory(_ s: Sim) {
        guard s.tvReported else { return }
        let r = s.request
        let watched = s.position >= Sim.duration * 0.95
        let entry = HistoryEntry(path: r.path, name: s.session.file?.name, sizeBytes: s.session.file?.sizeBytes,
                                 mtime: nil, position: s.position, duration: Sim.duration, watched: watched,
                                 resumePosition: (s.position < 30 || watched) ? nil : s.position,
                                 audio: r.audio, subtitle: r.subtitle, deviceId: r.deviceId, stereo: r.stereo,
                                 updatedAt: Date().timeIntervalSince1970)
        history.removeAll { $0.path == r.path }
        history.insert(entry, at: 0)
    }

    // MARK: - Setup endpoints

    func peek(path: String) async throws -> ProbeResult { try await probe(path: path) }

    func probe(path: String) async throws -> ProbeResult {
        try? await Task.sleep(nanoseconds: 450_000_000)
        let name = (path as NSString).lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.doubleValue ?? 3_458_200_000
        let av1 = name.lowercased().contains("av1")
        return ProbeResult(
            path: path, name: name, sizeBytes: size, durationS: Sim.duration,
            video: ProbeVideo(codec: av1 ? "av1" : "h264", width: 1920, height: 1080, hdr: false,
                              mode: av1 ? "reencode" : "copy",
                              reason: av1 ? "AV1 not supported by Apple TV" : nil),
            audio: [
                AudioTrack(id: 1, label: "eng (eac3, 6ch)", lang: "eng", title: "", codec: "eac3", channels: 6, isDefault: true, forced: false, mode: "copy"),
                AudioTrack(id: 2, label: "eng  Commentary (aac, 2ch)", lang: "eng", title: "Commentary", codec: "aac", channels: 2, isDefault: false, forced: false, mode: "copy"),
                AudioTrack(id: 3, label: "swe (ac3, 6ch)", lang: "swe", title: "", codec: "ac3", channels: 6, isDefault: false, forced: false, mode: "copy"),
                AudioTrack(id: 4, label: "jpn (truehd, 8ch)", lang: "jpn", title: "", codec: "truehd", channels: 8, isDefault: false, forced: false, mode: "transcode"),
            ],
            subtitles: [
                SubtitleTrack(id: 1, label: "eng  English (subrip)", lang: "eng", title: "English", codec: "subrip", isDefault: false, forced: false, external: false, mode: "soft"),
                SubtitleTrack(id: 2, label: "eng  English SDH (subrip)", lang: "eng", title: "English SDH", codec: "subrip", isDefault: false, forced: false, external: false, mode: "soft"),
                SubtitleTrack(id: 3, label: "swe  Svenska (subrip)", lang: "swe", title: "Svenska", codec: "subrip", isDefault: false, forced: false, external: false, mode: "soft"),
                SubtitleTrack(id: 4, label: "eng  English (hdmv_pgs_subtitle) [image - burned in, re-encodes video]", lang: "eng", title: "English", codec: "hdmv_pgs_subtitle", isDefault: false, forced: false, external: false, mode: "burn"),
                SubtitleTrack(id: 5, label: "fre  Français forcé (ass) [forced]", lang: "fre", title: "Français forcé", codec: "ass", isDefault: false, forced: true, external: false, mode: "soft"),
            ],
            defaultAudio: 1, defaultSubtitle: 0,
            resume: history.first { $0.path == path },
            next: Self.nextEpisode(after: path))
    }

    /// "…S01E03…" → "…S01E04…" (the mock pretends every next episode exists).
    private static func nextEpisode(after path: String) -> NextEpisode? {
        guard let r = path.range(of: "S(\\d{2})E(\\d{2})", options: .regularExpression) else { return nil }
        let tag = path[r]
        guard let season = Int(tag.dropFirst().prefix(2)), let ep = Int(tag.suffix(2)) else { return nil }
        let next = path.replacingCharacters(in: r, with: String(format: "S%02dE%02d", season, ep + 1))
        return NextEpisode(path: next, name: (next as NSString).lastPathComponent, season: season, episode: ep + 1)
    }

    // MARK: - Thumbnails (drawn: a "scene" changes colour every ~90 s)

    /// The mock has no "This Mac" device, so nothing ever reports.
    func localReport(_ report: LocalReport) async throws -> OKResponse { OKResponse(ok: true, error: nil) }

    func thumbs(path: String, make: Bool) async throws -> ThumbsInfo {
        let total = Int((Sim.duration / 10).rounded(.up))
        return ThumbsInfo(url: "mock://\(path)/", intervalS: 10, width: 480, height: 270,
                          count: total, total: total, done: true, failed: false,
                          palette: "mock://\(path)/palette.png")
    }

    /// One pixel per thumbnail in the scene's colour, like the backend's palette.
    func palette(_ info: ThumbsInfo) async throws -> NSImage {
        let n = info.count
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: 1, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for i in 0..<n {
            let t = Double(i) * info.intervalS
            let scene = Int(t / 90)
            let hue = (Double(scene) * 0.137 + Double(i % 3) * 0.01).truncatingRemainder(dividingBy: 1)
            let light = 0.45 + 0.2 * sin(Double(i) * 0.7)
            rep.setColor(NSColor(hue: hue, saturation: 0.6, brightness: light, alpha: 1), atX: i, y: 0)
        }
        let image = NSImage(size: NSSize(width: n, height: 1))
        image.addRepresentation(rep)
        return image
    }

    func thumbnail(_ info: ThumbsInfo, index: Int) async throws -> NSImage {
        let t = Double(index - 1) * info.intervalS
        let scene = Int(t / 90)
        let hue = (Double(scene) * 0.137).truncatingRemainder(dividingBy: 1)
        let size = NSSize(width: 480, height: 270)
        return NSImage(size: size, flipped: false) { rect in
            let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1)
            let bottom = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.18, alpha: 1)
            NSGradient(starting: bottom, ending: top)?.draw(in: rect, angle: 90)
            // A soft "light" that drifts within the scene, and a horizon.
            let f = (t.truncatingRemainder(dividingBy: 90)) / 90
            let light = NSRect(x: 60 + f * 300, y: 120 + sin(Double(scene)) * 40, width: 90, height: 90)
            NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 1, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: light).fill()
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: rect.width, height: 70 + Double(scene % 3) * 15)).fill()
            return true
        }
    }

    func devices(_ query: DeviceQuery) async throws -> DevicesResponse {
        switch query {
        case .refresh: try? await Task.sleep(nanoseconds: 2_000_000_000)
        case .probe: try? await Task.sleep(nanoseconds: 250_000_000)
        case .cached: break
        }
        if query != .cached {
            let now = Date().timeIntervalSince1970
            for i in devices.indices {
                devices[i].probedAt = now
                guard devices[i].status == "online" else { continue }
                let base = devices[i].id.hasSuffix("01") ? 3.0 : 7.5
                // While the simulated Wi-Fi dip is on, the TV in use answers slowly too.
                let dip = sim.map { degraded($0.e) && devices[i].id == $0.session.device?.id } ?? false
                devices[i].rttMs = dip ? 60 + 200 * rng.next() : base * (0.7 + 0.8 * rng.next())
                devices[i].lastSeen = now
            }
        }
        let sorted = devices.enumerated().sorted { a, b in
            let ra = a.element.reachability.rawValue, rb = b.element.reachability.rawValue
            if ra != rb { return ra < rb }
            return (a.element.rttMs ?? .infinity, a.offset) < (b.element.rttMs ?? .infinity, b.offset)
        }.map(\.element)
        return DevicesResponse(scanning: false, devices: sorted)
    }

    func pair(deviceID: String) async throws -> OKResponse {
        guard let d = devices.first(where: { $0.id == deviceID }) else { return OKResponse(ok: false, error: "Unknown device") }
        try? await Task.sleep(nanoseconds: 700_000_000)
        pairing = PairingState(deviceId: deviceID, awaitingPin: true, error: nil)
        log("info", "airplay", "Pairing with \(d.displayName): the TV now shows a PIN")
        return OKResponse(ok: true, error: nil)
    }

    func submitPin(_ pin: String) async throws -> OKResponse {
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard let p = pairing, let id = p.deviceId, let i = devices.firstIndex(where: { $0.id == id }) else {
            return OKResponse(ok: false, error: "No pairing in progress")
        }
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else {
            pairing?.error = "Wrong PIN, try again"
            log("warn", "airplay", "Pairing failed: wrong PIN")
            return OKResponse(ok: false, error: "Wrong PIN, try again")
        }
        devices[i].paired = true
        pairing = nil
        log("info", "airplay", "Paired with \(devices[i].displayName)")
        return OKResponse(ok: true, error: nil)
    }

    func play(_ r: PlayRequest) async throws -> OKResponse {
        guard let di = devices.firstIndex(where: { $0.id == r.deviceId }) else { return OKResponse(ok: false, error: "Unknown device") }
        let d = devices[di]
        if d.reachability == .offline { return OKResponse(ok: false, error: "\(d.displayName) is offline") }
        if d.needsPairing { return OKResponse(ok: false, error: "\(d.displayName) must be paired first") }
        if d.reachability == .notResponding {
            // Simulate a TV that does not wake up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            log("error", "airplay", "\(d.displayName) did not answer on its AirPlay port (asleep or blocked)")
            return OKResponse(ok: false, error: "\(d.displayName) is not responding. It may be asleep — wake it with the remote and try again.")
        }
        let probe = try await probe(path: r.path)
        if let s = sim, Phase(s.phase).isActive { stopSim(reason: "Replaced by a new session") }
        for i in devices.indices { devices[i].lastUsed = devices[i].id == d.id }

        let a = probe.audioTracks.first { $0.id == r.audio } ?? probe.audioTracks[0]
        let sub = probe.subtitleTracks.first { $0.id == r.subtitle }
        let burn = sub?.burnsIn ?? false
        let reencode = burn || probe.video?.mode == "reencode"
        let audioMode = (r.stereo || a.mode == "transcode") ? "transcode" : "copy"
        let now = Date().timeIntervalSince1970
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        let session = Session(
            id: id, startedAt: now,
            file: SessionFile(path: r.path, name: probe.name, sizeBytes: probe.sizeBytes, durationS: Sim.duration),
            video: SessionVideo(codec: probe.video?.codec, width: 1920, height: 1080,
                                mode: reencode ? "reencode" : "copy",
                                reason: burn ? "Burning in image subtitles" : probe.video?.reason,
                                outCodec: "h264"),
            audio: SessionAudio(id: a.id, label: a.label, codec: a.codec, channels: r.stereo ? 2 : a.channels, mode: audioMode,
                                outCodec: audioMode == "copy" ? a.codec : (r.stereo ? "aac" : "eac3")),
            subtitle: sub.map { SessionSubtitle(id: $0.id, label: $0.label, codec: $0.codec, mode: $0.mode) },
            stereo: r.stereo,
            device: SessionDevice(id: d.id, name: d.name, address: d.address, model: d.model),
            streamUrl: "http://192.168.1.10:53211/master.m3u8",
            streamBitrateBps: Sim.bitrate, segmentDurationS: Sim.segDur,
            segmentsReady: 0, segmentsTotal: Sim.segTotal)
        var newSim = Sim(session: session, request: r, reencode: reencode, softSubs: sub != nil && !burn, t0: now)
        if let start = r.startPosition, start > 0 {
            let seg = (min(start, Sim.duration - 6) / Sim.segDur).rounded(.down)
            newSim.position = seg * Sim.segDur
            newSim.loadedEnd = newSim.position
            newSim.prepared = newSim.position
            newSim.nextSeg = Int(seg)
        }
        sim = newSim
        lastWall = Date()
        simCarry = 0
        log("info", "app", "Session \(id): \(probe.displayName) → \(d.displayName)", at: now)
        log("info", "ffmpeg", reencode
            ? "ffmpeg started: re-encoding video to H.264 (\(burn ? "burning in PGS subtitles" : probe.video?.reason ?? "")), audio \(audioMode)"
            : "ffmpeg started: copying video (H.264), audio \(audioMode)", at: now + 0.2)
        return OKResponse(ok: true, error: nil)
    }

    func control(_ r: ControlRequest) async throws -> OKResponse {
        advance()
        guard var s = sim, Phase(s.phase).isActive else { return OKResponse(ok: false, error: "No active session") }
        let ts = s.t0 + Double(s.e)
        switch r.action {
        case "volume":
            log("info", "airplay", "TV volume \(r.step ?? "?") (simulated)", at: ts)
            return OKResponse(ok: true, error: nil)
        case "pause":
            s.paused = true
            if s.phase == "playing" { s.phase = "paused" }
            sim = s
            log("info", "airplay", "Paused at \(Fmt.clock(s.position))", at: ts)
        case "resume":
            s.paused = false
            if s.phase == "paused" { s.phase = "playing" }
            sim = s
            log("info", "airplay", "Resumed at \(Fmt.clock(s.position))", at: ts)
        case "stop":
            sim = s
            stopSim(reason: "Stopped by user")
        case "seek", "skip":
            let target = max(0, min(Sim.duration - 1, r.action == "skip" ? s.position + (r.seconds ?? 0) : (r.position ?? s.position)))
            // Like MediaRemote on a real TV: inside the buffered range the playhead moves in place.
            if target < s.loadedEnd - 1 {
                s.position = target
                sim = s
                log("info", "airplay", "\(r.action == "skip" ? String(format: "Skip %+.0f s", r.seconds ?? 0) : "Seek") to \(Fmt.clock(target)) (in place)", at: ts)
                return OKResponse(ok: true, error: nil)
            }
            if let dl = s.download {
                recordRequest(&s, segment: dl.segment, start: dl.start, end: ts, bytes: dl.bytes - dl.left, status: 200, error: "client aborted")
                s.clientAborts += 1
                s.download = nil
            }
            let segStart = (target / Sim.segDur).rounded(.down)
            s.position = segStart * Sim.segDur
            s.loadedEnd = s.position
            s.nextSeg = Int(segStart)
            s.phase = "buffering"
            s.wasSeek = true
            sim = s
            log("info", "airplay", "\(r.action == "skip" ? String(format: "Skip %+.0f s", r.seconds ?? 0) : "Seek") to \(Fmt.clock(target))", at: ts)
        default:
            return OKResponse(ok: false, error: "Unknown action \(r.action)")
        }
        return OKResponse(ok: true, error: nil)
    }

    func state(since: Int) async throws -> StateResponse {
        advance()
        var r = StateResponse(seq: seq, now: sim.map { $0.t0 + Double($0.e) } ?? Date().timeIntervalSince1970,
                              phase: sim?.phase ?? "idle", telemetryLevel: telemetryLevel, pairing: pairing)
        if let s = sim {
            var session = s.session
            session.segmentsReady = min(Sim.segTotal, Int(s.prepared / Sim.segDur))
            if s.tvReported {
                session.timing = SessionTiming(startS: 1.4, seekS: nil)
            }
            r.session = session
            r.prep = Prep(progress: s.prepared / Sim.duration, speed: s.ffDone ? s.lastSpeed : s.ffSpeed,
                          preparedS: s.prepared, done: s.ffDone, error: nil)
            if s.tvReported {
                r.playback = Playback(position: s.position, duration: Sim.duration, rate: s.phase == "playing" ? 1 : 0,
                                      bufferedAheadS: max(0, s.loadedEnd - s.position),
                                      bufferEmpty: s.phase == "stalled", bufferFull: s.loadedEnd - s.position >= Sim.target - 0.1,
                                      likelyToKeepUp: s.phase != "stalled" && s.recentRatio >= 1,
                                      readyToPlay: true, stallCount: s.stallCount, stalledSTotal: s.stalledTotal,
                                      lastReportAt: s.t0 + Double(s.e) - 0.4, error: nil)
            }
            let tx = s.txHist
            r.network = NetworkStats(txBpsNow: tx.last, txBpsAvg10: tx.isEmpty ? nil : tx.suffix(10).reduce(0, +) / Double(min(10, tx.count)),
                                     rttMs: s.rttHist.last ?? nil, rttMsAvg: s.rttAvg, rttLoss: s.rttLoss,
                                     httpErrors: s.httpErrors, clientAborts: s.clientAborts)
            r.diagnosis = s.diagnosis
        }
        if since <= 0 {
            r.samples = Array(samples.suffix(900))
            r.requests = Array(requests.suffix(400))
            r.events = Array(events.suffix(300))
        } else {
            r.samples = samples.filter { $0.seq > since }
            r.requests = requests.filter { $0.seq > since }
            r.events = events.filter { $0.seq > since }
        }
        return r
    }

    func ocrStatus(path: String, subtitle: Int) async throws -> OCRStatus {
        OCRStatus(status: "not_needed", progress: 1, error: nil)
    }

    func setTelemetry(level: String) async throws -> OKResponse {
        guard level == "basic" || level == "detailed" else { return OKResponse(ok: false, error: "Unknown level \(level)") }
        if level != telemetryLevel { log("info", "app", "Telemetry level: \(level) (latency probe every \(level == "detailed" ? "1" : "5") s)") }
        telemetryLevel = level
        return OKResponse(ok: true, error: nil)
    }

    // MARK: - Simulation

    private func nextSeq() -> Int { seq += 1; return seq }

    private func log(_ level: String, _ source: String, _ message: String, at t: Double? = nil) {
        events.append(Event(seq: nextSeq(), t: t ?? Date().timeIntervalSince1970, level: level, source: source, message: message))
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
    }

    private func stopSim(reason: String) {
        guard var s = sim else { return }
        s.phase = "stopped"
        s.download = nil
        sim = s
        saveHistory(s)
        log("info", "app", reason, at: s.t0 + Double(s.e))
    }

    private func advance() {
        guard sim != nil else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastWall ?? now)
        lastWall = now
        simCarry += dt * speed
        var steps = 0
        while simCarry >= 1, steps < 600 {
            simCarry -= 1
            steps += 1
            tick()
        }
    }

    /// Network capacity towards the TV at sim second e (bits/s).
    private func capacity(_ e: Int) -> Double {
        let jitter = 0.85 + 0.3 * rng.next()
        switch e {
        case ..<60: return 85e6 * jitter
        case 60..<64: return (85e6 - Double(e - 59) * 20e6) * jitter
        case 64..<102: return (3e6 + 3e6 * rng.next())
        case 102..<108: return (6e6 + Double(e - 101) * 12e6) * jitter
        default: return 80e6 * jitter
        }
    }

    private func degraded(_ e: Int) -> Bool { (61..<104).contains(e) }

    private func tick() {
        guard var s = sim else { return }
        let phase = Phase(s.phase)
        if !phase.isActive { sim = s; return }
        s.e += 1
        let e = s.e
        let ts = s.t0 + Double(e)

        if let failAt, e >= failAt {
            // Mirrors the backend: phase failed, raw message in session.error,
            // diagnosis details[0] = "Error: <message>".
            let msg = "AirPlay play request failed: Apple TV answered HTTP 500 on /play (\"MediaPlayer error -12938\")"
            s.phase = "failed"
            s.download = nil
            s.session.error = msg
            s.diagnosis = Diagnosis(status: "failed", headline: "Playback failed", details: ["Error: " + msg],
                                    suspects: s.diagnosis?.suspects?.map { Suspect(cause: $0.cause, confidence: 0, evidence: $0.evidence) })
            log("error", "airplay", msg, at: ts)
            saveHistory(s)
            sim = s
            return
        }

        // 1. Preparation (ffmpeg)
        if !s.ffDone && e >= 1 {
            let sp = s.reencode ? (1.25 + 0.3 * rng.next()) : (360 + 50 * rng.next())
            s.ffSpeed = sp
            s.lastSpeed = sp
            s.prepared = min(Sim.duration, s.prepared + sp)
            if s.prepared >= Sim.duration {
                s.ffDone = true
                s.ffSpeed = nil
                log("info", "ffmpeg", "Preparation finished: \(Int(Sim.duration)) s of media ready after \(e) s (\(Fmt.speed(sp)))", at: ts)
            }
        }

        // 2. Phase progression at the start
        if s.phase == "preparing" && e >= 2 {
            s.phase = "connecting"
            log("info", "airplay", "Connecting to \(s.session.device?.name ?? "Apple TV") (\(s.session.device?.address ?? ""))", at: ts)
        } else if s.phase == "connecting" && e >= 4 {
            s.phase = "buffering"
            s.tvReported = true
            log("info", "airplay", "AirPlay session established, Apple TV is loading the stream", at: ts)
            for (i, kind) in ["master", "playlist", "playlist", "init"].enumerated() {
                let path = ["/master.m3u8", "/video.m3u8", "/audio.m3u8", "/init_0.mp4"][i]
                requests.append(RequestRecord(seq: nextSeq(), t: ts + 0.05 * Double(i), path: path, kind: kind, segment: nil,
                                              status: 200, bytes: kind == "init" ? 1240 : 2900, durationMs: 1.2, mbps: 19,
                                              realtimeRatio: nil, client: s.session.device?.address, error: nil))
            }
            if s.softSubs {
                requests.append(RequestRecord(seq: nextSeq(), t: ts + 0.3, path: "/subs.m3u8", kind: "playlist", segment: nil,
                                              status: 200, bytes: 18_000, durationMs: 2.0, mbps: 72, realtimeRatio: nil,
                                              client: s.session.device?.address, error: nil))
            }
        }

        // 3. RTT probe: every second at "detailed", every 5 s at "basic".
        var rtt: Double?
        let probed = telemetryLevel == "detailed" || e % 5 == 0
        var timedOut = false
        if probed {
            if degraded(e) {
                rtt = rng.next() < (telemetryLevel == "detailed" ? 0.22 : 0.4) ? nil : 40 + 280 * rng.next()
            } else {
                rtt = 2.5 + 4.5 * rng.next()
            }
            timedOut = rtt == nil
            s.rttHist.append(rtt)
            if s.rttHist.count > 30 { s.rttHist.removeFirst() }
        }
        if timedOut {
            log("warn", "network", "RTT probe to the Apple TV timed out (no answer within 1 s)", at: ts + 0.5)
        } else if let r = rtt, r > 120, !s.warnedRTT {
            s.warnedRTT = true
            log("warn", "network", String(format: "RTT to the Apple TV rose to %.0f ms (normally ~5 ms)", r), at: ts + 0.5)
        }

        // 4. HLS delivery for this second
        var tx = 0.0
        var nRequests = 0
        if s.tvReported {
            let cap = capacity(e)
            var budget = cap
            var guardLoops = 0
            while budget > 1, guardLoops < 40 {
                guardLoops += 1
                if s.download == nil {
                    let ahead = s.loadedEnd - s.position
                    guard ahead < Sim.target, s.nextSeg < Sim.segTotal else { break }
                    let available = s.ffDone || Double(s.nextSeg + 1) * Sim.segDur <= s.prepared
                    if !available {
                        if e % 3 == 0 {
                            recordRequest(&s, segment: s.nextSeg, start: ts, end: ts + 0.002, bytes: 0, status: 404, error: "not ready (404)")
                            nRequests += 1
                        }
                        break
                    }
                    let used = 1 - budget / cap
                    let bytes = Sim.segDur * Sim.bitrate / 8 * (0.8 + 0.4 * rng.next())
                    s.download = Download(segment: s.nextSeg, bytes: bytes, left: bytes, start: ts + used + (rtt ?? 5) / 1000)
                }
                guard var dl = s.download else { break }
                let bits = min(budget, dl.left * 8)
                dl.left -= bits / 8
                budget -= bits
                tx += bits
                if dl.left <= 0.5 {
                    let end = max(dl.start + 0.01, ts + (1 - budget / cap))
                    recordRequest(&s, segment: dl.segment, start: dl.start, end: end, bytes: dl.bytes, status: 200, error: nil)
                    nRequests += 1
                    s.loadedEnd += Sim.segDur
                    s.nextSeg += 1
                    s.download = nil
                    if s.softSubs && dl.segment % 5 == 0 {
                        requests.append(RequestRecord(seq: nextSeq(), t: end, path: String(format: "/sub_%05d.vtt", dl.segment / 5),
                                                      kind: "subtitle", segment: dl.segment / 5, status: 200, bytes: 2400,
                                                      durationMs: 1.5, mbps: 12.8, realtimeRatio: nil,
                                                      client: s.session.device?.address, error: nil))
                    }
                } else {
                    s.download = dl
                }
            }
            // The TV gives up on a download that takes far too long and retries.
            if let dl = s.download, ts + 1 - dl.start > 14 {
                recordRequest(&s, segment: dl.segment, start: dl.start, end: ts + 1, bytes: dl.bytes - dl.left, status: 200, error: "client aborted")
                nRequests += 1
                s.clientAborts += 1
                log("warn", "http", "Apple TV aborted segment \(dl.segment) after 14 s and retried", at: ts + 1)
                s.download = Download(segment: dl.segment, bytes: dl.bytes, left: dl.bytes, start: ts + 1)
            }
        }
        s.txHist.append(tx)
        if s.txHist.count > 30 { s.txHist.removeFirst() }

        // 5. Playback on the TV
        let ahead = s.loadedEnd - s.position
        switch s.phase {
        case "buffering":
            if ahead >= 12 {
                s.phase = s.paused ? "paused" : "playing"
                log("info", "airplay", s.wasSeek ? "Playback continued at \(Fmt.clock(s.position))" : "Apple TV started playback", at: ts)
                s.wasSeek = false
            }
        case "playing":
            if ahead <= 0.01 {
                s.phase = "stalled"
                s.stallCount += 1
                s.stallStart = ts
                s.lastStallAt = ts
                log("error", "airplay", "Apple TV buffer empty - playback stalled", at: ts)
            } else {
                s.position = min(Sim.duration, s.position + min(1, ahead))
                if s.position >= Sim.duration {
                    s.phase = "finished"
                    saveHistory(s)
                    log("info", "airplay", "Playback finished", at: ts)
                }
            }
        case "stalled":
            s.stalledTotal += 1
            if ahead >= 8 {
                s.phase = s.paused ? "paused" : "playing"
                s.lastStallLength = ts - s.stallStart
                log("info", "airplay", String(format: "Playback resumed after a %.0f s stall", s.lastStallLength), at: ts)
            }
        default: break
        }

        if e % 10 == 0 { saveHistory(s) }

        // 6. Sample
        let tvPos: Double? = s.tvReported ? s.position : nil
        samples.append(Sample(seq: nextSeq(), t: ts, txBps: tx, requests: nRequests,
                              ffSpeed: s.ffDone ? nil : s.ffSpeed, ffPreparedS: s.prepared,
                              tvPosition: tvPos, tvBufferedAheadS: s.tvReported ? max(0, s.loadedEnd - s.position) : nil,
                              tvRate: s.tvReported ? (s.phase == "playing" ? 1 : 0) : nil,
                              tvBufferEmpty: s.tvReported ? s.phase == "stalled" : nil,
                              headroomS: tvPos.map { s.prepared - $0 }, rttMs: rtt,
                              rttTimeout: probed ? timedOut : nil, rttExplicitNull: timedOut))
        if samples.count > 5000 { samples.removeFirst(samples.count - 5000) }
        if requests.count > 3000 { requests.removeFirst(requests.count - 3000) }

        s.diagnosis = diagnose(s, ts: ts)
        sim = s
    }

    private func recordRequest(_ s: inout Sim, segment: Int, start: Double, end: Double, bytes: Double, status: Int, error: String?) {
        let dur = max(0.001, end - start)
        let ratio: Double? = status == 200 && error == nil ? Sim.segDur / dur : nil
        requests.append(RequestRecord(seq: nextSeq(), t: start, path: String(format: "/seg_0_%05d.m4s", segment), kind: "segment",
                                      segment: segment, status: status, bytes: bytes, durationMs: dur * 1000,
                                      mbps: bytes * 8 / dur / 1e6, realtimeRatio: ratio,
                                      client: s.session.device?.address, error: error))
        if status >= 400 { s.httpErrors += 1 }
        if let ratio {
            s.segRatios.append(ratio)
            s.segMbps.append(bytes * 8 / dur / 1e6)
            if s.segRatios.count > 10 { s.segRatios.removeFirst(); s.segMbps.removeFirst() }
            if ratio < 1 {
                s.hadSlow = true
                log("warn", "http", String(format: "Segment %d took %.1f s to send for %.0f s of video (%.1f× realtime)", segment, dur, Sim.segDur, ratio), at: end)
            } else if s.hadSlow && ratio > 3 {
                s.hadSlow = false
                s.warnedRTT = false
                log("info", "network", String(format: "Throughput recovered: segment %d sent at %.0f Mbit/s", segment, bytes * 8 / dur / 1e6), at: end)
            }
        }
    }

    private func diagnose(_ s: Sim, ts: Double) -> Diagnosis {
        let ahead = max(0, s.loadedEnd - s.position)
        var ratio = s.recentRatio
        var mbps = s.recentMbps
        if let dl = s.download, ts + 1 - dl.start > Sim.segDur {
            // An in-flight download that is already slower than realtime counts too.
            let el = ts + 1 - dl.start
            ratio = min(ratio, Sim.segDur / el)
            mbps = min(mbps, (dl.bytes - dl.left) * 8 / el / 1e6)
        }
        let need = Sim.bitrate / 1e6
        let rttAvg = s.rttAvg ?? 0
        let loss = s.rttLoss
        let headroom = s.prepared - s.position

        var netConf = 0.05
        var netEvidence = String(format: "Segments arrive at %.0f Mbit/s (%.0f× realtime); RTT %.0f ms", mbps, ratio, rttAvg)
        if ratio < 1 {
            netConf = s.phase == "stalled" ? 0.92 : 0.82
            netEvidence = String(format: "Recent segments arrived at %.1f Mbit/s = %.1f× realtime (needs ≥ 1×); RTT %.0f ms, %.0f%% probes lost", mbps, ratio, rttAvg, loss * 100)
        } else if ratio < 1.5 || rttAvg > 60 {
            netConf = 0.5
            netEvidence = String(format: "Segments at %.1f× realtime, RTT %.0f ms (normally ~5 ms)", ratio, rttAvg)
        }
        var encConf = 0.0
        var encEvidence = "Stream fully prepared (\(Int(Sim.duration)) s at \(Fmt.speed(s.lastSpeed)))"
        if !s.ffDone {
            if headroom < 12 && (s.ffSpeed ?? 0) < 1 { encConf = 0.8 } else { encConf = s.reencode ? 0.12 : 0.05 }
            encEvidence = String(format: "ffmpeg at %@ realtime, %.0f s ahead of the TV", Fmt.speed(s.ffSpeed), headroom)
        }
        let suspects = [
            Suspect(cause: "network", confidence: netConf, evidence: netEvidence),
            Suspect(cause: "encoder", confidence: encConf, evidence: encEvidence),
            Suspect(cause: "device", confidence: s.phase == "stalled" ? 0.08 : 0.02,
                    evidence: "Apple TV reports no player error\(s.phase == "stalled" ? "; it is waiting for data" : "")"),
            Suspect(cause: "server", confidence: s.httpErrors > 0 && s.reencode ? 0.1 : 0.03,
                    evidence: s.httpErrors > 0 ? "\(s.httpErrors) segment requests arrived before the segment was ready (404)" : "All requests answered 200 OK, time to first byte < 5 ms"),
            Suspect(cause: "source", confidence: 0.0, evidence: "File read without errors"),
        ].sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }

        func line(_ f: String, _ a: CVarArg...) -> String { String(format: f, arguments: a) }
        let deliveryLine = line("Segments arrive at %.1f Mbit/s (%.1f× realtime); the stream needs %.1f Mbit/s", mbps, ratio, need)
        let bufferLine = line("Apple TV buffer: %.0f s of video ahead", ahead)

        switch s.phase {
        case "preparing", "connecting":
            return Diagnosis(status: "ok", headline: "Starting stream…", details: ["Preparing the HLS stream and connecting to the Apple TV"], suspects: suspects)
        case "buffering" where s.stallCount == 0:
            return Diagnosis(status: "ok", headline: "Apple TV is buffering", details: [bufferLine], suspects: suspects)
        case "stalled":
            return Diagnosis(status: "failing", headline: "Playback stalled: the Apple TV ran out of video",
                             details: [deliveryLine, line("RTT %.0f ms average, %.0f%% of probes timed out — Wi-Fi between Mac and TV is struggling", rttAvg, loss * 100),
                                       "Encoder is not the cause: the whole file is already prepared"],
                             suspects: suspects)
        default: break
        }
        if ratio < 1 && ahead < 15 {
            return Diagnosis(status: "failing", headline: "TV buffer is draining — the network can't keep up",
                             details: [deliveryLine, bufferLine + line(" and falling about %.1f s per second", max(0.1, 1 - ratio))],
                             suspects: suspects)
        }
        if ratio < 1.5 || rttAvg > 60 {
            return Diagnosis(status: "warning",
                             headline: ratio < 1 ? "Wi-Fi throughput dropped below what the stream needs" : "Network to the Apple TV is slower than usual",
                             details: [deliveryLine, bufferLine, line("RTT %.0f ms average (normally ~5 ms)", rttAvg)],
                             suspects: suspects)
        }
        if let st = s.lastStallAt, ts - st < 90 {
            return Diagnosis(status: "warning", headline: "Recovered from a stall",
                             details: [line("Stalled %.0f s at %@ because segments arrived slower than realtime", s.lastStallLength, Fmt.time(st)),
                                       deliveryLine, bufferLine],
                             suspects: suspects)
        }
        var details = [deliveryLine, bufferLine]
        if s.stallCount > 0 { details.append(line("%d stall(s) earlier this session, %.0f s total", s.stallCount, s.stalledTotal)) }
        return Diagnosis(status: "ok", headline: s.phase == "paused" ? "Paused — stream healthy" : "Streaming smoothly", details: details, suspects: suspects)
    }
}

// MARK: - Simulation state

private struct Download {
    var segment: Int
    var bytes: Double
    var left: Double
    var start: Double
}

private struct Sim {
    static let duration = 2700.0           // 45 min
    static let bitrate = 10_250_000.0
    static let segDur = 6.0
    static let segTotal = 450
    static let target = 24.0               // seconds the TV keeps buffered ahead

    var session: Session
    var request: PlayRequest
    var reencode: Bool
    var softSubs: Bool
    var t0: Double
    var e = 0
    var phase = "preparing"
    var prepared = 0.0
    var ffSpeed: Double?
    var lastSpeed: Double?
    var ffDone = false
    var tvReported = false
    var position = 0.0
    var loadedEnd = 0.0
    var nextSeg = 0
    var download: Download?
    var paused = false
    var wasSeek = false
    var stallCount = 0
    var stalledTotal = 0.0
    var stallStart = 0.0
    var lastStallAt: Double?
    var lastStallLength = 0.0
    var txHist: [Double] = []
    var rttHist: [Double?] = []
    var httpErrors = 0
    var clientAborts = 0
    var segRatios: [Double] = []
    var segMbps: [Double] = []
    var hadSlow = false
    var warnedRTT = false
    var diagnosis: Diagnosis?

    init(session: Session, request: PlayRequest, reencode: Bool, softSubs: Bool, t0: Double) {
        self.session = session
        self.request = request
        self.reencode = reencode
        self.softSubs = softSubs
        self.t0 = t0
    }

    var recentRatio: Double {
        let r = segRatios.suffix(3).sorted()
        return r.isEmpty ? 10 : r[r.count / 2]
    }

    var recentMbps: Double {
        let r = segMbps.suffix(3).sorted()
        return r.isEmpty ? 0 : r[r.count / 2]
    }

    var rttAvg: Double? {
        let v = rttHist.suffix(10).compactMap { $0 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    var rttLoss: Double {
        let w = rttHist.suffix(10)
        return w.isEmpty ? 0 : Double(w.filter { $0 == nil }.count) / Double(w.count)
    }
}

private struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}
