import SwiftUI

// One place for every semantic color/symbol so the whole app reads as one
// system: status colors (good / warning / serious / critical) are reserved for
// state and always ship with an SF Symbol, never color alone.

enum Health: Int, Comparable {
    case neutral = 0, good, warning, serious, critical

    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return .green
        case .warning: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .neutral: return "minus.circle"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .serious: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

/// Series colors (identity, not state). One hue per measure, used the same way
/// in KPI tiles and charts.
enum SeriesColor {
    static let throughput = Color.blue
    static let buffer = Color.teal
    static let headroom = Color.indigo
    static let speed = Color.purple
    static let rtt = Color.cyan
    static let reference = Color.secondary
    static let incident = Color.red
}

enum Phase: String, CaseIterable {
    case idle, preparing, connecting, pairing, buffering, playing, paused, stalled, finished, failed, stopped, unknown

    init(_ raw: String?) {
        guard let raw, !raw.isEmpty else { self = .idle; return }
        self = Phase(rawValue: raw.lowercased()) ?? .unknown
    }

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .connecting: return "Connecting"
        case .pairing: return "Pairing"
        case .buffering: return "Buffering"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stalled: return "Stalled"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "moon.zzz"
        case .preparing: return "gearshape.2"
        case .connecting: return "airplayvideo"
        case .pairing: return "lock.shield"
        case .buffering: return "hourglass"
        case .playing: return "play.fill"
        case .paused: return "pause.fill"
        case .stalled: return "exclamationmark.triangle.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped: return "stop.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .playing, .finished: return .green
        case .preparing, .connecting, .buffering, .pairing: return .blue
        case .stalled: return .orange
        case .failed: return .red
        case .paused, .stopped, .idle, .unknown: return .secondary
        }
    }

    /// A session is running and can be controlled.
    var isActive: Bool {
        switch self {
        case .preparing, .connecting, .pairing, .buffering, .playing, .paused, .stalled: return true
        default: return false
        }
    }

    /// Position on the happy path, used by the phase stepper.
    var stepIndex: Int {
        switch self {
        case .idle, .unknown: return -1
        case .preparing: return 0
        case .connecting, .pairing: return 1
        case .buffering: return 2
        case .playing, .paused, .stalled, .stopped, .failed: return 3
        case .finished: return 4
        }
    }
}

enum DiagStatus: String {
    case ok, warning, failing, failed, unknown

    init(_ raw: String?) { self = DiagStatus(rawValue: raw?.lowercased() ?? "") ?? .unknown }

    var health: Health {
        switch self {
        case .ok: return .good
        case .warning: return .warning
        case .failing: return .serious
        case .failed: return .critical
        case .unknown: return .neutral
        }
    }

    var title: String {
        switch self {
        case .ok: return "Healthy"
        case .warning: return "Warning"
        case .failing: return "Failing"
        case .failed: return "Failed"
        case .unknown: return "No diagnosis yet"
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "exclamationmark.octagon.fill"
        case .failed: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum Cause: String {
    case network, encoder, device, source, server, unknown

    init(_ raw: String) { self = Cause(rawValue: raw.lowercased()) ?? .unknown }

    var title: String {
        switch self {
        case .network: return "Network"
        case .encoder: return "Preparation / encoder"
        case .device: return "Apple TV"
        case .source: return "Source file"
        case .server: return "Jancast HTTP server"
        case .unknown: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .network: return "wifi"
        case .encoder: return "cpu"
        case .device: return "appletv.fill"
        case .source: return "film"
        case .server: return "server.rack"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum LogLevel: String, CaseIterable, Identifiable {
    case info, warn, error

    var id: String { rawValue }

    init(_ raw: String?) {
        switch raw?.lowercased() {
        case "warn", "warning": self = .warn
        case "error", "critical", "fatal": self = .error
        default: self = .info
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .secondary
        case .warn: return .yellow
        case .error: return .red
        }
    }

    var title: String {
        switch self {
        case .info: return "Info"
        case .warn: return "Warning"
        case .error: return "Error"
        }
    }

    var rank: Int {
        switch self {
        case .info: return 0
        case .warn: return 1
        case .error: return 2
        }
    }
}

extension RequestRecord {
    var failed: Bool { (status ?? 200) >= 400 || error != nil }

    /// Health of a segment delivery: < 1x realtime cannot keep up, < 1.5x is marginal.
    var health: Health {
        if failed { return .critical }
        guard let r = realtimeRatio else { return .neutral }
        if r < 1 { return .critical }
        if r < 1.5 { return .warning }
        return .good
    }
}
