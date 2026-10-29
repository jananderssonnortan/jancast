import Foundation

// Codable mirror of docs/API.md. Everything that could plausibly be missing is
// optional, measurements are Double (JSON ints decode fine into Double), and
// enum-like fields (phase, status, cause, level, kind) stay plain strings that
// are interpreted leniently in Support/Semantics.swift, so an unknown value
// from a newer backend never breaks decoding.

// MARK: - Generic responses

struct OKResponse: Decodable {
    var ok: Bool?
    var error: String?
}

struct HealthResponse: Decodable {
    var ok: Bool?
    var version: String?
}

struct ReadyLine: Decodable {
    var port: Int
}

// MARK: - Probe

struct ProbeResult: Decodable, Equatable {
    var path: String
    var name: String?
    var sizeBytes: Double?
    var downloading: Bool?          // "movie.mkv.part": a download in progress
    var durationS: Double?
    var video: ProbeVideo?
    var audio: [AudioTrack]?
    var subtitles: [SubtitleTrack]?
    var defaultAudio: Int?
    var defaultSubtitle: Int?
    var resume: HistoryEntry?
    var next: NextEpisode?          // next episode in the same folder
    var nameInfo: NameInfo? = nil

    var displayName: String { name ?? (path as NSString).lastPathComponent }
    var audioTracks: [AudioTrack] { audio ?? [] }
    var subtitleTracks: [SubtitleTrack] { subtitles ?? [] }
}

struct ProbeVideo: Decodable, Equatable {
    var codec: String?
    var width: Int?
    var height: Int?
    var hdr: Bool?
    var mode: String?      // "copy" | "reencode"
    var reason: String?
}

struct AudioTrack: Codable, Identifiable, Hashable {
    var id: Int
    var label: String?
    var lang: String?
    var title: String?
    var codec: String?
    var channels: Int?
    var isDefault: Bool?
    var forced: Bool?
    var mode: String?      // "copy" | "transcode"

    enum CodingKeys: String, CodingKey {
        case id, label, lang, title, codec, channels, forced, mode
        case isDefault = "default"
    }
}

struct SubtitleTrack: Codable, Identifiable, Hashable {
    var id: Int
    var label: String?
    var lang: String?
    var title: String?
    var codec: String?
    var isDefault: Bool?
    var forced: Bool?
    var external: Bool?
    var mode: String?      // "soft" | "ocr" (picture subtitles shown as text) | "burn"

    enum CodingKeys: String, CodingKey {
        case id, label, lang, title, codec, forced, external, mode
        case isDefault = "default"
    }

    var burnsIn: Bool { mode == "burn" }
    var viaOCR: Bool { mode == "ocr" }
}

struct NextEpisode: Decodable, Equatable {
    var path: String
    var name: String?
    var season: Int?
    var episode: Int?
    var nameInfo: NameInfo? = nil

    var displayName: String { name ?? (path as NSString).lastPathComponent }
}

/// What a file is, read from its name by the backend (`name_info`): a show's
/// season and episode, or a film's title and year. Shown via `Fmt.name`.
struct NameInfo: Decodable, Equatable, Hashable {
    var title: String?            // one line: "Night Train S6 · E3", "Quiet Hours (2025)"
    var show: String?
    var season: Int?
    var episode: Int?
    var episodeEnd: Int?          // multi-episode file: S01E02E03 → 3
    var episodeTitle: String?     // "'90 - Autumn", or a daily show's air date
    var year: Int?
    var kind: String?             // "episode" | "movie"
}

/// GET /api/thumbs: preview thumbnails, one every `intervalS` seconds.
struct ThumbsInfo: Decodable, Equatable {
    var url: String               // "/api/thumbs/<key>/", thumbnail n is "<url><n>.jpg"
    var intervalS: Double
    var width: Double?
    var height: Double?
    var count: Int                // 1…count are ready
    var total: Int?
    var done: Bool?
    var failed: Bool?
    var palette: String? = nil    // "<url>palette.png" once made: one colour per thumbnail

    var aspect: Double { (width ?? 16) / max(1, height ?? 9) }
}

// MARK: - Resume / history

struct RecentResponse: Decodable {
    var items: [HistoryEntry]?
}

