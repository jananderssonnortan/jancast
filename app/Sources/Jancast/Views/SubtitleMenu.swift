import SwiftUI

/// The subtitle menu's content, shared by the ready view and the player:
/// the tracks (picture subtitles marked "shown as text" when they are read
/// with OCR) and the delay, in half-second steps.
struct SubtitleMenuContent: View {
    @Environment(AppModel.self) private var model
    let probe: ProbeResult
    /// In the player a change restarts the stream at the current position.
    let inPlayer: Bool

    var body: some View {
        let selected = inPlayer ? model.sessionSubtitleID : model.subtitleID
        Picker("Subtitles", selection: Binding(
            get: { selected },
            set: { id in
                if inPlayer { model.switchTracks(subtitle: id) } else { model.subtitleID = id }
            })) {
            Text("Off").tag(0)
            ForEach(probe.subtitleTracks) { t in
                Text(Self.title(t)).tag(t.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()

        Divider()
        let delay = model.shownSubtitleDelay
        Section("Delay: \(Self.delayText(delay))") {
            Button("Show Earlier (−0.5 s)") { model.changeSubtitleDelay(by: -AppModel.subtitleDelayStep) }
            Button("Show Later (+0.5 s)") { model.changeSubtitleDelay(by: AppModel.subtitleDelayStep) }
            Button("Reset Delay") { model.changeSubtitleDelay(by: nil) }
                .disabled(delay == 0)
        }
        .disabled(selected == 0)
    }

    static func title(_ t: SubtitleTrack) -> String {
        Fmt.trackTitle(t) + (t.burnsIn ? " · burned in, re-encodes video"
                             : t.viaOCR ? " · picture, shown as text" : "")
    }

    static func delayText(_ d: Double) -> String {
        d == 0 ? "none" : String(format: "%+.1f s", d)
    }

    /// Short suffix for a menu label, e.g. " · +0.5 s".
    static func labelSuffix(_ d: Double) -> String {
        d == 0 ? "" : " · " + String(format: "%+.1f s", d)
    }
}

/// One quiet line in the ready view while picture subtitles are read as text.
struct OCRNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.ocrStatus, model.selectedSubtitle?.viaOCR == true {
            HStack(spacing: 6) {
                switch s.status {
                case "working":
                    ProgressView(value: s.progress ?? 0).progressViewStyle(.linear).controlSize(.small).frame(width: 70)
                    Text("Reading the subtitles as text · \(Fmt.percent(s.progress))")
                case "ready":
                    Image(systemName: "text.viewfinder").foregroundStyle(.green)
                    Text("Picture subtitles read as text — no re-encode")
                case "failed", "unavailable":
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(s.error ?? "Couldn’t read the subtitles as text").lineLimit(2)
                default:
                    EmptyView()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
