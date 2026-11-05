import Foundation

/// Client-side ring buffers for the incremental collections of /api/state.
/// Samples and requests are per session (cleared when session.id changes);
/// events are kept across sessions so the log tells the whole story.
struct Telemetry {
    static let maxSamples = 4 * 3600     // 4 h at 1 Hz
    static let maxRequests = 8000
    static let maxEvents = 3000

    private(set) var sessionID: String?
    private(set) var sessionStart: Double?
    private(set) var samples: [Sample] = []
    private(set) var requests: [RequestRecord] = []
    private(set) var events: [Event] = []
    /// App-side events get negative sequence numbers (backend ones are positive).
    private var localSeq = -1

    mutating func resetSession(id: String?, startedAt: Double?) {
        sessionID = id
        sessionStart = startedAt
        samples.removeAll(keepingCapacity: true)
        requests.removeAll(keepingCapacity: true)
    }

    mutating func resetAll() {
        resetSession(id: nil, startedAt: nil)
        events.removeAll()
    }

    mutating func ingest(_ r: StateResponse) {
        let floorT = (sessionStart ?? 0) - 1
        let hasSession = sessionID != nil
        if hasSession {
            append(&samples, r.samples.filter { $0.t >= floorT }, cap: Self.maxSamples)
            append(&requests, r.requests.filter { $0.t >= floorT }, cap: Self.maxRequests)
        }
        append(&events, r.events, cap: Self.maxEvents)
    }

    /// Log something the app itself observed (e.g. a media key) in the event list.
    mutating func note(_ level: String, _ source: String, _ message: String) {
        events.append(Event(seq: localSeq, t: Date().timeIntervalSince1970, level: level, source: source, message: message))
        localSeq -= 1
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    private func append<T>(_ arr: inout [T], _ new: [T], cap: Int) where T: Identifiable, T.ID == Int {
        guard !new.isEmpty else { return }
        // Guard against duplicates if the backend repeats items (app notes have ids < 0).
        let lastID = arr.last(where: { $0.id >= 0 })?.id ?? Int.min
        arr.append(contentsOf: new.filter { $0.id > lastID }.sorted { $0.id < $1.id })
        if arr.count > cap { arr.removeFirst(arr.count - cap) }
    }

    // MARK: - Derived

    var segmentRequests: [RequestRecord] { requests.filter { $0.kind == "segment" } }

    var problemRequestCount: Int {
        requests.reduce(0) { $0 + (($1.kind == "segment" && $1.health >= .warning) || $1.failed ? 1 : 0) }
    }

    var errorEventCount: Int {
        let start = sessionStart ?? 0
        return events.reduce(0) { $0 + (LogLevel($1.level) == .error && $1.t >= start - 1 ? 1 : 0) }
    }

    /// Delivery speed of the last few completed segment downloads (median Mbit/s and realtime ratio).
    var recentSegmentDelivery: (mbps: Double, ratio: Double)? {
        let recent = requests.lazy.filter { $0.kind == "segment" && !$0.failed && $0.realtimeRatio != nil }.suffix(3)
        guard !recent.isEmpty else { return nil }
        let m = recent.compactMap(\.mbps).sorted()
        let r = recent.compactMap(\.realtimeRatio).sorted()
        guard !m.isEmpty, !r.isEmpty else { return nil }
        return (m[m.count / 2], r[r.count / 2])
    }
}

extension Sample: Identifiable { var id: Int { seq } }

// MARK: - Chart series

struct ChartPoint: Identifiable {
    let id: Int
    let date: Date
    var tx: Double?          // Mbit/s, this second
    var txAvg: Double?       // Mbit/s, trailing 10 s
    var buffer: Double?      // s
    var empty: Bool
    var headroom: Double?    // s
    var speed: Double?       // ×
    var rtt: Double?         // ms
    var rttTimeout: Bool
    var rttRun: Int          // breaks the RTT line at timeouts
}

struct Interval: Identifiable {
    let id: Int
    let start: Date
    let end: Date
}

enum ChartRange: String, CaseIterable, Identifiable {
    case oneMinute = "1 min", fiveMinutes = "5 min", fifteenMinutes = "15 min", session = "Session"
    var id: String { rawValue }
    var seconds: Double? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .session: return nil
        }
    }
}

struct ChartSeries {
    var points: [ChartPoint] = []
    var stalls: [Interval] = []
    var domain: ClosedRange<Date>
    var maxTx: Double = 0
    var maxAvg: Double = 0
    var maxBuffer: Double = 0
    var maxHeadroom: Double = 0
    var maxSpeed: Double = 0
    var maxRTT: Double = 0
    var hasRTTMeasurements = false
    /// Changes whenever the points do: lets a chart skip redrawing when it gets
    /// the same data again (every poll re-creates the views).
    var revision = 0

