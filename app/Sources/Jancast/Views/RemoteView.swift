import SwiftUI

/// The main window's content: the "remote" — the TV is the screen, so the Mac
/// shows a compact remote (what is on, a filmstrip timeline, big transport
/// buttons, tracks) with the library underneath. Always one column: the
/// window is kept narrow (RootView.maxWidth), like a remote in the hand.
struct RemoteLayout: View {
    @Environment(AppModel.self) private var model

    static let columnWidth: CGFloat = 440
    /// How far the film's backdrop reaches below the toolbar: fixed, about the
    /// remote's height. Following the remote's own height, it shrank and grew
    /// whenever another file was clicked (a shorter "Reading file…" step, then
    /// a remote a few points taller or shorter); the library's glow under it
    /// carries the colours on.
    static let backdropHeight: CGFloat = 400
    /// Scroll target: the transport stays in view when the drawer opens.
    static let transportID = "transport"
    private static let fade: CGFloat = 24
    /// Snapshots (development aid) can't render the scroll fade's mask.
    private static let snapshotting = ProcessInfo.processInfo.environment["JANCAST_SNAPSHOT_DIR"] != nil

    var body: some View {
        // The remote keeps its natural height and scrolls when the window (or
        // the open Diagnostics drawer) leaves less; the library gets the rest.
        GeometryReader { geo in
            let height = model.remoteHeight
            let overflows = height > geo.size.height + 1
            let look = model.ambience
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        RemoteColumn()
                            .frame(maxWidth: Self.columnWidth)
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                                if abs(h - model.remoteHeight) > 0.5 { model.remoteHeight = h }
                            }
                            .padding(.bottom, overflows ? Self.fade : 0)   // room to scroll past the fade
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(overflows ? .visible : .automatic)
                    // "There is more": the cut-off edge fades instead of slicing a tile.
                    .modifier(BottomFade(height: Self.fade, active: overflows && !Self.snapshotting))
                    .frame(height: height > 0 ? min(height, geo.size.height) : nil)
                    .onChange(of: model.diagnosticsOpen) { _, open in
                        guard open else { return }
                        withAnimation(.snappy) { proxy.scrollTo(Self.transportID, anchor: .bottom) }
                    }
                }
                // Hidden when the drawer leaves only a sliver (a cut-off title).
                if height == 0 || geo.size.height - height >= 60 {
                    LibraryPanel(title: "Recent")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            // The poster's colours behind the remote, fading out where the
            // library starts. macOS 15+ draws it as the window's background
            // instead (RootView), so it also runs under the toolbar.
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    ZStack(alignment: .top) {
                        LibraryWash(palette: model.washPalette, fallback: look?.backdrop)
                        AmbientBackdrop(image: look?.backdrop, scene: model.backdropScene)
                            .frame(height: min(Self.backdropHeight, geo.size.height))
                    }
                }
            }
            .tint(look?.tint)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y in
                if abs(y - model.remoteTop) > 0.5 { model.remoteTop = y }
            }
        }
    }
}

/// Fades the bottom edge out. Inactive: no mask at all (snapshots can't render one).
private struct BottomFade: ViewModifier {
    let height: CGFloat
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: height)
                }
            }
        } else {
            content
        }
    }
}

/// The remote for whatever is on screen: the stream, the file ready to play,
/// or a drop target.
private struct RemoteColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.showsPlayer {
                PlayingRemote()
            } else if model.probing && model.probe == nil {
                // Only with nothing loaded: switching files keeps the current
                // remote until the next one is read (no collapse and regrow).
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading file…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else if let probe = model.probe {
                ReadyRemote(probe: probe)
            } else {
                EmptyDropView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.2), value: model.showsPlayer)
    }
}

// MARK: - Now card

/// Poster, title, "Season 6 · Episode 3" and the format badges.
struct NowCard: View {
    let fileName: String
    var nameInfo: NameInfo? = nil
    let poster: NSImage?
    let detail: String?             // shown when the file is not an episode (length, …)
    let badges: [FormatBadge]

