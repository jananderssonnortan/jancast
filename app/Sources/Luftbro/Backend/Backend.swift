import AppKit

/// The app talks to either the real Python backend (LiveBackend) or an
/// in-process simulation (MockBackend) through this single interface.
@MainActor
protocol Backend: AnyObject {
    var isMock: Bool { get }

    /// Spawn / connect. Throws BackendError.launch with a readable message.
    func start() async throws
    /// Called on app termination (must be synchronous).
    func shutdown()
    /// The same before a restart, without holding the main thread.
    func stop() async
    /// Invoked if the backend dies after a successful start (message, log tail).
    var onUnexpectedExit: ((String, String) -> Void)? { get set }

    func probe(path: String) async throws -> ProbeResult
    /// A probe that doesn't list the file in Recents (`remember=0`).
    func peek(path: String) async throws -> ProbeResult
    func recent(limit: Int) async throws -> RecentResponse
    func devices(_ query: DeviceQuery) async throws -> DevicesResponse
    func pair(deviceID: String) async throws -> OKResponse
    func submitPin(_ pin: String) async throws -> OKResponse
    func play(_ request: PlayRequest) async throws -> OKResponse
    func control(_ request: ControlRequest) async throws -> OKResponse
    func state(since: Int) async throws -> StateResponse
    /// Starts/reports text recognition for picture subtitles (`subtitle` = 1-based id).
    func ocrStatus(path: String, subtitle: Int) async throws -> OCRStatus
    /// Starts/reports the measurement of the delay that fits a subtitle track
    /// to the speech in an audio track (1-based ids; poll while "working").
    func subtitleSync(path: String, subtitle: Int, audio: Int?) async throws -> SubtitleSyncStatus
    /// Preview thumbnails for a file. `make` starts making them if needed;
    /// false only reports what exists (for posters in lists).
    func thumbs(path: String, make: Bool) async throws -> ThumbsInfo
    /// Intro and credits: from chapters, else found by comparing the episode
    /// with its neighbour in the background (poll while "working").
    func markers(path: String) async throws -> MarkersStatus
    /// "This Mac" player window: what its AVPlayer sees (POST /api/local/report).
    func localReport(_ report: LocalReport) async throws -> OKResponse
    /// The palette strip (`info.palette`): one pixel per thumbnail, one high.
    func palette(_ info: ThumbsInfo) async throws -> NSImage
    /// Thumbnail `index` (1-based) from `info`.
    func thumbnail(_ info: ThumbsInfo, index: Int) async throws -> NSImage
    /// The now card's picture (`info.poster.url`), once the backend has chosen one.
    func poster(_ info: ThumbsInfo) async throws -> NSImage
    /// "basic" (latency probe every 5 s) or "detailed" (every 1 s).
    func setTelemetry(level: String) async throws -> OKResponse
}

extension Backend {
    /// Nothing to wait for unless the backend is a real process (LiveBackend).
    func stop() async { shutdown() }
}

enum BackendError: LocalizedError {
    case launch(String, log: String)
    case notRunning
    case http(Int, String?)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .launch(let m, _): return m
        case .notRunning: return "The Luftbro backend is not running."
        case .http(let code, let msg): return msg ?? "Backend returned HTTP \(code)."
        case .decoding(let m): return "Unexpected response from backend: \(m)"
        case .transport(let m): return m
        }
    }

    var log: String {
        if case .launch(_, let log) = self { return log }
        return ""
    }
}
