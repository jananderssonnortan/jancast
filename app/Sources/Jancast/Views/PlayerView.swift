import SwiftUI

/// The remote while a stream runs: what is on (poster, title, format badges,
/// status), the filmstrip timeline, big transport buttons, audio/subtitle
/// tiles and — near the end of an episode — Up Next. The TV pill at the top
/// carries the health dot; the only hint of trouble besides it is the inline
/// headline when things actually fail.
struct PlayingRemote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live
        let session = live?.session
        let pb = live?.playback
        let duration = max(1, session?.file?.durationS ?? pb?.duration ?? 1)
        let position = model.displayPosition ?? 0
        // Poster: where this session started (a resume point), else 10 % in.
        let start = session?.startPosition ?? 0
        let posterAt: Double? = start > 0 ? start : duration * 0.1
        let tracks = model.sessionTracks
        let subtitle = tracks?.subtitleTracks.first { $0.id == model.sessionSubtitleID }
        let audio = session?.audio

        VStack(alignment: .leading, spacing: 18) {
            NowCard(fileName: session?.file?.name ?? model.probe?.displayName ?? "Untitled",
                    nameInfo: session?.file?.name != nil ? session?.file?.nameInfo : model.probe?.nameInfo,
                    poster: posterAt.flatMap { model.thumbs.image(at: $0) },
                    detail: Fmt.clock(session?.file?.durationS),
                    badges: FormatBadges.make(width: session?.video?.width, height: session?.video?.height,
                                              hdr: tracks?.video?.hdr == true, videoCodec: session?.video?.codec,
                                              reencode: session?.video?.mode == "reencode",
                                              // Downmixed: the TV gets stereo, whatever the track has.
                                              audioCodec: audio?.outCodec ?? (model.sessionStereo ? "aac" : audio?.codec),
                                              channels: model.sessionStereo ? 2 : audio?.channels,
                                              subtitles: subtitle != nil))

            VStack(spacing: 6) {
                Filmstrip(duration: duration, position: position,
                          buffered: min(duration, (pb?.position ?? 0) + (pb?.bufferedAheadS ?? 0)),
                          prepared: min(duration, live?.prep?.preparedS ?? 0),
                          interactive: model.canControl) { model.seek(to: $0) }
                    .zIndex(1)
                HStack {
                    Text(Fmt.clock(position)).monospacedDigit()
                    Spacer()
                    StatusLine()
                    Spacer()
                    Text("−" + Fmt.clock(max(0, duration - position))).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 6)

            Transport()
                .frame(maxWidth: .infinity)
                .id(RemoteLayout.transportID)

            TrackTiles()

            if model.showUpNextCard, let next = model.upNext {
                UpNextRow(next: next)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.phase == .failed {
                FailureCard()
            } else if model.phase == .finished || model.phase == .stopped {
                Button("Close Player") { model.playerVisible = false }
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(duration: 0.35), value: model.showUpNextCard)
    }
}

// MARK: - Status

/// Phase in plain words — only when not simply playing.
struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live
        let name = live?.session?.device?.name ?? "Apple TV"
        let status = DiagStatus(live?.diagnosis?.status)
        let failingNow = (status == .failing || status == .failed) && model.phase != .failed
        Group {
            if let hint = model.volumeHint {
                Label(hint, systemImage: "speaker.wave.2.fill")      // brief, after ⌘↑ / ⌘↓
            } else if failingNow, let h = live?.diagnosis?.headline {
                // Real trouble is said inline, not hidden in a popover.
                Label(h, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(status == .failed ? Color.red : .orange)
            } else {
                switch model.phase {
                case .preparing:
                    Text(live?.prep?.stage == "subtitles"
                         ? "Reading subtitles as text… \(Fmt.percent(live?.prep?.progress))"
                         : "Preparing… \(Fmt.percent(live?.prep?.progress))")
                case .connecting: Text("Connecting to \(name)…")
                case .pairing: Text("Waiting for the pairing code…")
                case .paused: Text("Paused")
                case .finished: Text("Finished")
                case .stopped: Text("Stopped")
                case .failed:
                    Text("Failed").foregroundStyle(.red)    // the card below says why
                case .playing:
                    if model.prepInProgress { PrepProgress() } else { Text(" ") }
                case .buffering, .stalled:
                    PrepProgress()
                case .idle, .unknown:
                    Text(" ")
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// When playback failed: what went wrong, and the ways forward.
private struct FailureCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.live?.diagnosis?.headline ?? "Playback failed", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text(model.failureReason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(model.failureReason)
            HStack {
                Button("Try Again") { model.retryPlayback() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.startingPlayback)
                Button("Show Diagnostics") { model.showDiagnostics(.overview) }
                Spacer()
                Button("Done") { model.playerVisible = false }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.red.opacity(0.3)))
    }
}

/// Playback starts before the whole file is prepared; this shows the rest
/// being prepared (remux or re-encode) until it is done.
private struct PrepProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let prep = model.live?.prep
        let phase = model.phase
        if model.prepInProgress, let progress = prep?.progress {
            HStack(spacing: 6) {
                if phase == .buffering || phase == .stalled {
                    Text(phase == .stalled ? "Waiting —" : "Buffering —")
                }
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 60)
                Text("Preparing · \(Fmt.percent(progress))").monospacedDigit()
            }
            .help(prep?.speed.map { "ffmpeg is preparing the rest of the stream at \(Fmt.speed($0)) realtime; ready to \(Fmt.clock(prep?.preparedS))." } ?? "")
        } else if phase == .buffering {
            Text("Buffering…")
        } else if phase == .stalled {
            Text("Playback stalled")
        }
    }
}

