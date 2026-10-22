import Charts
import SwiftUI

/// The four (+1) time-series charts. They share one x-domain and one hover
/// crosshair, so pointing at a moment in one chart shows what every other
/// measure was doing at that same second.
struct TimelineCharts: View {
    let series: ChartSeries
    var latencyEvery5s = false
    let bitrate: Double?
    let segmentDuration: Double
    let prepDone: Bool
    let hover: ChartHover

    var body: some View {
        // One per row: the drawer is one narrow column.
        VStack(spacing: 12) {
            ThroughputChart(series: series, bitrate: bitrate, hover: hover)
            BufferChart(series: series, hover: hover)
            RTTChart(series: series, sparse: latencyEvery5s, hover: hover)
            HeadroomChart(series: series, segmentDuration: segmentDuration, prepDone: prepDone, hover: hover)
            SpeedChart(series: series, prepDone: prepDone, hover: hover)
        }
    }
}

// MARK: - Shared chrome

struct ChartCard<Content: View, Legend: View>: View {
    let title: String
    let subtitle: String
    let readout: String
    let height: CGFloat
    @ViewBuilder var legend: Legend
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text(readout)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(spacing: 14) { legend; Spacer() }
            content.frame(height: height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// The data part of a chart. Equatable on what it draws, so it is redrawn only
/// when that changes — not on every poll (which re-creates these views) or
/// pointer move. The crosshair is a separate, cheap layer on top (HoverLayer).
private struct Plot<Content: ChartContent>: View, Equatable {
    let series: ChartSeries
    let yMax: Double
    let yLabel: String
    var ticks = 4
    /// Anything else the marks depend on (e.g. the "needed" line).
    var extra: [Double] = []
    /// The hovered point's value for the crosshair dot, if this chart has one.
    var dotY: ((ChartPoint) -> Double?)? = nil
    var dotColor: Color = .secondary
    let hover: ChartHover
    @ChartContentBuilder let content: () -> Content

    static func == (a: Self, b: Self) -> Bool {
        a.series.revision == b.series.revision && a.series.domain == b.series.domain
            && a.yMax == b.yMax && a.extra == b.extra && a.ticks == b.ticks
    }

    var body: some View {
        Chart { content() }
            .chartYScale(domain: 0...yMax)
            .chartYAxisLabel(yLabel)
            .timeAxis(series.domain, ticks: ticks)
            .valueAxis()
            .chartOverlay { proxy in
                HoverLayer(proxy: proxy, series: series, dotY: dotY, dotColor: dotColor, hover: hover)
            }
    }
}

/// The shared crosshair: the measured moment under the pointer, in any chart.
/// An observable object rather than a Binding, so the crosshair layers (and the
/// readouts) follow the pointer at once while the plots under them are skipped.
@Observable
final class ChartHover {
    var date: Date?

    /// Snap to the nearest measured point; only a different point is a change.
    func point(at d: Date, in series: ChartSeries) {
        let snapped = series.point(near: d)?.date
        if snapped != date { date = snapped }
    }
}

/// Pointer tracking plus the crosshair line and dot, drawn over the plot.
/// Only this layer (and the readouts) depend on `hover`.
private struct HoverLayer: View {
    let proxy: ChartProxy
    let series: ChartSeries
    let dotY: ((ChartPoint) -> Double?)?
    let dotColor: Color
    let hover: ChartHover

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                // Measured in this layer's own space (inside a scroll view the
                // default space can be off).
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .named("chartHover")) { phase in
                        switch phase {
                        case .active(let loc):
                            let x = loc.x - plot.minX
                            if x >= 0, x <= plot.width, let d: Date = proxy.value(atX: x) {
                                hover.point(at: d, in: series)
                            } else {
                                hover.date = nil
                            }
                        case .ended:
                            hover.date = nil
                        }
                    }
                if let d = hover.date, let x = proxy.position(forX: d) {
                    Rectangle().fill(Color.secondary.opacity(0.55))
                        .frame(width: 1, height: plot.height)
                        .offset(x: plot.minX + x, y: plot.minY)
                        .allowsHitTesting(false)
                    if let p = series.point(near: d), let v = dotY?(p), let y = proxy.position(forY: v) {
                        Circle().fill(dotColor)
                            .frame(width: 8, height: 8)
                            .offset(x: plot.minX + x - 4, y: plot.minY + y - 4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .coordinateSpace(name: "chartHover")
        }
    }
}

private extension View {
    func timeAxis(_ domain: ClosedRange<Date>, ticks: Int = 4) -> some View {
        // A label starts at its tick, so one near the right edge was cut
        // ("18:…"): a tick in the last 18 % (≈ a label's width at 400 pt) keeps
        // its line but not its label. (Ending it at the tick instead ran into
        // the one before.)
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let lateFrom = domain.lowerBound.addingTimeInterval(span * 0.82)
        return self
            .chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: ticks)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick().foregroundStyle(Color.secondary.opacity(0.3))
                    if let d = value.as(Date.self), d <= lateFrom {
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                    }
                }
            }
    }

    func valueAxis() -> some View {
        self.chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel()
            }
        }
    }
}

