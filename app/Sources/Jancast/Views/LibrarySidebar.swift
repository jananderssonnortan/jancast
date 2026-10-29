import AppKit
import SwiftUI

/// The library: what is playing, the next episode, and the last files opened
/// or played. Click loads a file (ready to play, never starts it); double-click
/// starts it right away — resumed, on the TV picked in the toolbar. Under the
/// remote, in the same column.
struct LibraryPanel: View {
    @Environment(AppModel.self) private var model
    let title: String
    @State private var firstClick: (id: RowID, at: Date)?

    var body: some View {
        // One list that keeps its order: what plays stays in its own row
        // (highlighted, with live progress), the suggestion sits at the bottom.
        // Clicking or ↑ / ↓ only moves the selection.
        let now = nowPlayingPath
        let recents = model.libraryRecents
        let nowListed = now.map { p in recents.contains { $0.path == p } } ?? false
        // A plain scrolling stack, not a List: NSTableView keeps its scroll
        // anchored to existing rows, so a section inserted above them (Now
        // Playing appearing) ended up hidden under the title bar.
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                UpdateLine()
                Text(title)
                    .font(.title3.weight(.bold))
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                if let now, !nowListed { nowRow(now) }      // not in Recent yet: on top
                if recents.isEmpty && now == nil {
                    Text("Files you open or play show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(recents) { item in
                    if item.path == now {
                        nowRow(item.path)
                    } else {
                        row(.recent(item.path)) {
                            LibraryRow(path: item.path, name: item.name, nameInfo: item.nameInfo, kind: .recent, entry: item)
                        }
                    }
                }
                if let next = model.librarySuggestion {
                    header("Suggested")
                    row(.next(next.path)) {
                        LibraryRow(path: next.path, name: next.name, nameInfo: next.nameInfo, kind: .upNext(next),
                                   entry: model.recents.first { $0.path == next.path })
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            // The remote's column: same width, centred, so titles and row
            // highlights line up with the remote's 20 pt edges.
            .frame(maxWidth: RemoteLayout.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // ↑ / ↓ keep the selected row in view.
        .onChange(of: selectedID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
        }
        }
    }

    /// What plays, in its place in the list: the way back to the player.
    private func nowRow(_ path: String) -> some View {
        row(.now(path)) {
            LibraryRow(path: path, name: model.live?.session?.file?.name,
                       nameInfo: model.live?.session?.file?.nameInfo, kind: .nowPlaying)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    /// Click loads the file (never plays it); double-click starts it. One
    /// gesture reading the click count, and the second click starts the row the
    /// first one hit: loading a file moves it to the top of Recent, so by the
    /// second click another row could be under the pointer (and a count-2 tap
    /// gesture never fired).
    private func row(_ id: RowID, @ViewBuilder content: () -> some View) -> some View {
        SidebarRow(selected: selectedID == id.id) { content() }
            .id(id.id)
            .onTapGesture {
                model.keyFocus = .library
                let now = Date()
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2, let first = firstClick,
                   now.timeIntervalSince(first.at) <= NSEvent.doubleClickInterval + 0.1 {
                    firstClick = nil
                    start(first.id)
                } else {
                    firstClick = (id, now)
                    open(id)
                }
            }
            .contextMenu { menu(for: id) }
            // One element per row for VoiceOver: a button, selected or not, with
            // a Play action beside the default one (load).
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selectedID == id.id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(id) }
            .accessibilityAction(named: "Play") { start(id) }
    }

    // MARK: - Data

    private var nowPlayingPath: String? { model.nowPlayingPath }

    /// Up Next: of what plays, else of what was played last (AppModel.libraryNext).
    private var upNext: NextEpisode? { model.libraryNext }

    private func entry(_ path: String) -> HistoryEntry? { model.recents.first { $0.path == path } }

    // MARK: - Selection

    /// Derived from what is on screen, so it always matches the main area.
    private var selectedID: String? {
        // Where ↑ / ↓ went shows at once, before its file is read.
        if let c = model.libraryCursor {
            if let n = model.librarySuggestion, n.path == c { return RowID.next(c).id }
            return RowID.recent(c).id
        }
        if model.showsPlayer, let now = nowPlayingPath { return RowID.now(now).id }
        guard let path = model.probe?.path, path != nowPlayingPath else { return nil }
        if let n = model.librarySuggestion, n.path == path { return RowID.next(path).id }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if selected {
                    // Clearly more than hover, also over the film's colours.
                    shape.fill(.tint.opacity(0.24))
                        .overlay(shape.strokeBorder(.tint.opacity(0.5), lineWidth: 1))
                } else if hovering {
                    shape.fill(Color.primary.opacity(0.06))
                }
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
        HStack(spacing: 12) {
            PosterTile(image: poster, fileName: fileName, nameInfo: nameInfo ?? entry?.nameInfo,
                       width: 72, height: 40, radius: 6)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if isNowPlaying && model.phase == .playing {
                        Image(systemName: "play.fill")      // static: a looping effect redraws the list constantly
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 3))
                            .padding(2)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(display.headline)
                    .font(.body.weight(.medium))
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
                    .foregroundStyle(.secondary)
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
                        Capsule().fill(.tint).frame(width: g.size.width * min(1, max(0, fraction)))
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

/// One quiet line over the library while an update is available, being
/// downloaded, or failed to install (Updater); a failed check stays quiet.
private struct UpdateLine: View {
    private var updater: Updater { .shared }
    @State private var showNotes = false

    var body: some View {
        switch updater.state {
        case .available(let r):
            line("arrow.down.circle.fill", r.version == Updater.currentVersion
                 ? "A newer build of Jancast \(r.version) is available" : "Jancast \(r.version) is available") {
                if let notes = r.notes {
                    Button("What’s New") { showNotes.toggle() }
                        .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotes(markdown: notes) }
                }
                Button(Updater.canInstallInPlace ? "Install" : "Download") { updater.install() }
                    .help(Updater.canInstallInPlace ? "Download it, quit and open the new Jancast" : "Open the release page")
            }
        case .downloading:
            line(nil, "Downloading the update…") { EmptyView() }
        case .installFailed(let m):
            line("exclamationmark.triangle.fill", m) {
                Button("Release Page") { NSWorkspace.shared.open(Updater.releasesPage) }
            }
        default:
            EmptyView()
        }
    }

    private func line(_ symbol: String?, _ text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.tint) } else { ProgressView().controlSize(.small) }
            Text(text).lineLimit(2)
            Spacer(minLength: 4)
            action().controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.top, 14)
    }
}

/// An update's release notes (Markdown: headings, bullets, bold, links).
private struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        // No scroll view: the notes are a few lines, and a scrolling popover
        // sized from its content can come out with no height.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.split(separator: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(.headline)
                        .padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else {
                    Text(inline(line))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 380, alignment: .leading)
        .padding(16)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