struct HistoryEntry: Decodable, Identifiable, Equatable {
    var path: String
    var name: String?
    var sizeBytes: Double?
    var mtime: Double?
    var position: Double?
    var duration: Double?
    var watched: Bool?
    var resumePosition: Double?     // null = nothing worth resuming
    var audio: Int?
    var subtitle: Int?
    var deviceId: String?
    var stereo: Bool?
    var updatedAt: Double?
    var subtitleDelay: Double? = nil
    var nameInfo: NameInfo? = nil

    var id: String { path }
    var displayName: String { name ?? (path as NSString).lastPathComponent }
    var progress: Double? {
        guard let p = position, let d = duration, d > 0 else { return nil }
        return min(1, max(0, p / d))
    }
}

// MARK: - Devices & pairing

struct DevicesResponse: Decodable {
    var scanning: Bool?
    var devices: [Device]?
}

struct Device: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var address: String?
    var model: String?
    var paired: Bool?
    var pairingRequired: Bool?
    var lastUsed: Bool?
    var status: String?        // online | not_responding | offline
    var reachable: Bool?
    var rttMs: Double?
    var lastSeen: Double?
    var probedAt: Double?

    var displayName: String { name ?? id }
    var needsPairing: Bool { (pairingRequired ?? false) && !(paired ?? false) }
    var reachability: DeviceReachability {
        switch status?.lowercased() {
        case "online": return .online
        case "not_responding": return .notResponding
        case "offline": return .offline
        default: return reachable == false ? .notResponding : .online
        }
    }
}

enum DeviceReachability: Int {
    case online = 0, notResponding = 1, offline = 2
}

enum DeviceQuery {
    case cached      // GET /api/devices
    case probe       // GET /api/devices?probe=1  (fast reachability re-probe)
    case refresh     // GET /api/devices?refresh=1 (full Bonjour scan)
}

struct PairingState: Decodable, Equatable {
    var deviceId: String?
    var awaitingPin: Bool?
    var error: String?
}

// MARK: - Requests (app -> backend)

struct PairRequest: Encodable { var deviceId: String }
struct PinRequest: Encodable { var pin: String }
struct TelemetryRequest: Encodable { var level: String }   // "basic" | "detailed"

struct PlayRequest: Encodable {
    var path: String
    var audio: Int
    var subtitle: Int
    var deviceId: String
    var stereo: Bool
    var startPosition: Double?   // omitted when nil
    var subtitleDelay: Double? = nil   // seconds, + = later
}

struct ControlRequest: Encodable {
    var action: String     // pause | resume | stop | seek | skip | volume
    var position: Double?  // seek: absolute seconds
    var seconds: Double?   // skip: relative seconds, negative = back
    var step: String?      // volume: "up" | "down"
}

// MARK: - Live state

struct StateResponse {
    var seq: Int
    var now: Double?
    var phase: String?
    var telemetryLevel: String?
    var pairing: PairingState?
    var session: Session?
    var prep: Prep?
    var playback: Playback?
    var network: NetworkStats?
    var diagnosis: Diagnosis?
    var localPlayer: LocalPlayerState?      // set while a session plays to "This Mac"
    var samples: [Sample] = []
    var requests: [RequestRecord] = []
    var events: [Event] = []
}

extension StateResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case seq, now, phase, telemetryLevel, pairing, session, prep, playback, network, diagnosis, localPlayer, samples, requests, events
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        now = try? c.decodeIfPresent(Double.self, forKey: .now)
        phase = try? c.decodeIfPresent(String.self, forKey: .phase)
        telemetryLevel = try? c.decodeIfPresent(String.self, forKey: .telemetryLevel)
        pairing = try? c.decodeIfPresent(PairingState.self, forKey: .pairing)
        session = try? c.decodeIfPresent(Session.self, forKey: .session)
        prep = try? c.decodeIfPresent(Prep.self, forKey: .prep)
        playback = try? c.decodeIfPresent(Playback.self, forKey: .playback)
        network = try? c.decodeIfPresent(NetworkStats.self, forKey: .network)
        diagnosis = try? c.decodeIfPresent(Diagnosis.self, forKey: .diagnosis)
        localPlayer = try? c.decodeIfPresent(LocalPlayerState.self, forKey: .localPlayer)
        samples = (try? c.decodeIfPresent(LossyArray<Sample>.self, forKey: .samples))?.items ?? []
        requests = (try? c.decodeIfPresent(LossyArray<RequestRecord>.self, forKey: .requests))?.items ?? []
        events = (try? c.decodeIfPresent(LossyArray<Event>.self, forKey: .events))?.items ?? []
    }
}

