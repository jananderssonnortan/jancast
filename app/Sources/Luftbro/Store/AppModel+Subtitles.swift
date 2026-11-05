import Foundation

/// Subtitle delay and stretch, and the text recognition (OCR) of picture subtitles.
///
/// A cue at t shows at t × scale + delay. The scale only comes from Sync
/// Automatically, for subtitles that drift (made for another frame rate);
/// the delay is the offset on top of it, which the Delay picker and H / J
/// move as always. "Use the File’s Timing" drops both.
extension AppModel {
    /// One press of H (earlier) or J (later), as in VLC on the Mac.
    static let subtitleDelayStep = 0.5
    /// The Delay submenu: half seconds near zero, whole seconds further out.
    static let subtitleDelayChoices: [Double] = [-5, -4, -3, -2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 3, 4, 5]
    /// The backend's limit.
    static let subtitleDelayLimit = 60.0
    /// H / J presses closer together than this are sent as one restart.
    static let subtitleDelaySettle = 0.8

    /// The backend's limit on the stretch.
    static let subtitleScaleLimit = 0.06

    /// Delay of the subtitles that are playing (from the backend).
    var sessionSubtitleDelay: Double { live?.session?.subtitle?.delay ?? 0 }

    /// Stretch of the subtitles that are playing (from the backend; 1 = none).
    var sessionSubtitleScale: Double { live?.session?.subtitle?.scale ?? 1 }

    /// The delay the menus and the tile show: in the player the one being
    /// applied (else the playing one), else Setup's.
    var shownSubtitleDelay: Double { showsPlayer ? (pendingSubtitleDelay ?? sessionSubtitleDelay) : subtitleDelay }

    /// The stretch the Delay submenu shows, picked the same way as the delay.
    var shownSubtitleScale: Double { showsPlayer ? (pendingSubtitleScale ?? sessionSubtitleScale) : subtitleScale }

    /// Subtitles are on where a delay would go (the player, else Setup).
    var subtitleDelayApplies: Bool {
        showsPlayer ? canControl && sessionSubtitleID != 0 : probe != nil && subtitleID != 0
    }

    /// H / J work: the remote (no PIN sheet; the key monitor leaves text
    /// fields, like the Events filter, alone) or the This Mac window has the keys.
    var subtitleDelayKeysApply: Bool {
        subtitleDelayApplies && pairingDeviceID == nil && (playerWindowIsKey || mainWindowIsKey)
    }

    /// From the Delay submenu: one restart mid-playback. A stretch stays.
    func setSubtitleDelay(_ value: Double) {
        setSubtitleTiming(delay: value, scale: shownSubtitleScale)
    }

    /// Delay and stretch together (Sync Automatically, "Use the File’s
    /// Timing"): one restart mid-playback.
    func setSubtitleTiming(delay: Double, scale: Double) {
        guard subtitleDelayApplies else { return }
        let new = Self.clampedDelay(delay), newScale = Self.clampedScale(scale)
        if showsPlayer {
            pendingSubtitleDelay = new
            pendingSubtitleScale = newScale
            subtitleDelayToken += 1
            applyPendingSubtitleDelay()
        } else {
            subtitleDelay = new
            subtitleScale = newScale
            if let path = probe?.path { Self.rememberSubtitleTiming(delay: new, scale: newScale, for: path) }
        }
    }

    /// The subtitles as the file times them: no stretch, no delay.
    func resetSubtitleTiming() {
        setSubtitleTiming(delay: 0, scale: 1)
    }