private func emptyOverlay(_ show: Bool, _ text: String) -> some View {
    Group {
        if show {
            Text(text).font(.callout).foregroundStyle(.secondary)
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - 1. Throughput

private struct ThroughputChart: View {
    let series: ChartSeries
    let bitrate: Double?
    let hover: ChartHover

    var body: some View {
        let need = (bitrate ?? 0) / 1e6
        // Spikes from bursty segment downloads can be 20× the bitrate; cap the
        // axis so the "needed" line stays readable and clip the bursts.
        let yMax = max(need * 3, series.maxAvg * 1.25, 1)
        let hp = hover.date.flatMap { series.point(near: $0) }
        ChartCard(title: "Throughput to Apple TV",
                  subtitle: "The 10-second average should stay above the dashed line. Short bursts then idle are normal while the TV buffer is full.",
                  readout: hp.map { "\(Fmt.time($0.date)) · \(Fmt.mbps($0.tx)) Mbit/s (avg \(Fmt.mbps($0.txAvg)))" }
                    ?? "avg \(Fmt.mbps(series.points.last?.txAvg)) Mbit/s",
                  height: 190) {
            LegendSwatch(kind: .area, color: SeriesColor.throughput, title: "per second")
            LegendSwatch(kind: .line, color: SeriesColor.throughput, title: "10 s average")
            if need > 0 { LegendSwatch(kind: .dashed, color: .secondary, title: "needed \(Fmt.mbps(need)) Mbit/s") }
        } content: {
            Plot(series: series, yMax: yMax, yLabel: "Mbit/s", ticks: 5, extra: [need],
                 dotY: { min($0.txAvg ?? 0, yMax) }, dotColor: SeriesColor.throughput, hover: hover) {
                ForEach(series.points) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("Mbit/s", min(p.tx ?? 0, yMax)))
                        .foregroundStyle(SeriesColor.throughput.opacity(0.22))
                        .interpolationMethod(.stepCenter)
                }
                ForEach(series.points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Mbit/s", min(p.txAvg ?? 0, yMax)), series: .value("Series", "avg"))
                        .foregroundStyle(SeriesColor.throughput)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if need > 0 {
                    RuleMark(y: .value("Needed", need))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }
            }
            .equatable()
            .overlay { emptyOverlay(series.points.isEmpty, "Waiting for data…") }
        }
    }
}

// MARK: - 2. Buffer

private struct BufferChart: View {
    let series: ChartSeries
    let hover: ChartHover

    var body: some View {
        let yMax = max(10, series.maxBuffer * 1.15)
        let hp = hover.date.flatMap { series.point(near: $0) }
        let hasBuffer = series.points.contains { $0.buffer != nil }
        ChartCard(title: "TV buffer ahead",
                  subtitle: "Seconds of video the Apple TV has loaded. At zero, playback stalls.",
                  readout: hp.map { "\(Fmt.time($0.date)) · \(Fmt.seconds($0.buffer))\($0.empty ? " · stalled" : "")" }
                    ?? Fmt.seconds(series.points.last?.buffer),
                  height: 150) {
            LegendSwatch(kind: .area, color: SeriesColor.buffer, title: "buffered")
            LegendSwatch(kind: .block, color: SeriesColor.incident, title: "stalled (\(series.stalls.count))")
        } content: {
            Plot(series: series, yMax: yMax, yLabel: "s", dotY: { $0.buffer }, dotColor: SeriesColor.buffer, hover: hover) {
                ForEach(series.stalls) { s in
                    RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end),
                                  yStart: .value("Low", 0), yEnd: .value("High", yMax))
                        .foregroundStyle(SeriesColor.incident.opacity(0.2))
                }
                ForEach(series.points) { p in
                    if let b = p.buffer {
                        AreaMark(x: .value("Time", p.date), y: .value("Seconds", b))
                            .foregroundStyle(LinearGradient(colors: [SeriesColor.buffer.opacity(0.35), SeriesColor.buffer.opacity(0.05)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.linear)
                    }
                }
                ForEach(series.points) { p in
                    if let b = p.buffer {
                        LineMark(x: .value("Time", p.date), y: .value("Seconds", b), series: .value("Series", "buffer"))
                            .foregroundStyle(SeriesColor.buffer)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .equatable()
            .overlay { emptyOverlay(!hasBuffer, "The Apple TV hasn’t reported yet") }
        }
    }
}

// MARK: - 3. RTT

private struct RTTChart: View {
    let series: ChartSeries
    var sparse = false
    let hover: ChartHover

    var body: some View {
        let yMax = max(20, series.maxRTT * 1.2)
        let hp = hover.date.flatMap { series.point(near: $0) }
        let timeouts = series.points.filter(\.rttTimeout)
        ChartCard(title: "Round trip to Apple TV",
                  subtitle: sparse ? "Latency sampled every 5 s (1 s while this window is open)." : "TCP connect time from this Mac. Spikes and timeouts mean Wi-Fi trouble.",
                  readout: hp.map { "\(Fmt.time($0.date)) · \($0.rttTimeout ? "timeout" : ($0.rtt.map { Fmt.ms($0) } ?? "not sampled"))" }
                    ?? (series.points.last { $0.rtt != nil || $0.rttTimeout }.map { $0.rttTimeout ? "timeout" : Fmt.ms($0.rtt) } ?? Fmt.dash),
                  height: 150) {
            LegendSwatch(kind: .line, color: SeriesColor.rtt, title: "RTT")
            LegendSwatch(kind: .cross, color: SeriesColor.incident, title: "timeout (\(timeouts.count))")
        } content: {
            Plot(series: series, yMax: yMax, yLabel: "ms", dotY: { $0.rtt }, dotColor: SeriesColor.rtt, hover: hover) {
                ForEach(series.points) { p in
                    if let r = p.rtt {
                        LineMark(x: .value("Time", p.date), y: .value("ms", r), series: .value("Run", p.rttRun))
                            .foregroundStyle(SeriesColor.rtt)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(timeouts) { p in
                    PointMark(x: .value("Time", p.date), y: .value("ms", yMax * 0.94))
                        .symbol(.cross)
                        .symbolSize(40)
                        .foregroundStyle(SeriesColor.incident)
                }
            }
            .equatable()
            .overlay { emptyOverlay(!series.hasRTTMeasurements, "No RTT measurements yet") }
        }
    }
}

// MARK: - 4. Prep headroom

private struct HeadroomChart: View {
    let series: ChartSeries
    let segmentDuration: Double
    let prepDone: Bool
    let hover: ChartHover

    var body: some View {
        let danger = segmentDuration * 2
        let yMax = max(danger * 3, series.maxHeadroom * 1.1)
        let hp = hover.date.flatMap { series.point(near: $0) }
        let has = series.points.contains { $0.headroom != nil }
        ChartCard(title: "Prep headroom",
                  subtitle: prepDone ? "Whole file is prepared — preparation can’t be the bottleneck." : "Prepared video ahead of what the TV is playing. Near the line, the encoder is too slow.",
                  readout: hp.map { "\(Fmt.time($0.date)) · \(Fmt.seconds($0.headroom))" } ?? Fmt.seconds(series.points.last?.headroom),
                  height: 140) {
            LegendSwatch(kind: .area, color: SeriesColor.headroom, title: "prepared − position")
            LegendSwatch(kind: .dashed, color: SeriesColor.incident, title: "danger (\(Int(danger)) s)")
        } content: {
            Plot(series: series, yMax: yMax, yLabel: "s", extra: [danger],
                 dotY: { $0.headroom.map { max(0, $0) } }, dotColor: SeriesColor.headroom, hover: hover) {
                ForEach(series.points) { p in
                    if let h = p.headroom {
                        AreaMark(x: .value("Time", p.date), y: .value("Seconds", max(0, h)))
                            .foregroundStyle(SeriesColor.headroom.opacity(0.22))
                        LineMark(x: .value("Time", p.date), y: .value("Seconds", max(0, h)), series: .value("Series", "headroom"))
                            .foregroundStyle(SeriesColor.headroom)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                RuleMark(y: .value("Danger", danger))
                    .foregroundStyle(SeriesColor.incident.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .equatable()
            .overlay { emptyOverlay(!has, "Starts when the TV reports its position") }
        }
    }
}

// MARK: - 5. ffmpeg speed

private struct SpeedChart: View {
    let series: ChartSeries
    let prepDone: Bool
    let hover: ChartHover

    var body: some View {
        let yMax = max(2, series.maxSpeed * 1.15)
        let hp = hover.date.flatMap { series.point(near: $0) }
        let has = series.points.contains { $0.speed != nil }
        ChartCard(title: "ffmpeg speed",
                  subtitle: "Media seconds prepared per second. Below 1× the stream can’t keep up.",
                  readout: hp.map { "\(Fmt.time($0.date)) · \(Fmt.speed($0.speed))" } ?? (prepDone ? "finished" : Fmt.speed(series.points.last?.speed)),
                  height: 140) {
            LegendSwatch(kind: .line, color: SeriesColor.speed, title: "speed")
            LegendSwatch(kind: .dashed, color: SeriesColor.incident, title: "1× realtime")
        } content: {
            Plot(series: series, yMax: yMax, yLabel: "× realtime", dotY: { $0.speed }, dotColor: SeriesColor.speed, hover: hover) {
                ForEach(series.points) { p in
                    if let s = p.speed {
                        LineMark(x: .value("Time", p.date), y: .value("×", s), series: .value("Series", "speed"))
                            .foregroundStyle(SeriesColor.speed)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                RuleMark(y: .value("Realtime", 1))
                    .foregroundStyle(SeriesColor.incident.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .equatable()
            .overlay { emptyOverlay(!has, prepDone ? "ffmpeg finished — the whole file is ready" : "ffmpeg not running") }
        }
    }
}
