import Foundation

/// A file's name as shown: "Night Train" + "S6 · E3", or "Quiet Hours (2025)".
struct MediaName: Equatable {
    var headline: String          // show name, or the film's title (with year)
    var episode: String?          // "S6 · E3", "S1 · E2–3", "E12", "2024-03-15"; nil for films
    var episodeLong: String?      // "Season 6 · Episode 3"
    var episodeTitle: String?     // "'90 - Autumn"
    var title: String             // one line: "Night Train S6 · E3"
}

enum Fmt {
    static let dash = "—"

    /// "12.8" (Mbit/s number only)
    static func mbitValue(_ bps: Double?) -> String {
        guard let bps else { return dash }
        let m = bps / 1_000_000
        if m >= 100 { return String(format: "%.0f", m) }
        return String(format: "%.1f", m)
    }

    static func mbit(_ bps: Double?) -> String {
        guard bps != nil else { return dash }
        return "\(mbitValue(bps)) Mbit/s"
    }

    static func mbps(_ mbps: Double?) -> String {
        guard let mbps else { return dash }
        return mbps >= 100 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
    }

    /// Short human duration: "4.2 s", "54 s", "12 min", "1 h 05 min"
    static func seconds(_ s: Double?) -> String {
        guard let s, s.isFinite else { return dash }
        if s < 10 { return String(format: "%.1f s", s) }
        if s < 120 { return String(format: "%.0f s", s) }
        if s < 3600 { return String(format: "%.0f min", s / 60) }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return String(format: "%d h %02d min", h, m)
    }

    /// Value + unit split for KPI tiles.
    static func secondsParts(_ s: Double?) -> (String, String) {
        guard let s, s.isFinite else { return (dash, "") }
        if s < 10 { return (String(format: "%.1f", s), "s") }
        if s < 120 { return (String(format: "%.0f", s), "s") }
        if s < 3600 { return (String(format: "%.0f", s / 60), "min") }
        return (String(format: "%.1f", s / 3600), "h")
    }

