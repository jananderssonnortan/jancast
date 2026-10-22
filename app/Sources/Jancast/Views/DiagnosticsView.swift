import SwiftUI

/// Summary tab: the verdict first, then the handful of numbers behind it.
/// Technical stream facts are folded away; the charts have their own tab.
struct DiagnosticsOverview: View {
    @Environment(AppModel.self) private var model
    @AppStorage("diagStreamDetailsExpanded") private var detailsExpanded = false

    var body: some View {
        if let live = model.live, let session = live.session {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DiagnosisBanner(diagnosis: live.diagnosis, sessionError: session.error,
                                    playerError: live.playback?.error, prepError: live.prep?.error, phase: model.phase)
                    KPIGrid(live: live, session: session)
                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        StreamDetails(session: session, live: live)
                            .padding(.top, 6)
                    } label: {
                        Text("Stream details").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
        } else {
            NoStreamView()
        }
    }
}

/// Charts tab: the shared-crosshair timeline.
///
/// The series is built off the main thread, only when new samples arrive or
/// the range/width changes — not on every redraw (the crosshair moves on every
/// pointer move, and rebuilding hours of samples then stalled the UI). Points
/// are capped to the chart's width, and the crosshair snaps to them, so moving
/// the pointer only redraws when it reaches another point.
struct DiagnosticsCharts: View {
    @Environment(AppModel.self) private var model
    @State private var range: ChartRange = .fiveMinutes
    @State private var hover = ChartHover()
    @State private var series: ChartSeries?
    @State private var width: CGFloat = 500

    private func refreshEvery(_ range: ChartRange, _ points: Int) -> Int {
        let span = range.seconds ?? Double(model.telemetry.samples.count)
        return max(1, Int(span / Double(max(1, points))))
    }

    private struct SeriesKey: Equatable {
        var seq: Int?
        var range: ChartRange
        var points: Int
        var session: String?
    }

    var body: some View {
        if let live = model.live, let session = live.session {
            let maxPoints = max(100, min(400, Int(width / 3)))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Range", selection: $range) {
                            ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if let series {
                        TimelineCharts(series: series,
                                       latencyEvery5s: live.telemetryLevel == "basic",
                                       bitrate: session.streamBitrateBps, segmentDuration: session.segmentDurationS ?? 6,
                                       prepDone: live.prep?.done ?? false,
                                       hover: hover)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(16)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    if abs(w - width) > 40 { width = w }       // re-sample only on real size changes
                }
            }
            // New data is folded in at most once per point's worth of time
            // (5 min over ~160 points ≈ every 2 s; a whole session less often).
            .task(id: SeriesKey(seq: (model.telemetry.samples.last?.seq ?? 0) / refreshEvery(range, maxPoints),
                                range: range, points: maxPoints, session: session.id)) {
                let samples = model.telemetry.samples, events = model.telemetry.events
                let start = session.startedAt, range = range
                let built = await Task.detached(priority: .userInitiated) {
                    ChartSeries.build(samples: samples, events: events, range: range,
                                      sessionStart: start, maxPoints: maxPoints)
                }.value
                if !Task.isCancelled { series = built }
            }
        } else {
            NoStreamView()
        }
    }
}

private struct NoStreamView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Stream Yet", systemImage: "waveform.path.ecg")
        } description: {
            Text("Start playback to see throughput, buffer and encoder measurements — and a diagnosis of what goes wrong. Measurements are always recorded, so you can open this after a problem.")
        }
    }
}

// MARK: - Diagnosis banner

struct DiagnosisBanner: View {
    @State private var expandedOverride: Bool?
    let diagnosis: Diagnosis?
    var sessionError: String? = nil
    let playerError: String?
    let prepError: String?
    let phase: Phase

    private var status: DiagStatus {
        let s = DiagStatus(diagnosis?.status)
        if sessionError != nil || playerError != nil || prepError != nil || phase == .failed { return s == .failing ? .failing : .failed }
        return s
    }

    private var suspects: [Suspect] {
        (diagnosis?.suspects ?? []).sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
    }

    /// Details without the "Error: …" line when the error box already shows it.
    private var detailLines: [String] {
        let d = diagnosis?.details ?? []
        guard let e = sessionError else { return d }
        return d.filter { !($0.hasPrefix("Error:") && $0.contains(e.prefix(40))) }
    }

