import SwiftUI

struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var minLevel: LogLevel = .info
    @State private var hiddenSources = Set<String>()
    @State private var search = ""
    @State private var selection = Set<Int>()
    @State private var thisSessionOnly = false

    private static let knownSources = ["app", "ffmpeg", "http", "airplay", "network"]

    var body: some View {
        let start = model.telemetry.sessionStart ?? 0
        let rows = model.telemetry.events.reversed().filter { e in
            LogLevel(e.level).rank >= minLevel.rank
                && !hiddenSources.contains(e.source ?? "")
                && (!thisSessionOnly || e.t >= start - 1)
                && (search.isEmpty || (e.message ?? "").localizedCaseInsensitiveContains(search) || (e.source ?? "").localizedCaseInsensitiveContains(search))
        }
        let sources = Array(Set(Self.knownSources + model.telemetry.events.compactMap(\.source))).sorted()

        VStack(spacing: 0) {
            // Wide: every filter inline. Narrow: sources and "This session"
            // move into a ⋯ menu, then the level too, so nothing is clipped.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    levelPicker
                    Menu { sourceToggles(sources) } label: {
                        Label(hiddenSources.isEmpty ? "All sources" : "\(sources.count - hiddenSources.count) of \(sources.count) sources",
                              systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .fixedSize()
                    sessionToggle
                    searchField
                    trailingControls(rows)
                }
                HStack(spacing: 10) {
                    levelPicker
                    overflowMenu(sources, includeLevel: false)
                    searchField
                    trailingControls(rows)
                }
                HStack(spacing: 10) {
                    overflowMenu(sources, includeLevel: true)
                    searchField
                    trailingControls(rows)
                }
            }
            .fixedSize(horizontal: false, vertical: true)   // one row high, not half the drawer
            .controlSize(.small)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if rows.isEmpty {
                ContentUnavailableView(model.telemetry.events.isEmpty ? "No Events Yet" : "No Matching Events",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text(model.telemetry.events.isEmpty ? "Backend, ffmpeg, HTTP and AirPlay events appear here." : "Try a different filter."))
            } else {
                // The drawer is at most 560 pt wide: Time, Level (an icon) and
                // Source stay narrow and fixed, and the message gets the rest,
                // wrapping onto a second and third line instead of being cut.
                Table(rows, selection: $selection) {
                    TableColumn("Time") { e in
                        Text(Fmt.time(e.t)).monospacedDigit().foregroundStyle(.secondary)
                            .help(Fmt.timeMs(e.t))
                    }
                    .width(62)
                    TableColumn("") { e in
                        let l = LogLevel(e.level)
                        Image(systemName: l.symbol)
                            .foregroundStyle(l == .info ? Color.secondary : l.color)
                            .help(l.title)
                            .accessibilityLabel(l.title)
                    }
                    .width(16)
                    TableColumn("Source") { e in
                        Text(e.source ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .width(52)
                    TableColumn("Message") { e in
                        Text(e.message ?? "")
                            .fontWeight(LogLevel(e.level) == .error ? .medium : .regular)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(e.message ?? "")
                    }
                    .width(min: 120, ideal: 200)     // grows to fill the rest
                }
                .onCopyCommand {
                    let chosen = rows.filter { selection.contains($0.id) }
                    return [NSItemProvider(object: Self.text(for: chosen) as NSString)]
                }
            }
        }
    }

    @ViewBuilder
    private var levelOptions: some View {
        Text("All levels").tag(LogLevel.info)
        Text("Warnings & errors").tag(LogLevel.warn)
        Text("Errors only").tag(LogLevel.error)
    }

    private var levelPicker: some View {
        Picker("Level", selection: $minLevel) {
            levelOptions
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var sessionToggle: some View {
        Toggle("This session", isOn: $thisSessionOnly).toggleStyle(.checkbox).fixedSize()
            .help("Only events since this playback started")
    }

    private var searchField: some View {
        TextField("Filter", text: $search, prompt: Text("Filter"))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 80, maxWidth: 200)
    }

    @ViewBuilder
    private func sourceToggles(_ sources: [String]) -> some View {
        ForEach(sources, id: \.self) { s in
            Toggle(s, isOn: Binding(get: { !hiddenSources.contains(s) },
                                    set: { if $0 { hiddenSources.remove(s) } else { hiddenSources.insert(s) } }))
        }
        Divider()
        Button("Show All Sources") { hiddenSources.removeAll() }
    }

    /// The narrow window's home for the filters that don't fit inline.
    /// Filled when any of them hides events, so a filter is never invisible.
    private func overflowMenu(_ sources: [String], includeLevel: Bool) -> some View {
        let active = !hiddenSources.isEmpty || thisSessionOnly || (includeLevel && minLevel != .info)
        return Menu {
            if includeLevel {
                Picker("Level", selection: $minLevel) {
                    levelOptions
                }
                .pickerStyle(.inline)
            }
            Toggle("This session only", isOn: $thisSessionOnly)
            Section(hiddenSources.isEmpty ? "All sources" : "\(sources.count - hiddenSources.count) of \(sources.count) sources") {
                sourceToggles(sources)
            }
        } label: {
            Image(systemName: active ? "ellipsis.circle.fill" : "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(includeLevel ? "Level, session and source filters" : "Session and source filters")
    }

    @ViewBuilder
    private func trailingControls(_ rows: [Event]) -> some View {
        Spacer(minLength: 0)
        Text("\(rows.count)").foregroundStyle(.secondary).monospacedDigit()
            .help("\(rows.count) events shown")
        Button {
            AppModel.copyToPasteboard(Self.text(for: selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }))
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(selection.isEmpty ? "Copy all shown events as text" : "Copy the selected events as text (⌘C)")
    }

    static func text(for events: [Event]) -> String {
        events.map { "\(Fmt.timeMs($0.t))  \(($0.level ?? "").uppercased().padding(toLength: 5, withPad: " ", startingAt: 0))  \(($0.source ?? "").padding(toLength: 8, withPad: " ", startingAt: 0))  \($0.message ?? "")" }
            .joined(separator: "\n")
    }
}
