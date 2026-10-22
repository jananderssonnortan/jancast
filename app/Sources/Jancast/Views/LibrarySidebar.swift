import AppKit
import SwiftUI

/// The library: what is playing, the next episode, and the last files opened
/// or played. Click loads a file (ready to play, never starts it); double-click
/// starts it right away — resumed, on the TV it last played on. Under the
/// remote, in the same column.
struct LibraryPanel: View {
    @Environment(AppModel.self) private var model
    let title: String

    var body: some View {
        let now = nowPlayingPath
        let next = upNext
        let recents = Array(model.recents.filter { $0.path != now && $0.path != next?.path }.prefix(10))
        // A plain scrolling stack, not a List: NSTableView keeps its scroll
        // anchored to existing rows, so a section inserted above them (Now
        // Playing appearing) ended up hidden under the title bar.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                if let now {
                    header("Now Playing")
                    row(.now(now)) {
                        LibraryRow(path: now, name: model.live?.session?.file?.name,
                                   nameInfo: model.live?.session?.file?.nameInfo, kind: .nowPlaying)
                    }
                }
                if let next, next.path != now {
                    header("Up Next")
                    row(.next(next.path)) {
                        LibraryRow(path: next.path, name: next.name, nameInfo: next.nameInfo, kind: .upNext(next),
                                   entry: model.recents.first { $0.path == next.path })
                    }
                }
                header("Recent")
                if recents.isEmpty {
                    Text("Files you open or play show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                ForEach(recents) { item in
                    row(.recent(item.path)) {
                        LibraryRow(path: item.path, name: item.name, nameInfo: item.nameInfo, kind: .recent, entry: item)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            // The remote's column: same width, centred, so titles and rows
            // start where the remote's do (12 + 8 = its 20 pt inset).
            .frame(maxWidth: RemoteLayout.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    /// Click loads the file (never plays it); double-click starts it.
    private func row(_ id: RowID, @ViewBuilder content: () -> some View) -> some View {
        SidebarRow(selected: selectedID == id.id) { content() }
            .onTapGesture(count: 2) { start(id) }
            .simultaneousGesture(TapGesture().onEnded { open(id) })
            .contextMenu { menu(for: id) }
    }

    // MARK: - Data

    private var nowPlayingPath: String? {
        guard model.hasSession, model.phase.isActive else { return nil }
        return model.live?.session?.file?.path
    }

    /// The playing file's next episode, else the loaded file's.
    private var upNext: NextEpisode? {
        nowPlayingPath != nil ? model.upNext : model.probe?.next
    }

    private func entry(_ path: String) -> HistoryEntry? { model.recents.first { $0.path == path } }

    // MARK: - Selection

    /// Derived from what is on screen, so it always matches the main area.
    private var selectedID: String? {
        if model.showsPlayer, let now = nowPlayingPath { return RowID.now(now).id }
        guard let path = model.probe?.path, path != nowPlayingPath else { return nil }
        if let n = upNext, n.path == path { return RowID.next(path).id }
        return RowID.recent(path).id
    }

    private func open(_ id: RowID) {
        switch id {
        case .now:
            model.playerVisible = true
        case .next(let path), .recent(let path):
            if !model.showsPlayer, model.probe?.path == path { return }   // already loaded
            model.playerVisible = false
            let history = entry(path)
            Task { await model.openFile(path: path, history: history) }
        }
    }

    /// Double-click / Play.
    private func start(_ id: RowID) {
        switch id {
        case .now:
            model.playerVisible = true
        case .next(let path):
            if nowPlayingPath != nil { model.playNext(); return }
            if let e = entry(path) { model.playNow(e); return }
            Task {
                await model.openFile(path: path)
                if model.probe?.path == path { model.play(startPosition: model.resumeEntry?.resumePosition) }
            }
        case .recent(let path):
            if let e = entry(path) { model.playNow(e) }
        }
    }

    private func startOver(_ path: String) {
        Task {
            await model.openFile(path: path, history: entry(path), offerResume: false)
            if model.probe?.path == path { model.play() }
        }
    }

    @ViewBuilder private func menu(for id: RowID) -> some View {
        switch id {
        case .now:
            Button("Show Player") { model.playerVisible = true }
            Button("Show in Finder") { reveal(id.path) }
        case .next(let path), .recent(let path):
            if let pos = entry(path)?.resumePosition {
                Button("Resume at \(Fmt.clock(pos))") { start(id) }
                Button("Start Over") { startOver(path) }
            } else {
                Button("Play") { start(id) }
            }
            Button("Open Without Playing") { open(id) }
            Divider()
            Button("Show in Finder") { reveal(path) }
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Row identity for the selection highlight: the same file can appear as Up
/// Next and in Recent, so the section is part of the id.
private enum RowID {
    case now(String), next(String), recent(String)

    var id: String {
        switch self {
        case .now(let p): return "now:" + p
        case .next(let p): return "next:" + p
        case .recent(let p): return "recent:" + p
        }
    }

    var path: String {
        switch self {
        case .now(let p), .next(let p), .recent(let p): return p
        }
    }
}

// MARK: - Row

/// Sidebar-style row chrome: a tinted rounded highlight when selected, a faint
/// one on hover.
private struct SidebarRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22)
                          : hovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct LibraryRow: View {
    enum Kind {
        case nowPlaying, upNext(NextEpisode), recent
    }

    @Environment(AppModel.self) private var model
    let path: String
    let name: String?
    let nameInfo: NameInfo?
    let kind: Kind
    var entry: HistoryEntry? = nil
    @State private var poster: NSImage?

    private var fileName: String { name ?? (path as NSString).lastPathComponent }

    var body: some View {
        let display = Fmt.name(fileName, nameInfo ?? entry?.nameInfo)
        HStack(spacing: 10) {
            PosterTile(image: poster, fileName: fileName, nameInfo: nameInfo ?? entry?.nameInfo)
                .overlay(alignment: .bottomTrailing) {
                    if isNowPlaying && model.phase == .playing {
                        Image(systemName: "play.fill")      // static: a looping effect redraws the list constantly
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                            .padding(2)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(display.headline)
                    .lineLimit(1)
                if let episode = display.episode {
                    Text(episode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(path)
        .task(id: posterKey) {
            guard let at = posterAt else { poster = nil; return }
            poster = await Thumbnails.poster(path: path, at: at, backend: model.backend)
        }
    }

    private var isNowPlaying: Bool {
        if case .nowPlaying = kind { return true }
        return false
    }

    /// Retry the poster once this file's thumbnails have been made.
    private var posterKey: String {
        let ready = model.thumbs.path == path && model.thumbs.info?.done == true
        return "\(path)|\(ready)|\(posterAt != nil)"
    }

    /// Resume point, else 10 % in; nil (a neutral tile) before the length is known.
    private var posterAt: Double? {
        let start: Double? = isNowPlaying ? model.live?.session?.startPosition : entry?.resumePosition
        let duration = entry?.duration ?? model.live?.session?.file?.durationS ?? 0
        let preferred = (start ?? 0) > 0 ? start! : duration * 0.1
        return preferred > 0 ? preferred : nil
    }

    @ViewBuilder private var status: some View {
        switch kind {
        case .nowPlaying:
            let duration = model.live?.session?.file?.durationS ?? model.live?.playback?.duration
            let pos = model.displayPosition ?? 0
            ProgressRow(fraction: duration.map { $0 > 0 ? pos / $0 : 0 },
                        text: duration.map { "\(Fmt.clock(max(0, $0 - pos))) left" } ?? model.phase.title)
        case .upNext, .recent:
            if entry?.watched == true {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let e = entry, let pos = e.resumePosition, let d = e.duration, d > 0 {
                ProgressRow(fraction: pos / d, text: "\(Fmt.clock(max(0, d - pos))) left")
            } else {
                Text("Not started")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ProgressRow: View {
    let fraction: Double?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let fraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule().fill(Color.accentColor).frame(width: g.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(width: 44, height: 3)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