    private var collapsedSummary: String {
        let strong = suspects.filter { ($0.confidence ?? 0) >= 0.3 }
        if strong.isEmpty { return "nothing points to a problem (\(suspects.count) causes checked)" }
        return strong.map { "\(Cause($0.cause).title) \(Fmt.percent($0.confidence))" }.joined(separator: ", ")
    }

    /// All fine: nothing to explain, so one quiet line instead of the full card.
    private var isCalm: Bool {
        status == .ok && sessionError == nil && playerError == nil && prepError == nil
            && !suspects.contains { ($0.confidence ?? 0) >= 0.3 }
    }

    var body: some View {
        let h = status.health
        VStack(alignment: .leading, spacing: 12) {
            if isCalm {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: status.symbol)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, h.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diagnosis?.headline ?? status.title).font(.headline)
                        if !detailLines.isEmpty {
                            Text(detailLines.joined(separator: " · "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                full
            }
        }
        .padding(isCalm ? 12 : 16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background)
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(h.color.opacity(h == .neutral ? 0.04 : isCalm ? 0.06 : 0.10))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(h.color.opacity(h == .neutral ? 0.2 : isCalm ? 0.3 : 0.45), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: status)
    }

    @ViewBuilder private var full: some View {
        let h = status.health
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: status.symbol)
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(h == .warning ? Color.black.opacity(0.75) : .white, h.color)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(status.title.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        // Phase only when it adds information ("FAILED · FAILED", or a
                        // headline that already says "Stopped", doesn't).
                        if phase != .idle && phase != .unknown && phase.title.lowercased() != status.title.lowercased()
                            && phase.title.lowercased() != diagnosis?.headline?.lowercased() {
                            Text("·").foregroundStyle(.secondary)
                            Text(phase.title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                    Text(diagnosis?.headline ?? (status == .unknown ? "Waiting for measurements…" : status.title))
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let sessionError {
                        ErrorBox(message: sessionError)
                    }
                    if let playerError, playerError != sessionError {
                        Label("Apple TV reported: \(playerError)", systemImage: "appletv.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let prepError {
                        Label("Preparation failed: \(prepError)", systemImage: "cpu")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(line).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
                Spacer(minLength: 0)
            }

            if !suspects.isEmpty {
                let expanded = expandedOverride ?? (status != .ok)
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedOverride = !expanded }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .imageScale(.small)
                        Text("Likely causes").font(.caption.weight(.semibold))
                        if !expanded {
                            Text("· " + collapsedSummary).font(.caption)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(spacing: 10) {
                        ForEach(suspects, id: \.self) { s in SuspectRow(suspect: s, top: s == suspects.first && (s.confidence ?? 0) >= 0.3) }
                    }
                }
            }
        }
    }
}

private struct SuspectRow: View {
    let suspect: Suspect
    let top: Bool

    var body: some View {
        let cause = Cause(suspect.cause)
        let c = suspect.confidence ?? 0
        // Evidence on its own line: beside fixed columns it overflowed the
        // 400 pt drawer and was cut to a few words at 560.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: cause.symbol)
                    .frame(width: 20)
                    .foregroundStyle(c >= 0.3 ? Color.primary : .secondary)
                Text(cause.title)
                    .font(.callout.weight(top ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ConfidenceBar(value: c)
                    .frame(width: 70, height: 6)
                Text(c < 0.05 ? "ruled out" : Fmt.percent(c))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
            }
            if let evidence = suspect.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.callout)
                    .foregroundStyle(c >= 0.3 ? Color.primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 30)
            }
        }
        .opacity(c < 0.05 ? 0.7 : 1)
    }
}

private struct ConfidenceBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(value >= 0.6 ? Color.red : value >= 0.3 ? Color.orange : Color.secondary)
                    .frame(width: max(value > 0 ? 4 : 0, g.size.width * min(1, value)))
            }
        }
        .accessibilityLabel("Confidence \(Int(value * 100)) percent")
    }
}

/// The raw failure message, selectable and copyable.
struct ErrorBox: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { AppModel.copyToPasteboard(message) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy error message")
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.red.opacity(0.35)))
        .padding(.vertical, 2)
    }
}