    /// Nearest point to a date (points are sorted by date).
    func point(near d: Date) -> ChartPoint? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].date < d { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(points[lo - 1].date.timeIntervalSince(d)) < abs(points[lo].date.timeIntervalSince(d)) { return points[lo - 1] }
        return points[lo]
    }

    static func build(samples all: [Sample], events: [Event] = [], range: ChartRange, sessionStart: Double?, maxPoints: Int = 600) -> ChartSeries {
        // Seconds with a network warning/error event: used to tell an RTT
        // timeout (explicit null + event) from a second that simply wasn't probed.
        var netEventSeconds = Set<Int>()
        for e in events where e.source == "network" && LogLevel(e.level) != .info { netEventSeconds.insert(Int(e.t)) }
        func isTimeout(_ s: Sample) -> Bool {
            if let flag = s.rttTimeout { return flag && s.rttMs == nil }
            guard s.rttMs == nil, s.rttExplicitNull else { return false }
            let sec = Int(s.t)
            return netEventSeconds.contains(sec) || netEventSeconds.contains(sec - 1) || netEventSeconds.contains(sec + 1)
        }
        let latest = all.last?.t ?? (sessionStart ?? Date().timeIntervalSince1970)
        let start0 = sessionStart ?? all.first?.t ?? latest
        var lower = start0
        if let w = range.seconds { lower = max(start0, latest - w) }
        let upper = max(latest, lower + min(range.seconds ?? 60, 60))
        var series = ChartSeries(domain: Date(timeIntervalSince1970: lower)...Date(timeIntervalSince1970: upper))
        guard !all.isEmpty else { return series }

        // First index inside the window (keep 10 extra for the rolling average).
        let firstIdx = all.firstIndex { $0.t >= lower } ?? all.count
        let avgStart = max(0, firstIdx - 10)
        var rolling: [Double] = []
        var sum = 0.0
        var raw: [ChartPoint] = []
        raw.reserveCapacity(all.count - avgStart)
        var run = 0
        var seenRTT = false
        var playbackStarted = all[..<avgStart].contains { ($0.tvRate ?? 0) > 0 }
        for i in avgStart..<all.count {
            let s = all[i]
            let tx = (s.txBps ?? 0) / 1e6
            rolling.append(tx); sum += tx
            if rolling.count > 10 { sum -= rolling.removeFirst() }
            if s.rttMs != nil { seenRTT = true }
            if (s.tvRate ?? 0) > 0 { playbackStarted = true }
            let timeout = isTimeout(s)
            if timeout { run += 1 }
            guard i >= firstIdx else { continue }
            raw.append(ChartPoint(id: s.seq, date: Date(timeIntervalSince1970: s.t),
                                  tx: s.txBps.map { $0 / 1e6 }, txAvg: sum / Double(rolling.count),
                                  buffer: s.tvBufferedAheadS, empty: playbackStarted && (s.tvBufferEmpty ?? false),
                                  headroom: s.headroomS, speed: s.ffSpeed, rtt: s.rttMs,
                                  rttTimeout: timeout, rttRun: run))
        }
        series.hasRTTMeasurements = seenRTT
        series.revision = (all.last?.seq ?? 0) &* 1_000_003 &+ raw.count &* 31 &+ Int(lower)

        // Stall intervals from full-resolution data.
        var stalls: [Interval] = []
        var curStart: Date?
        var last: Date?
        for p in raw {
            if p.empty {
                if curStart == nil { curStart = p.date }
                last = p.date
            } else if let cs = curStart, let l = last {
                stalls.append(Interval(id: stalls.count, start: cs.addingTimeInterval(-0.5), end: l.addingTimeInterval(0.5)))
                curStart = nil
            }
        }
        if let cs = curStart, let l = last {
            stalls.append(Interval(id: stalls.count, start: cs.addingTimeInterval(-0.5), end: l.addingTimeInterval(0.5)))
        }
        series.stalls = stalls

        // Decimate long windows into buckets (mean for rates, min for buffers, max for RTT).
        var pts = raw
        if raw.count > maxPoints {
            let bucket = Int((Double(raw.count) / Double(maxPoints)).rounded(.up))
            pts = []
            pts.reserveCapacity(raw.count / bucket + 1)
            var i = 0
            while i < raw.count {
                let slice = raw[i..<min(raw.count, i + bucket)]
                func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
                let mid = slice[slice.startIndex + slice.count / 2]
                let rtts = slice.compactMap(\.rtt)
                let timeout = slice.contains { $0.rttTimeout }
                pts.append(ChartPoint(id: mid.id, date: mid.date,
                                      tx: mean(slice.compactMap(\.tx)), txAvg: mean(slice.compactMap(\.txAvg)),
                                      buffer: slice.compactMap(\.buffer).min(), empty: slice.contains { $0.empty },
                                      headroom: slice.compactMap(\.headroom).min(), speed: mean(slice.compactMap(\.speed)),
                                      rtt: rtts.max(), rttTimeout: timeout && rtts.isEmpty,
                                      rttRun: slice.last!.rttRun))
                i += bucket
            }
        }
        series.points = pts
        for p in pts {
            series.maxTx = max(series.maxTx, p.tx ?? 0)
            series.maxAvg = max(series.maxAvg, p.txAvg ?? 0)
            series.maxBuffer = max(series.maxBuffer, p.buffer ?? 0)
            series.maxHeadroom = max(series.maxHeadroom, p.headroom ?? 0)
            series.maxSpeed = max(series.maxSpeed, p.speed ?? 0)
            series.maxRTT = max(series.maxRTT, p.rtt ?? 0)
        }
        return series
    }
}