    /// Media clock: "12:03" or "1:02:03"
    static func clock(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "--:--" }
        let t = Int(s.rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "just now", "5 min ago", "2 h ago", "3 days ago"
    static func ago(_ t: Double, now: Double = Date().timeIntervalSince1970) -> String {
        let d = max(0, now - t)
        if d < 60 { return "just now" }
        if d < 3600 { return "\(Int(d / 60)) min ago" }
        if d < 86400 { return "\(Int(d / 3600)) h ago" }
        let days = Int(d / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// "10 s", "1 min 30 s"
    static func skipAmount(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        return t % 60 == 0 ? "\(t / 60) min" : "\(t / 60) min \(t % 60) s"
    }

    static func bytes(_ b: Double?) -> String {
        guard let b else { return dash }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    static func ms(_ v: Double?) -> String {
        guard let v else { return dash }
        if v < 10 { return String(format: "%.1f ms", v) }
        return String(format: "%.0f ms", v)
    }

    static func speed(_ x: Double?) -> String {
        guard let x else { return dash }
        if x >= 10 { return String(format: "%.0f×", x) }
        return String(format: "%.2f×", x)
    }

    static func ratio(_ x: Double?) -> String {
        guard let x else { return dash }
        if x >= 10 { return String(format: "%.0f×", x) }
        return String(format: "%.1f×", x)
    }

    static func percent(_ x: Double?) -> String {
        guard let x else { return dash }
        return String(format: "%.0f%%", x * 100)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let timeMsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func time(_ t: Double) -> String { timeFormatter.string(from: Date(timeIntervalSince1970: t)) }
    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }
    static func timeMs(_ t: Double) -> String { timeMsFormatter.string(from: Date(timeIntervalSince1970: t)) }

    static func resolution(_ w: Int?, _ h: Int?) -> String? {
        guard let w, let h else { return nil }
        return "\(w)×\(h)"
    }

    static func codec(_ c: String?) -> String {
        guard let c else { return dash }
        switch c.lowercased() {
        case "h264": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "aac": return "AAC"
        case "truehd": return "TrueHD"
        case "dts": return "DTS"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "subrip": return "SRT"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "ass", "ssa": return "ASS"
        case "webvtt": return "WebVTT"
        default: return c.uppercased()
        }
    }

    static func channels(_ n: Int?) -> String? {
        guard let n else { return nil }
        switch n {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n) ch"
        }
    }

    /// How a file is named on screen: from the backend's `name_info` when it
    /// is there, else parsed here from the file name (mock mode, older backends).
    static func name(_ fileName: String, _ info: NameInfo?) -> MediaName {
        if let info, let title = info.title, !title.isEmpty {
            guard info.kind == "episode" else {
                return MediaName(headline: title, episode: nil, episodeLong: nil, episodeTitle: nil, title: title)
            }
            // "2" or "2–3" (multi-episode file); nil for a daily show (dated, not numbered).
            let number = info.episode.map { e in info.episodeEnd.map { "\(e)–\($0)" } ?? "\(e)" }
            let short = number.map { n in info.season.map { "S\($0) · E\(n)" } ?? "E\(n)" } ?? info.episodeTitle
            let long = number.map { n in info.season.map { "Season \($0) · Episode \(n)" } ?? "Episode \(n)" }
                ?? info.episodeTitle
            return MediaName(headline: info.show ?? title, episode: short, episodeLong: long,
                             episodeTitle: number == nil ? nil : info.episodeTitle, title: title)
        }
        if let ep = episode(fileName) {
            return MediaName(headline: ep.show, episode: "S\(ep.season) · E\(ep.episode)",
                             episodeLong: "Season \(ep.season) · Episode \(ep.episode)", episodeTitle: nil,
                             title: title(fileName))
        }
        let t = cleanTitle(fileName)
        return MediaName(headline: t, episode: nil, episodeLong: nil, episodeTitle: nil, title: t)
    }

    // Fallbacks for when there is no `name_info`:
    /// "Night.Train.S01E03.1080p.WEB-DL.x264-GRP.mkv" → "Night Train S01E03"
    /// "Some.Movie.2019.2160p.BluRay.REMUX.mkv" → "Some Movie (2019)"
    /// "Night.Train.S06E02.1080p.mkv" → ("Night Train", 6, 2); nil if not an episode.
    /// The tag is looked for in the whole name, not the cleaned title, which
    /// stops at a year: "Harbour Lights (2010) - S03E01 - '90.mkv".
    static func episode(_ filename: String) -> (show: String, season: Int, episode: Int)? {
        let base = (filename as NSString).deletingPathExtension
        guard let m = base.range(of: "(?i)(?<![a-z0-9])S(\\d{1,2})[ ._-]?E(\\d{1,3})(?!\\d)",
                                 options: .regularExpression) else { return nil }
        let digits = base[m].uppercased().dropFirst().split(whereSeparator: { !$0.isNumber })
        guard digits.count == 2, let s = Int(digits[0]), let e = Int(digits[1]) else { return nil }
        let prefix = String(base[..<m.lowerBound])
        let show = prefix.isEmpty ? "" : cleanTitle(prefix + ".mkv")
            .replacingOccurrences(of: "\\s*\\(\\d{4}\\)$", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return (show.isEmpty ? cleanTitle(filename) : show, s, e)
    }

    /// One-line title: "Harbour Lights S3 · E1", else the cleaned name.
    static func title(_ filename: String) -> String {
        if let ep = episode(filename) { return "\(ep.show) S\(ep.season) · E\(ep.episode)" }
        return cleanTitle(filename)
    }

    static func cleanTitle(_ filename: String) -> String {
        var base = (filename as NSString).deletingPathExtension
        // "movie.mkv.part": a download in progress.
        if ["part", "!qb", "!ut", "crdownload"].contains((filename as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        if base.isEmpty { base = filename }
        let tokens = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
            .split(separator: " ").map(String.init)
        let noise = try! NSRegularExpression(
            pattern: "^(\\d{3,4}p|4k|uhd|hdr\\d*|dv|sdr|web|web-?dl|webrip|web-?rip|bluray|blu-ray|bdrip|brrip|remux|hdtv|dvdrip|x26[45]|h\\.?26[45]|hevc|avc|av1|10bit|aac\\d?|ac3|e?ac-?3|ddp?\\d?|dts(-hd)?|truehd|atmos|proper|repack|multi|nf|amzn|atvp|dsnp|hmax)([-.].*)?$",
            options: [.caseInsensitive])
        var out: [String] = []
        for (i, t) in tokens.enumerated() {
            let range = NSRange(t.startIndex..., in: t)
            if noise.firstMatch(in: t, range: range) != nil { break }
            if i > 0, t.count == 4, let y = Int(t), (1920...2099).contains(y) {
                out.append("(\(y))")
                break
            }
            if i > 0, t.hasPrefix("[") || t.hasPrefix("(") { break }
            out.append(t)
        }
        var title = out.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        if title == title.lowercased() {
            // "night train s06e01" → "Night Train S06E01"
            title = title.split(separator: " ").map { w -> String in
                let s = String(w)
                if s.range(of: "^s\\d+e\\d+$", options: .regularExpression) != nil { return s.uppercased() }
                return s.prefix(1).uppercased() + s.dropFirst()
            }.joined(separator: " ")
        }
        return title.isEmpty ? base : title
    }

    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty, code != "und" else { return "Unknown language" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Display text composed from fields (backend `label`s may contain odd spacing).
    static func trackTitle(_ t: AudioTrack) -> String {
        var s = language(t.lang)
        if let title = t.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty { s += " “\(title)”" }
        s += " — \(codec(t.codec))"
        if let ch = channels(t.channels) { s += " \(ch)" }
        return s
    }

    static func trackTitle(_ t: SubtitleTrack) -> String {
        let lang = language(t.lang)
        var s = lang
        if let title = t.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty, title.lowercased() != lang.lowercased() { s += " “\(title)”" }
        s += " — \(codec(t.codec))"
        if t.forced == true { s += " · forced" }
        if t.external == true { s += " · external file" }
        return s
    }

    /// Collapses runs of whitespace in backend labels.
    static func tidy(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}