// MARK: - Stream details

/// The technical facts the old session card showed, as a quiet two-column list.
private struct StreamDetails: View {
    let session: Session
    let live: StateResponse

    var body: some View {
        let pb = live.playback
        let rows: [(String, String)] = [
            ("Video", "\(Fmt.codec(session.video?.codec)) \(Fmt.resolution(session.video?.width, session.video?.height) ?? "") · \(session.video?.mode == "reencode" ? "re-encoded" + (session.video?.reason.map { " (\($0))" } ?? "") : "copied")"),
            ("Audio", "\(session.audio?.label ?? Fmt.dash) · \(session.audio?.mode == "transcode" ? "converted to \(Fmt.codec(session.audio?.outCodec))" : "copied")"),
            ("Stream", "\(Fmt.mbit(session.streamBitrateBps)) · \(session.segmentsReady ?? 0) of \(session.segmentsTotal ?? 0) segments prepared"),
            ("Served at", session.streamUrl ?? Fmt.dash),
            ("Apple TV", [session.device?.name, session.device?.model, session.device?.address].compactMap { $0 }.joined(separator: " · ")),
            ("TV last reported", pb?.lastReportAt.map { Fmt.time($0) } ?? "never"),
            ("Telemetry", live.telemetryLevel == "detailed" ? "detailed (latency every 1 s)" : "basic (latency every 5 s)"),
        ]
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(row.1).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }
}

// MARK: - KPI tiles

private struct KPIGrid: View {
    @Environment(AppModel.self) private var model
    let live: StateResponse
    let session: Session

