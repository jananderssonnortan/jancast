import SwiftUI

/// The remote with a file loaded but not playing: the same layout as the
/// playing remote, with Resume / Play in place of the transport and the TV
/// picker in the pill. Nothing starts until Play is pressed.
struct ReadyRemote: View {
    @Environment(AppModel.self) private var model
    let probe: ProbeResult

    var body: some View {
        let resume = model.resumeEntry?.resumePosition
        let duration = max(1, probe.durationS ?? 1)
        // Poster: where playback will start, else a little way in (past black
        // opening frames).
        let posterAt: Double? = resume ?? duration * 0.1
        let showThumbs = model.thumbs.path == probe.path
        let audio = model.selectedAudio
        let converted = model.stereo || audio?.mode == "transcode"

        VStack(alignment: .leading, spacing: 18) {
            // The way back to what plays on the TV (the device is in the toolbar).
            if model.canControl, let file = model.live?.session?.file, let name = file.name {
                NowPlayingPill(name: name, nameInfo: file.nameInfo)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            NowCard(fileName: probe.displayName, nameInfo: probe.nameInfo,
                    poster: showThumbs ? posterAt.flatMap { model.thumbs.image(at: $0) } : nil,
                    detail: [Fmt.clock(probe.durationS), probe.video?.hdr == true ? "HDR" : nil].compactMap { $0 }
                        .joined(separator: " · "),
                    badges: FormatBadges.make(width: probe.video?.width, height: probe.video?.height,
                                              hdr: probe.video?.hdr == true, videoCodec: probe.video?.codec,
                                              reencode: model.willReencodeVideo,
                                              audioCodec: converted ? (model.stereo ? "aac" : "eac3") : audio?.codec,
                                              channels: model.stereo ? 2 : audio?.channels,
                                              subtitles: model.subtitleID != 0))

            VStack(spacing: 6) {
                // Click or drag to start playing right there.
                Filmstrip(duration: duration, position: resume ?? 0,
                          interactive: model.canPlay) { model.play(startPosition: $0) }
                HStack {
                    Text(resume.map { "Stopped at \(Fmt.clock($0))" } ?? "Not started")
                    if let at = model.resumeEntry?.updatedAt { Text("· " + Fmt.ago(at)) }
                    Spacer()
                    Text(Fmt.clock(probe.durationS))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(.top, 6)

            PlayButtons(resume: resume)
                .id(RemoteLayout.transportID)
                .frame(maxWidth: .infinity)

            ChoiceTiles(probe: probe)

            Notes(probe: probe)
            OCRNote()
            if let f = model.lastFailure, f.path == probe.path {
                // The failure stays in view after "Done", until the next Play.
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Playback failed\(f.position.map { " at \(Fmt.clock($0))" } ?? "") — \(f.message)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(f.message)
                    Button("Details") { model.showDiagnostics(.overview) }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if let finished = model.upNextAfter {
                Label("Up next after \(finished)", systemImage: "play.square.stack")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.runDeviceProbeLoop() }
    }
}

// MARK: - Device picker

/// The Apple TV to play on, as a toolbar menu with a reachability dot.
struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.selectedDevice
        HStack(spacing: 7) {
            Menu {
                Picker("Apple TV", selection: Binding(get: { model.selectedDeviceID ?? "" }, set: { model.selectDevice($0) })) {
                    ForEach(model.devices) { d in Text(deviceTitle(d)).tag(d.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if model.devices.isEmpty {
                    Text(model.scanning ? "Looking for Apple TVs…" : "No Apple TVs found")
                }
                Divider()
                Button("Scan for Apple TVs") { Task { await model.loadDevices(.refresh) } }
                    .disabled(model.scanning)
            } label: {
                Label(d?.displayName ?? (model.scanning ? "Looking…" : "Choose Apple TV"), systemImage: "airplayvideo")
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
            StatusDot(color: dotColor(d))
        }
        .help(d.map(hint) ?? "The Apple TV to play on")
    }

    private func dotColor(_ d: Device?) -> Color {
        switch d?.reachability {
        case .online?: return d?.needsPairing == true ? .yellow : .green
        case .notResponding?: return .yellow
        default: return Color.secondary.opacity(0.5)
        }
    }

    private func hint(_ d: Device) -> String {
        switch d.reachability {
        case .online: return d.needsPairing ? "Needs pairing — you’ll be asked for the code shown on the TV" : "Online" + (d.rttMs.map { " · \(Fmt.ms($0))" } ?? "")
        case .notResponding: return "Not responding; Play will try to wake it"
        case .offline: return "Offline"
        }
    }

    private func deviceTitle(_ d: Device) -> String {
        var s = d.displayName
        switch d.reachability {
        case .online: s += d.rttMs.map { " — online · \(Fmt.ms($0))" } ?? " — online"
        case .notResponding: s += " — not responding"
        case .offline: s += " — offline"
        }
        if d.needsPairing { s += " · needs pairing" }
        return s
    }
}

// MARK: - Play buttons

/// One primary action: Resume (or Play), Start Over beside it.
private struct PlayButtons: View {
    @Environment(AppModel.self) private var model
    let resume: Double?

    var body: some View {
        let pair = model.selectedDevice?.needsPairing == true
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let resume {
                    Button("Start Over") { model.play() }
                        .controlSize(.large)
                        .help("Play from the beginning")
                    primary("\(pair ? "Pair & Resume" : "Resume") \(Fmt.clock(resume))") { model.play(startPosition: resume) }
                        .help("Continue where you left off (⌘↩)")
                } else {
                    primary(pair ? "Pair & Play" : "Play") { model.play() }
                        .help("Start streaming (⌘↩)")
                }
            }
            .disabled(!model.canPlay)
            .frame(minHeight: 76)
            if let hint = deviceHint {
                Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if model.startingPlayback { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                Text(title)
            }
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 140, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    /// Only when something about the TV needs saying.
    private var deviceHint: String? {
        guard let d = model.selectedDevice else {
            return model.scanning ? "Looking for Apple TVs…" : "Choose an Apple TV in the pill above."
        }
        switch d.reachability {
        case .offline: return "\(d.displayName) is offline — choose another Apple TV, or switch it on and scan."
        case .notResponding: return "\(d.displayName) isn’t responding; Play will try to wake it."
        case .online: return nil
        }
    }
}

// MARK: - Track tiles

private struct ChoiceTiles: View {
    @Environment(AppModel.self) private var model
    let probe: ProbeResult

    var body: some View {
        @Bindable var model = model
        let audio = model.selectedAudio
        let subtitle = model.selectedSubtitle
        HStack(spacing: 8) {
            MenuTile(caption: "AUDIO",
                     value: audio.map { TrackLabel.audio($0, in: probe.audioTracks, stereo: model.stereo) } ?? "Audio") {
                Picker("Audio", selection: $model.audioID) {
                    ForEach(probe.audioTracks) { t in Text(Fmt.trackTitle(t) + (t.mode == "transcode" ? " · converted" : "")).tag(t.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Toggle("Downmix to Stereo", isOn: $model.stereo)
            }
            .help(audio.map { Fmt.trackTitle($0) + (model.stereo ? " · stereo downmix" : "") } ?? "Audio track")
            MenuTile(caption: "SUBTITLES",
                     value: subtitle.map { TrackLabel.subtitle($0, in: probe.subtitleTracks)
                         + SubtitleMenuContent.labelSuffix(model.subtitleDelay) } ?? "Off") {
                SubtitleMenuContent(probe: probe, inPlayer: false)
            }
            .help(subtitle.map(Fmt.trackTitle) ?? "Subtitles off")
        }
    }
}

// MARK: - Notes

/// One quiet line, only when the choices cost something (re-encoding,
/// converted audio); the full explanation is behind the info button.
private struct Notes: View {
    @Environment(AppModel.self) private var model
    let probe: ProbeResult
    @State private var showDetails = false

    var body: some View {
        if let note {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: note.symbol).foregroundStyle(note.tint)
                    Text(note.title)
                    Image(systemName: "info.circle").foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                Text(note.details)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(width: 360)
            }
        }
    }

    private var note: (symbol: String, tint: Color, title: String, details: String)? {
        if probe.video?.mode == "reencode" {
            return ("cpu", .orange, "Video will be re-encoded",
                    "\(probe.video?.reason ?? "The video format isn’t supported by Apple TV"). Your Mac converts the picture while streaming: heavy CPU use and slightly lower quality. If it can’t encode faster than realtime, playback pauses to wait for it — Diagnostics shows this as “Preparation / encoder”.")
        }
        if let s = model.selectedSubtitle, s.burnsIn {
            return ("cpu", .orange, "Subtitles are burned in — video will be re-encoded",
                    "\(Fmt.codec(s.codec)) subtitles are pictures, not text, so they are painted into the video. That means re-encoding the whole picture: heavy CPU use and slightly lower quality. Pick a text track (SRT/ASS) if there is one.")
        }
        if model.stereo {
            return ("arrow.triangle.2.circlepath", .secondary, "Audio mixed down to stereo",
                    "Converted to 2-channel AAC while streaming (light CPU use). Video is passed through untouched.")
        }
        if let a = model.selectedAudio, a.mode == "transcode" {
            return ("arrow.triangle.2.circlepath", .secondary, "Audio is converted",
                    "Apple TV can’t play \(Fmt.codec(a.codec)) directly, so it is converted while streaming (light CPU use). Video is passed through untouched.")
        }
        return nil
    }
}

/// Shown while another file is playing on the TV: the way back to it.
private struct NowPlayingPill: View {
    @Environment(AppModel.self) private var model
    let name: String
    let nameInfo: NameInfo?

    var body: some View {
        Button { model.playerVisible = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.tv.fill").foregroundStyle(Color.accentColor)
                Text(Fmt.name(name, nameInfo).title).lineLimit(1)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
            }
            .font(.callout)
            .modifier(PillBackground())
        }
        .buttonStyle(.plain)
        .help("Now playing — back to the player")
    }
}