/// "This Mac": what the app's player window should play (docs/API.md).
struct LocalPlayerState: Decodable, Equatable {
    var url: String
    var startPosition: Double?
    var active: Bool?
    var commands: [LocalCommand]?
}

struct LocalCommand: Decodable, Equatable {
    var id: Int
    var action: String          // pause | resume | seek | stop
    var position: Double?
}

/// POST /api/local/report: what the player window's AVPlayer sees.
struct LocalReport: Encodable {
    var position: Double?
    var duration: Double?
    var rate: Double
    var readyToPlay: Bool
    var bufferEmpty: Bool
    var bufferFull: Bool
    var likelyToKeepUp: Bool
    var loadedRanges: [LoadedRange]
    var ack: Int?
    var ended = false
    var closed = false
    var error: String?

    struct LoadedRange: Encodable {
        var start: Double
        var duration: Double
    }
}

struct Session: Decodable, Equatable {
    var id: String
    var startedAt: Double?
    var file: SessionFile?
    var video: SessionVideo?
    var audio: SessionAudio?
    var subtitle: SessionSubtitle?
    var stereo: Bool?
    var device: SessionDevice?
    var streamUrl: String?
    var streamBitrateBps: Double?
    var segmentDurationS: Double?
    var segmentsReady: Int?
    var segmentsTotal: Int?
    var startPosition: Double?
    var lastSeekAt: Double?
    var volume: SessionVolume?
    var timing: SessionTiming?
    var error: String?          // raw failure message when phase is "failed"
}

/// Time to picture: Play → TV playing, and the last jump → playing again.
struct SessionTiming: Decodable, Equatable {
    var startS: Double?
    var seekS: Double?
}

/// Can the TV's volume be changed through the Apple TV (HDMI-CEC / IR).
struct SessionVolume: Decodable, Equatable {
    var supported: Bool?
    var level: Double?
}

struct SessionFile: Decodable, Equatable {
    var path: String?
    var name: String?
    var sizeBytes: Double?
    var durationS: Double?
    var nameInfo: NameInfo? = nil
}

struct SessionVideo: Decodable, Equatable {
    var codec: String?
    var width: Int?
    var height: Int?
    var mode: String?
    var reason: String?
    var outCodec: String?
}

struct SessionAudio: Decodable, Equatable {
    var id: Int?
    var label: String?
    var codec: String?
    var channels: Int?
    var mode: String?
    var outCodec: String?
}

struct SessionSubtitle: Decodable, Equatable {
    var id: Int?
    var label: String?
    var codec: String?
    var mode: String?
    var delay: Double?
    var inStream: Bool?     // false: preparing them failed, playing without
    var text: String?       // read as text: "fast" | "accurate" recognition
}

/// GET /api/ocr: text recognition of a picture subtitle track.
struct OCRStatus: Decodable, Equatable {
    var status: String        // ready | working | failed | unavailable | not_needed
    var progress: Double?
    var error: String?
}

struct SessionDevice: Decodable, Equatable {
    var id: String?
    var name: String?
    var address: String?
    var model: String?
}

struct Prep: Decodable, Equatable {
    var progress: Double?
    var speed: Double?
    var preparedS: Double?
    var done: Bool?
    var onDemand: Bool?     // fast start: segments made on request, never "the rest"
    var stage: String?      // "video" | "subtitles" (reading picture subtitles as text)
    var fastStart: FastStartStats?
    var error: String?
}

/// Fast start: how often the TV had to wait for a segment to be made.
struct FastStartStats: Decodable, Equatable {
    var segmentRequests: Int?
    var waited: Int?
    var restarts: Int?
    var waitLastMs: Double?
    var waitMedianMs: Double?
    var waitMaxMs: Double?
}

