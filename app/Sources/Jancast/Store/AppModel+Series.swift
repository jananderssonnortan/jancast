import Foundation

/// Audio, subtitles and subtitle delay remembered per series: an episode
/// without choices of its own (never played, or not part-way with tracks)
/// starts with what the show's last episode used, matched to this file's
/// tracks the way Up Next carries them over (same language, then title and
/// codec; forced and picture subtitles kept apart).
extension AppModel {
    struct SeriesChoice: Codable {
        var audio: AudioTrack?
        var subtitle: SubtitleTrack?     // nil: off, or a track no longer known
        var subtitleOff: Bool            // turned off although the file offered a default
        var stereo: Bool
        var subtitleDelay: Double
    }

    private static let seriesChoicesKey = "seriesChoices"

    /// "night train" for every episode of Night Train; nil for films.
    static func seriesKey(_ p: ProbeResult) -> String? {
        guard p.nameInfo?.kind == "episode",
              let show = p.nameInfo?.show?.trimmingCharacters(in: .whitespaces).lowercased(), !show.isEmpty
        else { return nil }
        return show
    }

    private static var seriesChoices: [String: SeriesChoice] {
        get {
            guard let data = UserDefaults.standard.data(forKey: seriesChoicesKey) else { return [:] }
            return (try? JSONDecoder().decode([String: SeriesChoice].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: seriesChoicesKey) }
    }

    /// At Play and at every track change while an episode plays.
    func rememberSeriesChoices(_ p: ProbeResult?, audio: Int?, subtitle: Int, stereo: Bool, delay: Double) {
        guard let p, let key = Self.seriesKey(p) else { return }
        Self.seriesChoices[key] = SeriesChoice(
            audio: p.audioTracks.first { $0.id == audio },
            subtitle: subtitle == 0 ? nil : p.subtitleTracks.first { $0.id == subtitle },
            subtitleOff: subtitle == 0 && (p.defaultSubtitle ?? 0) != 0,
            stereo: stereo,
            subtitleDelay: subtitle == 0 ? 0 : delay)
    }

    /// When an episode is opened without choices of its own.
    func applySeriesChoices(to p: ProbeResult) {
        guard let key = Self.seriesKey(p), let c = Self.seriesChoices[key] else { return }
        (audioID, subtitleID) = Self.carryOver(audio: c.audio, subtitle: c.subtitle, keepOff: c.subtitleOff, to: p)
        stereo = c.stereo
        subtitleDelay = subtitleID == 0 ? 0 : c.subtitleDelay
    }

    /// A history entry with choices of its own: left part-way, with tracks.
    static func hasOwnChoices(_ h: HistoryEntry?) -> Bool {
        h.map { $0.audio != nil && $0.resumePosition != nil } ?? false
    }
}