    var body: some View {
        let name = Fmt.name(fileName, nameInfo)
        // A film's year goes on the line under the title: "Quiet Hours (2025)"
        // at this size broke onto two lines.
        let year = nameInfo?.kind == "movie" ? nameInfo?.year : nil
        let headline = year.map { name.headline.replacingOccurrences(of: " (\($0))", with: "") } ?? name.headline
        let detail = [year.map(String.init), detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(alignment: .center, spacing: 16) {
            PosterTile(image: poster, fileName: fileName, nameInfo: nameInfo, width: 136, height: 76, radius: 10, large: true)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)

            // Always as tall as with a two-line title, a shorter one at the
            // bottom of it: stepping through the library with ↑ / ↓ moved
            // everything below by a line whenever the title's length changed,
            // and centred the episode line and badges still moved half a line.
            ZStack(alignment: .bottomLeading) {
                info(headline, name: name, detail: detail, reserve: true).hidden()
                info(headline, name: name, detail: detail, reserve: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func info(_ headline: String, name: MediaName, detail: String, reserve: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(2, reservesSpace: reserve)
                .minimumScaleFactor(0.8)
                .help(fileName)
            if let episode = name.episodeLong {
                Text([episode, name.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            FormatBadges(badges: badges)
                .padding(.top, 2)
        }
    }
}

/// A frame from the video, else (no thumbnails yet) a neutral tile with
/// "S1 · E3" or the title's initials.
struct PosterTile: View {
    let image: NSImage?
    let fileName: String
    var nameInfo: NameInfo? = nil
    var width: CGFloat = 64
    var height: CGFloat = 36
    var radius: CGFloat = 5
    var large = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.09)
                Text(Self.label(Fmt.name(fileName, nameInfo)))
                    .font(large ? .headline : .caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    static func label(_ name: MediaName) -> String {
        if let episode = name.episode { return episode }
        let words = name.headline.split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// "1080p", "HEVC", "E-AC-3 5.1", "CC" … — what the TV gets, at a glance.
struct FormatBadge: Hashable {
    var text: String
    var warning = false             // costs something (re-encode)
}

struct FormatBadges: View {
    let badges: [FormatBadge]

    var body: some View {
        BadgeFlow(spacing: 5) {
            ForEach(badges, id: \.self) { b in
                Text(b.text)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(b.warning ? Color.orange : .primary.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(b.warning ? Color.orange.opacity(0.16) : Color.primary.opacity(0.1)))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Badges for a video: resolution, HDR, codec, audio, subtitles.
    static func make(width: Int?, height: Int?, hdr: Bool, videoCodec: String?, reencode: Bool,
                     audioCodec: String?, channels: Int?, subtitles: Bool) -> [FormatBadge] {
        var out: [FormatBadge] = []
        let w = width ?? 0, h = height ?? 0
        if w >= 3800 || h >= 2100 { out.append(.init(text: "4K")) }
        else if w >= 1900 || h >= 1000 { out.append(.init(text: "1080p")) }
        else if w >= 1260 || h >= 700 { out.append(.init(text: "720p")) }
        else if w > 0 { out.append(.init(text: "SD")) }
        if hdr { out.append(.init(text: "HDR")) }
        if let c = videoCodec { out.append(.init(text: Fmt.codec(c))) }
        if reencode { out.append(.init(text: "Re-encode", warning: true)) }
        if let a = audioCodec {
            out.append(.init(text: [Fmt.codec(a), channelText(channels)].compactMap { $0 }.joined(separator: " ")))
        }
        if subtitles { out.append(.init(text: "CC")) }
        return out
    }

    /// "2.0", "5.1" … as on a box.
    static func channelText(_ channels: Int?) -> String? {
        switch channels {
        case 1: "Mono"
        case 2: "2.0"
        case 6: "5.1"
        case 8: "7.1"
        case let n?: "\(n) ch"
        default: nil
        }
    }
}

/// Badges in a row, wrapping onto the next line instead of widening the
/// column: at the window's minimum width "1080p HEVC E-AC-3 5.1 CC" didn't fit
/// beside the poster and pushed everything 3.5 pt past the right edge.
private struct BadgeFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, p) in zip(subviews, arrange(bounds.width, subviews).points) {
            view.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (points, CGSize(width: width, height: y + rowHeight))
    }
}

/// Short track names for the tiles ("English · E-AC-3 5.1", "Audio 2 · AAC
/// 2.0"); the menus keep the full ones.
enum TrackLabel {
    static func audio(_ t: AudioTrack, in tracks: [AudioTrack], stereo: Bool) -> String {
        let n = (tracks.firstIndex(of: t) ?? 0) + 1
        let format = stereo ? "Stereo mix" : [Fmt.codec(t.codec), FormatBadges.channelText(t.channels)].compactMap { $0 }.joined(separator: " ")
        return "\(name(lang: t.lang, title: t.title, fallback: "Audio \(n)")) · \(format)"
    }

    static func subtitle(_ t: SubtitleTrack, in tracks: [SubtitleTrack]) -> String {
        let n = (tracks.firstIndex(of: t) ?? 0) + 1
        return "\(name(lang: t.lang, title: t.title, fallback: "Subtitles \(n)")) · \(Fmt.codec(t.codec))"
            + (t.forced == true ? " · forced" : "")
    }

    /// The language when tagged, else the track's own title, else its number.
    private static func name(lang: String?, title: String?, fallback: String) -> String {
        if let lang, !lang.isEmpty, lang != "und" { return Fmt.language(lang) }
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty { return title }
        return fallback
    }
}

// MARK: - Device pill

/// Top-right capsule: the TV, with a status dot.
struct PillBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

// MARK: - Filmstrip timeline

/// The episode as a strip of frames from the preview thumbnails — it is the
/// timeline. Played part dimmed, a playhead, prepared/buffered on a thin line
/// below. Hovering or dragging lifts an enlarged frame with its time above the
/// pointer (on demand only); interactive strips seek on release.
/// Frames not loaded yet are empty film frames with their time, and their
/// preview is just the time.
struct Filmstrip: View {
    @Environment(AppModel.self) private var model
    let duration: Double
    let position: Double
    var buffered: Double? = nil
    var prepared: Double? = nil
    var interactive = true
    var onSeek: (Double) -> Void = { _ in }

    @State private var hoverX: CGFloat?
    @State private var dragValue: Double?
    /// Development aid for snapshots: pretend the pointer hovers at this fraction.
    private let snapshotHover = ProcessInfo.processInfo.environment["JANCAST_SNAPSHOT_HOVER"].flatMap(Double.init)

    static let height: CGFloat = 46
    private static let space = "filmstrip"
    /// Sprocket band at the top and bottom of the film.
    private static let band: CGFloat = 7
    // Fits above the strip under the now card without being cut off.
    private let previewWidth: CGFloat = 160

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shown = dragValue ?? position
            let pointer = dragValue.map { x($0, w) } ?? hoverX ?? snapshotHover.map { CGFloat($0) * w }
            ZStack(alignment: .topLeading) {
                strip(width: w, played: x(shown, w))
                lines(width: w)
                    .offset(y: Self.height + 4)
                playhead(at: x(shown, w))
                if let skip = model.skipHint, interactive {
                    skipBubble(skip, at: x(shown, w), width: w)
                }
                if let pointer, model.skipHint == nil {
                    preview(time: Double(pointer / max(1, w)) * duration, width: w, x: pointer)
                }
            }
            .contentShape(Rectangle())
            // Pointer positions in the strip's own space (named on the
            // GeometryReader below), not whatever "local" means inside the
            // remote's scroll view. Hover previews on the ready screen too.
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case .active(let p) = phase { hoverX = max(0, min(w, p.x)) } else { hoverX = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { g in
                        // No hover events arrive while the button is down, so
                        // the pointer is followed here too.
                        hoverX = max(0, min(w, g.location.x))
                        guard interactive else { return }
                        dragValue = Double(max(0, min(w, g.location.x)) / w) * duration
                    }
                    .onEnded { g in
                        if let v = dragValue { onSeek(v) }
                        dragValue = nil     // the model holds the target until the TV gets there
                        // The preview stays where the pointer was let go — or
                        // goes, if that was off the strip.
                        let inside = (0...w).contains(g.location.x) && (-4...(Self.height + 8)).contains(g.location.y)
                        hoverX = inside ? g.location.x : nil
                    }
            )
            .animation(.easeOut(duration: 0.12), value: pointer == nil)
            .animation(.easeOut(duration: 0.18), value: model.skipHint == nil)
        }
        .coordinateSpace(name: Self.space)
        .frame(height: Self.height + 8)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Fmt.clock(position)) of \(Fmt.clock(duration))")
        .accessibilityAdjustableAction { dir in
            guard interactive else { return }
            switch dir {
            case .increment: model.skip(30)
            case .decrement: model.skip(-10)
            @unknown default: break
            }
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(max(0, min(1, t / max(1, duration)))) * w
    }

    /// A piece of film: dark base, sprocket holes along both edges, frames in
    /// between. Watched stretches show their picture; the rest are empty frames
    /// with their time, faint, until thumbnails are made.
    /// The timeline: the film's colour palette once it exists; while it is
    /// being made a quiet "Preparing timeline · 35%" strip (frames filling in
    /// one by one flashed); the film roll only if no palette will come.
    @ViewBuilder private func strip(width w: CGFloat, played: CGFloat) -> some View {
        if let palette = model.thumbs.palette {
            paletteStrip(palette, width: w, played: played)
        } else if model.thumbs.paletteUnavailable {
            filmRoll(width: w, played: played)
        } else {
            preparingStrip(width: w, played: played)
        }
    }

    private func preparingStrip(width w: CGFloat, played: CGFloat) -> some View {
        let progress = model.thumbs.timelineProgress
        return ZStack(alignment: .leading) {
            Color.primary.opacity(0.07)
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: w * progress)
            Text(model.thumbs.path == nil ? " " : "Preparing timeline · \(Fmt.percent(progress))")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .frame(width: w, height: Self.height)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.black.opacity(0.25)).frame(width: played)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .animation(.easeOut(duration: 0.3), value: progress)
    }

    /// The film as bands of colour, one per 10 s (like a movie barcode), with a
    /// soft sheen top to bottom so it reads as a surface, not flat bars.
    private func paletteStrip(_ palette: NSImage, width w: CGFloat, played: CGFloat) -> some View {
        Image(nsImage: palette)
            .resizable()
            .interpolation(.none)
            .frame(width: w, height: Self.height)
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.18), location: 0),
                                       .init(color: .clear, location: 0.3),
                                       .init(color: .white.opacity(0.12), location: 0.66),
                                       .init(color: .black.opacity(0.22), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .leading) {
                // Played part dimmed.
                Rectangle().fill(Color.black.opacity(0.4)).frame(width: played)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private func filmRoll(width w: CGFloat, played: CGFloat) -> some View {
        let count = max(6, Int(w / 40))    // small frames: a sense of the film, little to spoil
        return HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let t = (Double(i) + 0.5) / Double(count) * duration
                ZStack {
                    if model.thumbs.available, let img = model.thumbs.image(at: t, pin: true) {
                        Color.clear.overlay { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }.clipped()
                    } else {
                        LinearGradient(colors: [Color(white: 0.24), Color(white: 0.17)], startPoint: .top, endPoint: .bottom)
                        Text(Fmt.clock((Double(i) / Double(count)) * duration))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.32))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Self.band)
        .padding(.horizontal, 3)
        .frame(width: w, height: Self.height)
        .background(Color(white: 0.08))
        .overlay { Sprockets(band: Self.band).allowsHitTesting(false) }
        .overlay(alignment: .leading) {
            // Played part dimmed.
            Rectangle().fill(Color.black.opacity(0.4)).frame(width: played)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// The holes along the film's edges, drawn in one pass. They show the
    /// window behind, like real film.
    private struct Sprockets: View {
        let band: CGFloat

        var body: some View {
            Canvas { ctx, size in
                let hole = CGSize(width: 4.5, height: 3.5)
                let pitch: CGFloat = 9
                let color = Color(nsColor: .windowBackgroundColor)
                var x: CGFloat = 4
                while x + hole.width <= size.width - 3 {
                    for y in [(band - hole.height) / 2, size.height - band + (band - hole.height) / 2] {
                        let r = CGRect(origin: CGPoint(x: x, y: y), size: hole)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(color))
                    }
                    x += pitch
                }
            }
        }
    }

    /// Prepared (grey) and TV-buffered (accent) ranges on a 2 pt line under the strip.
    private func lines(width w: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            if let prepared { Capsule().fill(Color.secondary.opacity(0.45)).frame(width: x(prepared, w)) }
            if let buffered { Capsule().fill(.tint).frame(width: x(buffered, w)) }
        }
        .frame(width: w, height: 3)
    }

    /// "+30 s" on the film itself, beside the playhead (after it, or before it
    /// near the end) — above the strip it covered the title and badges.
    private func skipBubble(_ skip: Double, at px: CGFloat, width w: CGFloat) -> some View {
        let after = px < w - 90
        return Text((skip > 0 ? "+" : "−") + Fmt.skipAmount(abs(skip)))
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
            .shadow(color: .black.opacity(0.35), radius: 3)
            .fixedSize()
            // A zero-width anchor beside the playhead; the bubble grows away from it.
            .frame(width: 0, height: Self.height, alignment: after ? .leading : .trailing)
            .offset(x: after ? px + 8 : px - 8)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func playhead(at px: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white)
            .frame(width: 3, height: Self.height + 8)
            .shadow(color: .white.opacity(0.55), radius: 5)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: px - 1.5, y: -4)
            .allowsHitTesting(false)
    }

    private func preview(time: Double, width w: CGFloat, x px: CGFloat) -> some View {
        let h = previewWidth / CGFloat(model.thumbs.aspect)
        let left = min(max(0, px - previewWidth / 2), max(0, w - previewWidth))
        let frame = model.thumbs.available
        let label = Text(Fmt.clock(time))
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.7)))
        // The time sits on the picture, so the preview stays low enough not to
        // be cut off under the toolbar.
        return Group {
            if frame {
                ZStack(alignment: .bottom) {
                    if let img = model.thumbs.image(at: time) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black.opacity(0.4)
                    }
                    label.padding(.bottom, 5)
                }
                .frame(width: previewWidth, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
            } else {
                label
            }
        }
        .frame(width: previewWidth)
        .offset(x: left, y: frame ? -(h + 8) : -30)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Buttons and tiles

/// Big round remote buttons; the prominent one is filled.
struct RoundButtonStyle: ButtonStyle {
    var size: CGFloat
    var prominent = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .frame(width: size, height: size)
            .background {
                if prominent {
                    Circle().fill(Color.primary.opacity(hovering ? 0.88 : 1))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                } else {
                    // A soft surface: lighter at the top, a hairline edge.
                    Circle().fill(LinearGradient(colors: [Color.primary.opacity(hovering ? 0.18 : 0.12),
                                                          Color.primary.opacity(hovering ? 0.11 : 0.06)],
                                                 startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// A tile with a small caption over its value that opens a menu. The whole
/// tile is the menu's label, so a click anywhere on it opens the menu.
struct MenuTile<MenuContent: View>: View {
    let caption: String
    let value: String
    @ViewBuilder var menu: MenuContent
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Menu {
            menu
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(hovering && enabled ? 0.13 : 0.09),
                                              Color.primary.opacity(hovering && enabled ? 0.09 : 0.05)],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

// MARK: - Empty state

struct EmptyDropView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDropTargeted) private var targeted

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text("Drop a video or press ⌘O")
                .font(.title3.weight(.semibold))
            Text("Or pick something from the library. MKV files are remuxed on the fly and streamed to your Apple TV.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            HStack {
                Button("Choose File…") { model.presentOpenPanel() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                if model.isMock {
                    Button("Sample") { Task { await model.openFile(path: AppModel.sampleMoviePath) } }
                        .controlSize(.large)
                }
            }
            .padding(.top, 4)
            if let err = model.probeError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: 360)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color(nsColor: .tertiaryLabelColor),
                              style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [8, 6]))
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}