// MARK: - Transport

private struct Transport: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Before the first picture the big button is a spinner, not "pause"
        // (the status line says what is happening); after a failure it retries.
        let starting = model.isStarting
        let failed = model.phase == .failed
        let canSkip = model.canControl && !starting
        // Symmetric: Stop and TV volume, small, at the two ends.
        HStack(spacing: 22) {
            Button { model.stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(RoundButtonStyle(size: 34))
                .help("Stop (⌘.)")
                .accessibilityLabel("Stop")
                .disabled(!model.canControl)
                .opacity(model.canControl ? 1 : 0.5)
            Button { model.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(RoundButtonStyle(size: 56))
                .help("Back 10 seconds (←)")
                .accessibilityLabel("Back 10 seconds")
                .disabled(!canSkip)
                .opacity(canSkip ? 1 : 0.5)
            Group {
                if starting {
                    Button {} label: { ProgressView().controlSize(.regular) }
                        .buttonStyle(RoundButtonStyle(size: 76))
                        .disabled(true)
                        .accessibilityLabel("Starting")
                } else if failed {
                    Button { model.retryPlayback() } label: { Image(systemName: "play.fill") }
                        .buttonStyle(RoundButtonStyle(size: 76, prominent: true))
                        .help("Try again")
                        .accessibilityLabel("Try again")
                        .disabled(model.startingPlayback)
                } else {
                    Button { model.togglePause() } label: {
                        Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(RoundButtonStyle(size: 76, prominent: true))
                    .help(model.isPaused ? "Resume (Space)" : "Pause (Space)")
                    .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
                    .disabled(!model.canControl)
                    .opacity(model.canControl ? 1 : 0.5)
                }
            }
            Button { model.skip(30) } label: { Image(systemName: "goforward.30") }
                .buttonStyle(RoundButtonStyle(size: 56))
                .help("Forward 30 seconds (⌘→)")
                .accessibilityLabel("Forward 30 seconds")
                .disabled(!canSkip)
                .opacity(canSkip ? 1 : 0.5)
            VolumeButton()
        }
    }
}

/// TV volume: − / + in a small popover (also ⌘↑ / ⌘↓).
private struct VolumeButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let usable = model.canControl && model.playsOnAppleTV
        // On This Mac it stays clickable but dimmed: a click says why (the
        // same hint as ⌘↑ / ⌘↓) instead of doing nothing.
        Button {
            if model.playsOnAppleTV { open.toggle() } else { model.changeTVVolume(up: true) }
        } label: { Image(systemName: "speaker.wave.2.fill") }
            .buttonStyle(RoundButtonStyle(size: 34))
            .help(model.playsOnAppleTV ? "TV volume (⌘↑ / ⌘↓)" : "This Mac uses the Mac’s volume")
            .accessibilityLabel("TV volume")
            .disabled(!model.canControl)
            .opacity(usable ? 1 : 0.5)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                HStack(spacing: 12) {
                    Button { model.changeTVVolume(up: false) } label: { Image(systemName: "speaker.minus.fill") }
                        .buttonStyle(RoundButtonStyle(size: 40))
                        .accessibilityLabel("Volume down")
                    Button { model.changeTVVolume(up: true) } label: { Image(systemName: "speaker.plus.fill") }
                        .buttonStyle(RoundButtonStyle(size: 40))
                        .accessibilityLabel("Volume up")
                }
                .padding(12)
                .environment(model)
            }
    }
}