    /// H / J: the new value shows at once; mid-playback the stream restarts
    /// once the presses stop, so four presses are one restart, not four.
    func nudgeSubtitleDelay(by delta: Double) {
        guard subtitleDelayApplies else { return }
        let new = Self.clampedDelay(shownSubtitleDelay + delta)
        localPlayer.flash(delta < 0 ? "backward.end.alt" : "forward.end.alt",
                          "Subtitles " + SubtitleMenuContent.delayText(new))
        guard showsPlayer else {
            subtitleDelay = new
            if let path = probe?.path { Self.rememberSubtitleTiming(delay: new, scale: subtitleScale, for: path) }
            return
        }
        pendingSubtitleDelay = new
        subtitleDelayToken += 1
        let token = subtitleDelayToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.subtitleDelaySettle) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.subtitleDelayToken == token else { return }
                self.applyPendingSubtitleDelay()
            }
        }
    }

    /// Restart at the current position with the pending delay and stretch;
    /// they stay the shown values until the backend reports the new session
    /// (no flicker back to the old ones), unless newer presses have come since.
    private func applyPendingSubtitleDelay() {
        guard pendingSubtitleDelay != nil || pendingSubtitleScale != nil else { return }
        let value = pendingSubtitleDelay ?? sessionSubtitleDelay
        let scale = pendingSubtitleScale ?? sessionSubtitleScale
        guard canControl, value != sessionSubtitleDelay || scale != sessionSubtitleScale else {
            pendingSubtitleDelay = nil      // back where it was, or nothing to restart
            pendingSubtitleScale = nil
            return
        }
        if let path = live?.session?.file?.path { Self.rememberSubtitleTiming(delay: value, scale: scale, for: path) }
        let token = subtitleDelayToken
        switchTracks(subtitleDelay: value, subtitleScale: scale) { [weak self] in
            guard let self, self.subtitleDelayToken == token else { return }
            self.pendingSubtitleDelay = nil
            self.pendingSubtitleScale = nil
        }
    }

    private static func clampedDelay(_ d: Double) -> Double {
        max(-subtitleDelayLimit, min(subtitleDelayLimit, d.rounded(toPlaces: 1)))
    }

    private static func clampedScale(_ s: Double) -> Double {
        s.isFinite ? max(1 - subtitleScaleLimit, min(1 + subtitleScaleLimit, s)) : 1
    }

    // MARK: Remembered per file

    /// The delay (and stretch) last picked for each file, kept across
    /// launches. History only has it once a file has played; this also keeps
    /// one picked on the ready screen, and it beats the series' carried-over
    /// delay.
    private struct SavedDelay: Codable {
        var delay: Double
        var scale: Double?          // nil: no stretch
        var at: Date
    }

    private static let savedDelaysKey = "subtitleDelays"
    private static let savedDelaysLimit = 300

    private static var savedDelays: [String: SavedDelay] {
        get {
            guard let data = UserDefaults.standard.data(forKey: savedDelaysKey) else { return [:] }
            return (try? JSONDecoder().decode([String: SavedDelay].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: savedDelaysKey) }
    }

    static func rememberSubtitleTiming(delay d: Double, scale: Double, for path: String) {
        var all = savedDelays
        all[path] = SavedDelay(delay: d, scale: scale == 1 ? nil : scale, at: Date())
        if all.count > savedDelaysLimit {
            for (key, _) in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - savedDelaysLimit) {
                all[key] = nil
            }
        }
        savedDelays = all
    }

    static func savedSubtitleTiming(for path: String) -> (delay: Double, scale: Double)? {
        savedDelays[path].map { ($0.delay, $0.scale ?? 1) }
    }

    // MARK: Sync Automatically

    /// The subtitle track a delay would go to: the playing one in the player, else Setup's.
    private var subtitleToSync: SubtitleTrack? {
        showsPlayer ? sessionTracks?.subtitleTracks.first { $0.id == sessionSubtitleID } : selectedSubtitle
    }

    /// Sync Automatically can run: subtitles are on, they are text (or picture
    /// subtitles read as text; burned-in ones have no times to move).
    var subtitleSyncApplies: Bool {
        subtitleDelayApplies && subtitleToSync.map { !$0.burnsIn } == true
    }

    /// Measure where the subtitles fit the speech (the backend listens to a
    /// few minutes of the audio) and set the delay to it, and the stretch
    /// for subtitles that drift. The outcome is one
    /// quiet line: under the tiles on the ready screen, the status line in
    /// the player. Nothing changes when the backend isn't sure.
    func syncSubtitlesAutomatically() {
        guard subtitleSyncApplies, !subtitleSyncWorking, let sub = subtitleToSync else { return }
        let path = showsPlayer ? live?.session?.file?.path : probe?.path
        guard let path else { return }
        let audio = showsPlayer ? sessionAudioID : audioID
        let inPlayer = showsPlayer
        subtitleSyncWorking = true
        subtitleSyncToken += 1
        let token = subtitleSyncToken
        showSubtitleSyncNote(Self.syncingText, symbol: "waveform", inPlayer: inPlayer, seconds: 120)
        subtitleSyncTask?.cancel()
        subtitleSyncTask = Task { [weak self] in
            defer { self?.subtitleSyncWorking = false }
            while !Task.isCancelled {
                guard let self else { return }
                let status: SubtitleSyncStatus
                do {
                    status = try await backend.subtitleSync(path: path, subtitle: sub.id, audio: audio)
                } catch {
                    finishSubtitleSync(token: token, inPlayer: inPlayer,
                                       "Couldn’t sync the subtitles: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                    return
                }
                guard !Task.isCancelled, self.subtitleSyncToken == token else { return }
                if status.status == "working" {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                // Still the same subtitles on the same file: a track or file
                // picked meanwhile gets no delay or stretch meant for another.
                let stillHere = inPlayer
                    ? live?.session?.file?.path == path && sessionSubtitleID == sub.id
                    : probe?.path == path && subtitleID == sub.id
                guard stillHere else { dropSubtitleSyncNote(inPlayer: inPlayer); return }
                finishSubtitleSync(token: token, inPlayer: inPlayer, status)
                return
            }
        }
    }

    private static let syncingText = "Finding where the subtitles fit…"

    /// The "finding" line goes when the answer no longer applies.
    private func dropSubtitleSyncNote(inPlayer: Bool) {
        if inPlayer, statusHint?.text == Self.syncingText { statusHint = nil }
        subtitleSyncNote = nil
    }

    private func finishSubtitleSync(token: Int, inPlayer: Bool, _ status: SubtitleSyncStatus) {
        guard status.status == "done" else {
            finishSubtitleSync(token: token, inPlayer: inPlayer,
                               "Couldn’t sync the subtitles" + (status.note.map { ": \($0)" } ?? ""),
                               symbol: "exclamationmark.triangle")
            return
        }
        guard let offset = status.offset else {
            // A drift no stretch fits, or nothing stood out: said as the
            // backend puts it, nothing applied.
            finishSubtitleSync(token: token, inPlayer: inPlayer, status.note ?? "Couldn’t tell where the subtitles fit",
                               symbol: "captions.bubble")
            return
        }
        // The answer is measured on the file's own times, so it replaces any
        // stretch as well: a plain delay comes with none.
        let new = Self.clampedDelay(offset), scale = Self.clampedScale(status.scale ?? 1)
        let current = shownSubtitleDelay, currentScale = shownSubtitleScale
        var text: String
        if abs(new - current) < 0.05 && scale == currentScale {
            text = "Subtitles are already in sync"
        } else if scale != 1 {
            setSubtitleTiming(delay: new, scale: scale)
            text = "Subtitles " + SubtitleMenuContent.stretchText(scale).lowercased()
            if new != 0 { text += ", delay " + SubtitleMenuContent.delayText(new) }
        } else {
            setSubtitleTiming(delay: new, scale: 1)
            let moved = abs(new - current)
            text = moved < 0.05 ? "Subtitles no longer stretched"
                : String(format: "Subtitles moved %.1f s %@", moved, new > current ? "later" : "earlier")
            if new != 0 { text += " (delay " + SubtitleMenuContent.delayText(new) + ")" }
        }
        if status.method == "energy" { text += " · from loudness alone, less reliable" }
        finishSubtitleSync(token: token, inPlayer: inPlayer, text, symbol: "captions.bubble")
    }

    private func finishSubtitleSync(token: Int, inPlayer: Bool, _ text: String, symbol: String) {
        guard subtitleSyncToken == token else { return }
        showSubtitleSyncNote(text, symbol: symbol, inPlayer: inPlayer, seconds: 6)
    }

    /// One line, in place: the player's status line (its hint slot), or the
    /// ready screen's note under the tiles. Nothing else moves.
    private func showSubtitleSyncNote(_ text: String, symbol: String, inPlayer: Bool, seconds: Double) {
        if inPlayer {
            showStatusHint(text, symbol: symbol, seconds: seconds)
            return
        }
        subtitleSyncNote = StatusHint(text: text, symbol: symbol)
        let token = subtitleSyncToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.subtitleSyncToken == token else { return }
            self.subtitleSyncNote = nil
        }
    }

    // MARK: OCR

    /// Start (and follow) the OCR of the selected picture subtitle track, so it
    /// is usually done before Play is pressed.
    func followOCR() {
        ocrTask?.cancel()
        ocrStatus = nil
        guard let probe, let sub = selectedSubtitle, sub.viaOCR else { return }
        let path = probe.path, id = sub.id
        ocrTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = try? await self.backend.ocrStatus(path: path, subtitle: id)
                guard !Task.isCancelled, self.probe?.path == path, self.subtitleID == id else { return }
                self.ocrStatus = status
                if let s = status?.status, s != "working" { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10, Double(places))
        return (self * f).rounded() / f
    }
}