    var body: some View {
        let n = live.network
        let pb = live.playback
        let prep = live.prep
        let need = session.streamBitrateBps
        let delivery = model.telemetry.recentSegmentDelivery
        let ahead = pb?.bufferedAheadS
        let bufferFull = pb?.bufferFull == true || (ahead ?? 0) >= 20
        let idle = bufferFull && (n?.txBpsAvg10 ?? 0) < (need ?? 0) / 2

        let (bv, bu) = Fmt.secondsParts(ahead)
        let (hv, hu) = Fmt.secondsParts(prep?.done == true ? nil : live.playback?.position.flatMap { p in prep?.preparedS.map { $0 - p } })
        let tiles: [KPITile] = [
            // With the TV's buffer full the link idles on purpose: say so, not "0.0".
            KPITile(title: "Throughput", symbol: "arrow.up.right", tint: SeriesColor.throughput,
                    value: idle ? "Idle" : Fmt.mbitValue(n?.txBpsAvg10), unit: idle ? nil : "Mbit/s",
                    lines: [idle ? "TV has \(Fmt.seconds(ahead)) · needs \(Fmt.mbitValue(need))"
                                 : "now \(Fmt.mbitValue(n?.txBpsNow)) · needs \(Fmt.mbitValue(need))",
                            delivery.map { "segments \(Fmt.ratio($0.ratio)) · \(Fmt.mbps($0.mbps)) Mbit/s" } ?? "no segments yet"],
                    health: throughputHealth(delivery?.ratio, avg: n?.txBpsAvg10, need: need, bufferFull: bufferFull)),

            KPITile(title: "TV buffer", symbol: "tray.full", tint: SeriesColor.buffer,
                    value: bv, unit: bu,
                    lines: [pb?.bufferEmpty == true ? "empty — playback stalled" : (pb?.bufferFull == true ? "buffer full" : (pb?.likelyToKeepUp == false ? "TV expects to run dry" : "TV keeps up")),
                            pb?.readyToPlay == false ? "not ready to play" : " "],
                    health: bufferHealth(ahead, empty: pb?.bufferEmpty)),

            KPITile(title: "Headroom", symbol: "cpu", tint: SeriesColor.headroom,
                    value: prep?.done == true ? "Done" : hv, unit: prep?.done == true ? nil : hu,
                    lines: [prep?.done == true ? "whole file prepared" : "ahead of the TV",
                            prep?.onDemand == true && prep?.speed == nil
                                ? "made on request · \(Fmt.percent(prep?.progress))"
                                : "ffmpeg \(Fmt.speed(prep?.speed)) · \(Fmt.percent(prep?.progress))"],
                    health: prepHealth(prep, position: pb?.position)),

            KPITile(title: "Round trip", symbol: "point.3.connected.trianglepath.dotted", tint: SeriesColor.rtt,
                    value: n?.rttMs.map { $0 < 10 ? String(format: "%.1f", $0) : String(format: "%.0f", $0) } ?? (n == nil ? Fmt.dash : "timeout"),
                    unit: n?.rttMs == nil ? nil : "ms",
                    lines: ["avg \(Fmt.ms(n?.rttMsAvg))", "loss \(Fmt.percent(n?.rttLoss))"],
                    health: rttHealth(n)),

            KPITile(title: "Stalls", symbol: "pause.circle", tint: .secondary,
                    value: "\(pb?.stallCount ?? 0)", unit: nil,
                    lines: ["\(Fmt.seconds(pb?.stalledSTotal ?? 0)) in total", pb?.bufferEmpty == true ? "stalled now" : " "],
                    health: stallHealth(pb)),

            KPITile(title: "HTTP", symbol: "server.rack", tint: .secondary,
                    value: "\(n?.httpErrors ?? 0)", unit: "errors",
                    lines: ["\(n?.clientAborts ?? 0) client aborts", "\(model.telemetry.requests.count) requests"],
                    health: httpHealth(n)),

            subtitleTile(session.subtitle, playing: (pb?.position ?? 0) > 0),
            fastStartTile(prep),
            timingTile(session.timing),
        ]
        // Rows of three: the window is one narrow column. Lines may wrap;
        // the tiles of a row keep one height.
        VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: 3)), id: \.self) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row..<min(row + 3, tiles.count), id: \.self) { tiles[$0] }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func throughputHealth(_ ratio: Double?, avg: Double?, need: Double?, bufferFull: Bool) -> Health {
        // With a full TV buffer the link idles on purpose, so a low average is fine.
        if !bufferFull, let avg, let need, need > 0, avg < need { return .critical }
        if let ratio {
            if ratio < 1 { return bufferFull ? .warning : .critical }
            if ratio < 1.5 { return .warning }
            return .good
        }
        guard let avg, let need, need > 0 else { return .neutral }
        if bufferFull { return .good }
        return avg >= need * 1.2 ? .good : (avg >= need ? .warning : .critical)
    }

    /// Text, read from pictures or burned in; delay; and whether the TV is
    /// actually fetching them (the clearest answer to "no subtitles on the TV").
    private func subtitleTile(_ sub: SessionSubtitle?, playing: Bool) -> KPITile {
        let fetched = model.telemetry.requests.filter { $0.kind == "subtitle" }
        let mode: String
        switch sub?.mode {
        case "ocr": mode = "Read as text"
        case "burn": mode = "Burned in"
        default: mode = "Text"
        }
        guard let sub else {
            return KPITile(title: "Subtitles", symbol: "captions.bubble", tint: .secondary,
                           value: "Off", unit: nil, lines: [" ", " "], health: .neutral)
        }
        let delay = (sub.delay ?? 0) == 0 ? "no delay" : String(format: "delay %+.1f s", sub.delay ?? 0)
        let kind = sub.text.map { "\(mode) (\($0))" } ?? mode
        if sub.inStream == false {
            return KPITile(title: "Subtitles", symbol: "captions.bubble", tint: .secondary,
                           value: "Failed", unit: nil, lines: [kind, "playing without them"], health: .serious)
        }
        if sub.mode == "burn" {
            return KPITile(title: "Subtitles", symbol: "captions.bubble", tint: .secondary,
                           value: mode, unit: nil, lines: ["in the picture", delay], health: .good)
        }
        let last = fetched.last.map { r -> String in
            let ago = max(0, Date().timeIntervalSince1970 - r.t)
            return ago < 60 ? "last one \(Int(ago)) s ago" : "last one " + Fmt.ago(r.t)
        } ?? "TV hasn’t asked yet"
        return KPITile(title: "Subtitles", symbol: "captions.bubble", tint: .secondary,
                       value: "\(fetched.count)", unit: "fetched",
                       lines: ["\(kind) · \(delay)", last],
                       health: fetched.isEmpty ? (playing ? .warning : .neutral) : .good)
    }

    /// Fast start makes segments when the TV asks: the waits are what it feels.
    private func fastStartTile(_ prep: Prep?) -> KPITile {
        guard let f = prep?.fastStart else {
            return KPITile(title: "Fast start", symbol: "bolt", tint: .secondary,
                           value: "Off", unit: nil,
                           lines: [prep == nil ? " " : "whole file made ahead", " "], health: .neutral)
        }
        let (v, u) = Self.waitParts(f.waitMaxMs)
        let waited = f.waited ?? 0
        return KPITile(title: "Fast start", symbol: "bolt", tint: .secondary,
                       value: waited == 0 ? "0" : v, unit: waited == 0 ? "waits" : u,
                       lines: [waited == 0 ? "every segment was ready" : "longest · typical \(Self.waitText(f.waitMedianMs))",
                               "\(waited)/\(f.segmentRequests ?? 0) waited · \(f.restarts ?? 0) restarts"],
                       health: (f.waitMaxMs ?? 0) >= 8000 ? .warning : .good)
    }

    private func timingTile(_ t: SessionTiming?) -> KPITile {
        let (v, u) = Fmt.secondsParts(t?.startS)
        // "Startup": "Time to picture" didn't fit a third of the drawer.
        return KPITile(title: "Startup", symbol: "timer", tint: .secondary,
                       value: v, unit: t?.startS == nil ? nil : u,
                       lines: ["Play to picture", t?.seekS.map { "last jump \(Fmt.seconds($0))" } ?? "no jumps yet"],
                       health: t?.startS == nil ? .neutral : ((t?.startS ?? 0) > 20 ? .warning : .good))
    }

    static func waitText(_ ms: Double?) -> String {
        let (v, u) = waitParts(ms)
        return "\(v) \(u)"
    }

    static func waitParts(_ ms: Double?) -> (String, String) {
        guard let ms else { return (Fmt.dash, "") }
        return ms < 1000 ? (String(format: "%.0f", ms), "ms") : (String(format: "%.1f", ms / 1000), "s")
    }

    private func bufferHealth(_ s: Double?, empty: Bool?) -> Health {
        if empty == true { return .critical }
        guard let s else { return .neutral }
        if s < 5 { return .critical }
        if s < 15 { return .warning }
        return .good
    }

    private func prepHealth(_ p: Prep?, position: Double?) -> Health {
        guard let p else { return .neutral }
        if p.error != nil { return .critical }
        if p.done == true { return .good }
        let head = (p.preparedS ?? 0) - (position ?? 0)
        if let sp = p.speed, sp < 1, head < 30 { return .critical }
        if head < 15 { return .critical }
        if head < 60 || (p.speed ?? 2) < 1.2 { return .warning }
        return .good
    }

    private func rttHealth(_ n: NetworkStats?) -> Health {
        guard let n else { return .neutral }
        let loss = n.rttLoss ?? 0
        guard let avg = n.rttMsAvg ?? n.rttMs else { return loss > 0 ? .critical : .neutral }
        if loss >= 0.2 || avg > 150 { return .critical }
        if loss > 0 || avg > 40 { return .warning }
        return .good
    }

    private func stallHealth(_ pb: Playback?) -> Health {
        guard let pb else { return .neutral }
        if pb.bufferEmpty == true { return .critical }
        let c = pb.stallCount ?? 0
        return c == 0 ? .good : (c < 3 ? .warning : .critical)
    }

    private func httpHealth(_ n: NetworkStats?) -> Health {
        guard let n else { return .neutral }
        if (n.httpErrors ?? 0) > 0 { return .serious }
        if (n.clientAborts ?? 0) > 0 { return .warning }
        return .good
    }
}

private struct KPITile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let unit: String?
    let lines: [String]
    let health: Health

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                HealthIcon(health: health)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            // A third of a 400–560 pt drawer: a line wraps rather than end in
            // "…", after a "·" rather than before it.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.replacingOccurrences(of: " · ", with: "\u{00A0}· "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 10)
        .overlay(alignment: .leading) {
            if health >= .warning {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .fill(health.color)
                    .frame(width: 3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
