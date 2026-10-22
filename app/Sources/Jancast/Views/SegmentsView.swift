import Charts
import SwiftUI

struct SegmentsView: View {
    @Environment(AppModel.self) private var model
    @State private var segmentsOnly = true
    @State private var problemsOnly = false
    @State private var showAll = false
    @State private var selection = Set<Int>()
    @State private var hoverSegment: Int?

    var body: some View {
        if model.live?.session == nil {
            ContentUnavailableView("No Requests Yet", systemImage: "square.stack.3d.up",
                                   description: Text("Every HTTP request the Apple TV makes for the stream is listed here once playback starts."))
        } else {
            content
        }
    }

    private var content: some View {
        let segDur = model.live?.session?.segmentDurationS ?? 6
        let all = model.telemetry.requests
        let segs = all.filter { $0.kind == "segment" }
        let shown = showAll ? segs : Array(segs.suffix(150))
        let rows = all.reversed().filter { r in
            (!segmentsOnly || r.kind == "segment") && (!problemsOnly || r.failed || r.health >= .warning)
        }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SegmentSummary(segments: segs, segDur: segDur, showAll: $showAll)
                SegmentChart(segments: shown, segDur: segDur, hoverSegment: $hoverSegment)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack(spacing: 12) {
                Toggle("Segments only", isOn: $segmentsOnly).toggleStyle(.checkbox)
                Toggle("Slow or failed only", isOn: $problemsOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(rows.count) requests").foregroundStyle(.secondary)
                Button { AppModel.copyToPasteboard(Self.text(for: rows)) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the visible rows as text")
            }
            .controlSize(.small)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Divider()
            RequestTable(rows: rows, selection: $selection)
                .frame(minHeight: 80)
        }
    }

    static func text(for rows: [RequestRecord]) -> String {
        rows.map(line(for:)).joined(separator: "\n")
    }

    private static func line(for r: RequestRecord) -> String {
        var cols: [String] = []
        cols.append(Fmt.timeMs(r.t))
        cols.append(r.kind ?? "")
        cols.append(r.segment.map { String($0) } ?? "-")
        cols.append(r.status.map { String($0) } ?? "-")
        cols.append(Fmt.bytes(r.bytes))
        cols.append(r.durationMs.map { String(format: "%.0f ms", $0) } ?? "-")
        cols.append(r.mbps.map { String(format: "%.1f Mbit/s", $0) } ?? "-")
        cols.append(Fmt.ratio(r.realtimeRatio))
        cols.append(r.error ?? "")
        cols.append(r.path ?? "")
        return cols.joined(separator: "\t")
    }
}

/// One line: counts by speed class, the median, and the chart's range picker.
private struct SegmentSummary: View {
    let segments: [RequestRecord]
    let segDur: Double
    @Binding var showAll: Bool