// MARK: - Tracks

/// Audio and subtitles as two tiles; changing one restarts the stream at the
/// current position.
private struct TrackTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let probe = model.sessionTracks
        let disabled = probe == nil || (!model.canControl && model.phase != .failed)
        HStack(spacing: 8) {
            MenuTile(caption: "AUDIO", value: audioValue) {
                if let probe {
                    Picker("Audio", selection: Binding(get: { model.sessionAudioID ?? -1 }, set: { model.switchTracks(audio: $0) })) {
                        ForEach(probe.audioTracks) { t in Text(Fmt.trackTitle(t)).tag(t.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Toggle("Downmix to Stereo", isOn: Binding(get: { model.sessionStereo }, set: { model.switchTracks(stereo: $0) }))
                }
            }
            .help(model.currentAudioTitle + " — click to change; playback restarts at the current position")
            MenuTile(caption: "SUBTITLES", value: subtitleValue) {
                if let probe {
                    SubtitleMenuContent(probe: probe, inPlayer: true)
                }
            }
            .help((model.sessionSubtitleID == 0 ? "Off" : model.currentSubtitleTitle)
                  + " — click to change; playback restarts at the current position")
        }
        .disabled(disabled)
    }

    private var audioValue: String {
        let tracks = model.sessionTracks?.audioTracks ?? []
        guard let id = model.sessionAudioID, let t = tracks.first(where: { $0.id == id }) else { return model.currentAudioTitle }
        return TrackLabel.audio(t, in: tracks, stereo: model.sessionStereo)
    }

    /// "Off" as on the ready screen.
    private var subtitleValue: String {
        let id = model.sessionSubtitleID
        guard id != 0 else { return "Off" }
        let tracks = model.sessionTracks?.subtitleTracks ?? []
        let name = tracks.first { $0.id == id }.map { TrackLabel.subtitle($0, in: tracks) } ?? model.currentSubtitleTitle
        return name + SubtitleMenuContent.labelSuffix(model.sessionSubtitleDelay)
    }
}

// MARK: - Up next

/// Offered during the last minutes of an episode. Never starts by itself.
private struct UpNextRow: View {
    @Environment(AppModel.self) private var model
    let next: NextEpisode
    @State private var poster: NSImage?

    var body: some View {
        let name = Fmt.name(next.displayName, next.nameInfo)
        HStack(spacing: 12) {
            PosterTile(image: poster, fileName: next.displayName, nameInfo: next.nameInfo, radius: 6)
            // Show and episode on their own lines: on one line beside the
            // buttons the narrow window cut it to "Night Train S…".
            VStack(alignment: .leading, spacing: 1) {
                Text("UP NEXT").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(name.headline)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let episode = name.episode {
                    Text(episode).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(name.title)
            Spacer(minLength: 4)
            Button("Not Now") { model.upNextDismissedFor = model.live?.session?.id }
                .buttonStyle(.borderless)
            Button { model.playNext() } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(model.startingPlayback)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
        .task(id: next.path) {
            let entry = model.recents.first { $0.path == next.path }
            poster = await Thumbnails.poster(path: next.path, at: entry?.resumePosition, backend: model.backend)
        }
    }
}

// MARK: - Health pill

