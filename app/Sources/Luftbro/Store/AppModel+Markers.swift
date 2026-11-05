import AppKit

/// Skip Intro and Next Episode, as on the streaming services: where the file's chapters say
/// the intro or the end credits are, the remote (and the This Mac picture)
/// offer a button. Space runs it during its first seconds, ⏭ (media key,
/// Control Center) any time it shows.
enum PlaybackMarker: Equatable {
    case intro(end: Double)
    case credits
}

extension AppModel {
    /// How long Space runs the button after it appears; then it pauses again.
    static let markerSpaceSeconds: TimeInterval = 10

    /// The intro or credits the playhead is in, when there is something to do.
    var activeMarker: PlaybackMarker? {
        guard canControl, !isStarting, let p = displayPosition, let m = sessionMarkers else { return nil }
        // Not in the intro's last seconds: the skip would barely move.
        if let i = m.intro, let end = i.end, p >= i.start, p < end - 3 { return .intro(end: end) }
        // Whenever the remote offers Up Next: from the credits when the file
        // says where they are, else the last 2½ minutes. The This Mac picture,
        // Space and ⏭ then always agree with the remote.
        if showUpNextCard { return .credits }
        return nil
    }

    /// The playhead is past the start of the end credits.
    var inCredits: Bool {
        guard let start = sessionMarkers?.credits?.start, let p = displayPosition else { return false }
        return p >= start
    }

    /// The playing file's markers: its chapters, filled in with what the
    /// backend found by comparing it with a neighbouring episode.
    var sessionMarkers: Markers? {
        markers(for: live?.session?.file?.path, chapters: sessionTracks?.markers)
    }

    /// A file's chapters, filled in with what was found for it (detection
    /// runs while a file plays; the ready screen shows what is known so far).
    func markers(for path: String?, chapters: Markers?) -> Markers? {
        guard let path, let found = detectedMarkers[path] else { return chapters }
        return Markers(intro: chapters?.intro ?? found.intro, credits: chapters?.credits ?? found.credits)
    }

    /// While an episode without intro or credits chapters plays: ask the
    /// backend (credits from the picture, the intro by its sound) until it answers.
    func followDetectedMarkers() {
        // Films and lone files: the backend answers "unavailable" at once.
        guard canControl, let path = live?.session?.file?.path, sessionTracks?.path == path,
              sessionTracks?.markers?.credits == nil || sessionTracks?.markers?.intro == nil,
              detectedMarkers[path] == nil,
              markersPollingPath != path else { return }
        markersPollingPath = path
        markersTask?.cancel()
        markersTask = Task { [weak self] in
            var delay: UInt64 = 2_000_000_000
            while !Task.isCancelled {
                guard let self else { return }
                if let r = try? await self.backend.markers(path: path), r.status != "working" {
                    self.detectedMarkers[path] = Markers(intro: r.intro, credits: r.credits)
                    return
                }
                guard self.live?.session?.file?.path == path else { break }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 15_000_000_000)
            }
            if self?.markersPollingPath == path { self?.markersPollingPath = nil }
        }
    }

    /// Skip the intro, or play the next episode.
    func runMarker() {
        // Twice in a row (⏭ ⏭, a double click): once. Next Episode loads for a moment.
        guard Date().timeIntervalSince(markerRanAt) >= 2 else { return }
        switch activeMarker {
        case .intro(let end):
            seek(to: end)
            // Said on the remote too: on a TV the jump is easy to miss.
            localPlayer.flash("forward.end.fill", "Intro skipped")
            showStatusHint("Intro skipped", symbol: "forward.end.fill", seconds: 2.5)
            Self.announce("Intro skipped")
        case .credits:
            playNext()
        case nil:
            break
        }
        markerTakesSpace = false
        markerRanAt = Date()
    }

    /// After each state update: a marker that just appeared takes Space for a while.
    func followMarker() {
        followDetectedMarkers()
        let now = activeMarker
        guard now != shownMarker else { return }
        shownMarker = now
        markerSpaceToken += 1
        markerTakesSpace = now != nil
        localPlayer.setMarkerShown(now != nil)
        guard let now else { return }
        // VoiceOver: the button appears without focus moving there.
        Self.announce(now == .credits ? "Next episode available. Press Space to play it."
                                      : "Intro. Press Space to skip it.")
        let token = markerSpaceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.markerSpaceSeconds) { [weak self] in
            guard let self, self.markerSpaceToken == token else { return }
            self.markerTakesSpace = false
        }
    }

    /// A VoiceOver announcement (nothing happens without VoiceOver).
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Space where it plays or pauses the session: the new marker's button instead.
    func spaceRunsMarker() -> Bool {
        // A second press right after (Space, Space) must not pause the episode
        // that is ending or the next one starting.
        if Date().timeIntervalSince(markerRanAt) < 2 { return true }
        guard markerTakesSpace, activeMarker != nil else { return false }
        runMarker()
        return true
    }
}