    var body: some View {
        let ok = segments.filter { $0.health == .good }.count
        let slow = segments.filter { $0.health == .warning }.count
        let bad = segments.filter { $0.health == .critical }.count
        let ratios = segments.compactMap(\.realtimeRatio).sorted()
        let median = ratios.isEmpty ? nil : ratios[ratios.count / 2]
        HStack(spacing: 12) {
            // Wide: one stat each. Narrow: one plain sentence, a problem
            // glyph only when something was slow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    stat("sent", "\(segments.count)", .neutral)
                    stat("fast", "\(ok)", .good, help: "Sent at least 1.5× faster than realtime")
                    stat("marginal", "\(slow)", slow > 0 ? .warning : .neutral, help: "Sent 1–1.5× faster than realtime")
                    stat("too slow or failed", "\(bad)", bad > 0 ? .critical : .neutral, help: "Took longer to send than the video it holds")
                    stat("median", Fmt.ratio(median), .neutral, help: "Typical send speed relative to realtime")
                }
                HStack(spacing: 5) {
                    if bad > 0 || slow > 0 { HealthIcon(health: bad > 0 ? .critical : .warning).imageScale(.small) }
                    Text("\(segments.count) sent · \(ok) fast"
                         + (slow > 0 ? " · \(slow) marginal" : "")
                         + (bad > 0 ? " · \(bad) too slow" : "")
                         + " · median \(Fmt.ratio(median))")
                        .monospacedDigit()
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Picker("", selection: $showAll) {
                Text("Last 150").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .font(.callout)
        .lineLimit(1)
        .help("A segment holds \(Int(segDur)) s of video. If sending one takes longer than that, the TV’s buffer shrinks.")
    }

    private func stat(_ title: String, _ value: String, _ h: Health, help: String = "") -> some View {
        HStack(spacing: 4) {
            if h != .neutral { HealthIcon(health: h).imageScale(.small) }
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }
        .help(help)
    }
}

private struct SegmentChart: View {
    let segments: [RequestRecord]
    let segDur: Double
    @Binding var hoverSegment: Int?

    var body: some View {
        let durations = segments.map { ($0.durationMs ?? 0) / 1000 }
        let yMax = max(segDur * 1.3, (durations.max() ?? 0) * 1.1)
        let hovered = hoverSegment.flatMap { h in segments.last { $0.segment == h } }
        VStack(alignment: .leading, spacing: 6) {
            // Title on its own line: next to the legend it got cut off.
            Text("Time to send each segment").font(.callout.weight(.semibold))
            HStack(spacing: 14) {
                if let r = hovered {
                    Text("#\(r.segment ?? 0) · \(Fmt.seconds((r.durationMs ?? 0) / 1000)) · \(Fmt.mbps(r.mbps)) Mbit/s · \(Fmt.ratio(r.realtimeRatio))\(r.error.map { " · \($0)" } ?? "")")
                        .font(.callout).monospacedDigit().lineLimit(1)
                } else {
                    LegendSwatch(kind: .dashed, color: .secondary, title: "\(Int(segDur)) s = realtime — bars should stay below")
                }
                Spacer(minLength: 0)
            }
            Chart {
                ForEach(segments) { r in
                    let seg = Double(r.segment ?? 0)
                    let d = max((r.durationMs ?? 0) / 1000, yMax * 0.012)
                    RectangleMark(xStart: .value("Segment", seg - 0.4), xEnd: .value("Segment", seg + 0.4),
                                  yStart: .value("s", 0), yEnd: .value("s", min(d, yMax)))
                        .foregroundStyle(r.health.color.opacity(hoverSegment == nil || hoverSegment == r.segment ? 0.9 : 0.45))
                        .cornerRadius(1.5)
                }
                RuleMark(y: .value("Realtime", segDur))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            .chartYScale(domain: 0...yMax)
            .chartXScale(domain: xDomain)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .named("segmentHover")) { phase in
                            switch phase {
                            case .active(let loc):
                                guard let f = proxy.plotFrame else { return }
                                if let v: Double = proxy.value(atX: loc.x - geo[f].origin.x) { hoverSegment = Int(v.rounded()) }
                            case .ended: hoverSegment = nil
                            }
                        }
                }
                .coordinateSpace(name: "segmentHover")
            }
            .frame(height: 100)
            .overlay {
                if segments.isEmpty { Text("No segment requests yet").foregroundStyle(.secondary) }
            }
        }
        .card(padding: 10)
    }

    private var xDomain: ClosedRange<Double> {
        let s = segments.compactMap(\.segment)
        guard let lo = s.min(), let hi = s.max() else { return 0...10 }
        return Double(lo) - 1...Double(max(hi, lo + 10)) + 1
    }
}

private struct RequestTable: View {
    let rows: [RequestRecord]
    @Binding var selection: Set<Int>

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Time") { r in Text(Fmt.timeMs(r.t)).monospacedDigit() }
                .width(min: 90, ideal: 95)
            TableColumn("Segment") { r in Text(r.segment.map(String.init) ?? "—").monospacedDigit() }
                .width(min: 50, ideal: 60)
            TableColumn("Kind") { r in Text(r.kind ?? "—") }
                .width(min: 55, ideal: 65)
            TableColumn("Status") { r in
                Text(r.status.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle((r.status ?? 200) >= 400 ? Color.red : .primary)
            }
            .width(min: 45, ideal: 50)
            TableColumn("Size") { r in Text(Fmt.bytes(r.bytes)).monospacedDigit() }
                .width(min: 60, ideal: 75)
            TableColumn("Send time") { r in Text(r.durationMs.map { $0 < 1000 ? String(format: "%.0f ms", $0) : String(format: "%.2f s", $0 / 1000) } ?? "—").monospacedDigit() }
                .width(min: 65, ideal: 75)
            TableColumn("Mbit/s") { r in Text(Fmt.mbps(r.mbps)).monospacedDigit() }
                .width(min: 50, ideal: 60)
            TableColumn("Realtime") { r in
                HStack(spacing: 4) {
                    if r.kind == "segment" { HealthIcon(health: r.health).imageScale(.small) }
                    Text(Fmt.ratio(r.realtimeRatio)).monospacedDigit()
                }
            }
            .width(min: 65, ideal: 75)
            TableColumn("Error") { r in
                Text(r.error ?? "").foregroundStyle(r.error == nil ? Color.secondary : .red).help(r.path ?? "")
            }
        }
        .onCopyCommand {
            let chosen = rows.filter { selection.contains($0.id) }
            return [NSItemProvider(object: SegmentsView.text(for: chosen) as NSString)]
        }
    }
}