struct Playback: Decodable, Equatable {
    var position: Double?
    var duration: Double?
    var rate: Double?
    var bufferedAheadS: Double?
    var bufferEmpty: Bool?
    var bufferFull: Bool?
    var likelyToKeepUp: Bool?
    var readyToPlay: Bool?
    var stallCount: Int?
    var stalledSTotal: Double?
    var lastReportAt: Double?
    var error: String?          // player error reported by the Apple TV
}

struct NetworkStats: Decodable, Equatable {
    var txBpsNow: Double?
    var txBpsAvg10: Double?
    var rttMs: Double?
    var rttMsAvg: Double?
    var rttLoss: Double?
    var httpErrors: Int?
    var clientAborts: Int?
}

struct Diagnosis: Decodable, Equatable {
    var status: String?
    var headline: String?
    var details: [String]?
    var suspects: [Suspect]?
}

struct Suspect: Decodable, Equatable, Hashable {
    var cause: String
    var confidence: Double?
    var evidence: String?
}

struct Sample: Equatable {
    var seq: Int
    var t: Double
    var txBps: Double?
    var requests: Int?
    var ffSpeed: Double?
    var ffPreparedS: Double?
    var tvPosition: Double?
    var tvBufferedAheadS: Double?
    var tvRate: Double?
    var tvBufferEmpty: Bool?
    var headroomS: Double?
    var rttMs: Double?
    /// Proposed contract addition: explicit timeout flag. When absent, a
    /// timeout is inferred from an explicit `"rtt_ms": null` plus a network event.
    var rttTimeout: Bool?
    /// `rtt_ms` key was present and null (vs. absent = not probed this second).
    var rttExplicitNull = false
}

extension Sample: Decodable {
    enum CodingKeys: String, CodingKey {
        case seq, t, txBps, requests, ffSpeed, ffPreparedS, tvPosition, tvBufferedAheadS, tvRate, tvBufferEmpty, headroomS, rttMs, rttTimeout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        t = try c.decode(Double.self, forKey: .t)
        txBps = try? c.decodeIfPresent(Double.self, forKey: .txBps)
        requests = try? c.decodeIfPresent(Int.self, forKey: .requests)
        ffSpeed = try? c.decodeIfPresent(Double.self, forKey: .ffSpeed)
        ffPreparedS = try? c.decodeIfPresent(Double.self, forKey: .ffPreparedS)
        tvPosition = try? c.decodeIfPresent(Double.self, forKey: .tvPosition)
        tvBufferedAheadS = try? c.decodeIfPresent(Double.self, forKey: .tvBufferedAheadS)
        tvRate = try? c.decodeIfPresent(Double.self, forKey: .tvRate)
        tvBufferEmpty = try? c.decodeIfPresent(Bool.self, forKey: .tvBufferEmpty)
        headroomS = try? c.decodeIfPresent(Double.self, forKey: .headroomS)
        rttMs = try? c.decodeIfPresent(Double.self, forKey: .rttMs)
        rttTimeout = try? c.decodeIfPresent(Bool.self, forKey: .rttTimeout)
        rttExplicitNull = c.contains(.rttMs) && ((try? c.decodeNil(forKey: .rttMs)) ?? false)
    }
}

struct RequestRecord: Decodable, Equatable, Identifiable {
    var seq: Int
    var t: Double
    var path: String?
    var kind: String?
    var segment: Int?
    var status: Int?
    var bytes: Double?
    var durationMs: Double?
    var mbps: Double?
    var realtimeRatio: Double?
    var client: String?
    var error: String?

    var id: Int { seq }
}

struct Event: Decodable, Equatable, Identifiable {
    var seq: Int
    var t: Double
    var level: String?
    var source: String?
    var message: String?

    var id: Int { seq }
}

// MARK: - Helpers

/// Decodes an array, silently skipping elements that fail to decode.
struct LossyArray<T: Decodable>: Decodable {
    var items: [T]

    /// Accepts any JSON value so the container always advances.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) {
                out.append(v)
            } else {
                _ = try? c.decode(Skip.self)
            }
        }
        items = out
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
