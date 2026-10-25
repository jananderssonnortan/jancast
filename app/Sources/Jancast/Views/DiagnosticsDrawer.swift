import AppKit
import SwiftUI

/// The opt-in Diagnostics drawer: slides up from the bottom of the main
/// window, under the player or the setup form. Data is collected all the
/// time (the main model polls regardless), so the full history is here even
/// if the drawer is opened after a failure.
struct DiagnosticsDrawer: View {
    @Environment(AppModel.self) private var model
    /// Height of the drawer; the parent clamps it to what the window allows.
    @Binding var height: Double
    let maxHeight: Double

    static let minHeight = 220.0

    var body: some View {
        VStack(spacing: 0) {
            ResizeHandle(height: $height, maxHeight: maxHeight)
            DrawerHeader()
            Divider()
            Group {
                switch model.diagSection {
                case .overview: DiagnosticsOverview()
                case .charts: DiagnosticsCharts()
                case .segments: SegmentsView()
                case .events: EventsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A little of the film's colour shows through, so the drawer doesn't
        // end in a hard grey slab. Not a material: a live blur under charts
        // that redraw every second costs too much (see DESIGN.md).
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.88))
    }
}

/// The drawer's top edge: a hairline you can drag to resize.
private struct ResizeHandle: View {
    @Binding var height: Double
    let maxHeight: Double
    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 4)
                .offset(y: 5)
        }
        .frame(height: 9, alignment: .top)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = dragStart ?? height
                    dragStart = start
                    height = max(DiagnosticsDrawer.minHeight, min(maxHeight, start - g.translation.height))
                }
                .onEnded { _ in dragStart = nil }
        )
        .help("Drag to resize")
        .accessibilityHidden(true)
    }
}

private struct DrawerHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            // The tabs get first claim on the space left by the buttons, the
            // verdict what remains; both shrink in steps rather than clip.
            sectionPicker
                .layoutPriority(1)

            if model.hasSession {
                // The verdict in one line, visible on every tab.
                // In the narrow window, just the icon.
                // The Summary tab's banner says it in full right below.
                let headline = model.diagSection == .overview ? nil : model.live?.diagnosis?.headline
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        HealthIcon(health: model.streamHealth)
                        Text(DiagStatus(model.live?.diagnosis?.status).title).fontWeight(.medium)
                            .fixedSize()
                        if let headline, !headline.isEmpty {
                            Text("· " + headline).foregroundStyle(.secondary)
                                .truncationMode(.tail)
                        }
                    }
                    HealthIcon(health: model.streamHealth)
                }
                .font(.callout)
                .lineLimit(1)
                .help(headline ?? "")
            }
            if let err = model.pollError {
                Label(err, systemImage: "bolt.horizontal.circle")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
            }

            Spacer(minLength: 8)

            // Never squeezed: the drawer must always be closable with the mouse.
            HStack(spacing: 12) {
                if model.isMock {
                    Image(systemName: "theatermasks")
                        .foregroundStyle(.secondary)
                        .help("Mock backend: simulated data, nothing is sent to a TV")
                }
                Button { AppModel.copyToPasteboard(model.diagnosticsReport()) } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("Copy a text diagnostics report for sharing (⇧⌘C)")
                .disabled(!model.hasSession)
                Button { model.diagnosticsOpen = false } label: {
                    Image(systemName: "xmark")
                }
                .help("Hide Diagnostics (⌥⌘I)")
            }
            .fixedSize()
            .layoutPriority(2)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
    }

    /// Text tabs → symbol tabs → a pop-up menu, whichever fits first.
    private var sectionPicker: some View {
        @Bindable var model = model
        return ViewThatFits(in: .horizontal) {
            Picker("Section", selection: $model.diagSection) {
                ForEach(DiagSection.allCases, id: \.self) { section in
                    Text(title(for: section)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            // Symbols only (a segment holds a string or an image, not both);
            // names and problem counts move to the tooltip and VoiceOver.
            Picker("Section", selection: $model.diagSection) {
                ForEach(DiagSection.allCases, id: \.self) { section in
                    Image(systemName: section.symbol)
                        .accessibilityLabel(title(for: section))
                        .help(title(for: section))
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(DiagSection.allCases.map(title(for:)).joined(separator: " · "))

            Picker("Section", selection: $model.diagSection) {
                ForEach(DiagSection.allCases, id: \.self) { section in
                    Label(title(for: section), systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .labelsHidden()
    }

    private func problemCount(for section: DiagSection) -> Int {
        switch section {
        case .overview, .charts: return 0
        case .segments: return model.telemetry.problemRequestCount
        case .events: return model.telemetry.errorEventCount
        }
    }

    /// Problem counts ride along in the tab title (segmented controls have no badges).
    private func title(for section: DiagSection) -> String {
        let n = problemCount(for: section)
        return n > 0 ? "\(section.title) (\(n))" : section.title
    }
}

extension DiagSection {
    var title: String {
        switch self {
        case .overview: return "Summary"
        case .charts: return "Charts"
        case .segments: return "Segments"
        case .events: return "Events"
        }
    }

    /// For the compact tabs in the narrow window.
    var symbol: String {
        switch self {
        case .overview: return "list.bullet.rectangle"
        case .charts: return "chart.xyaxis.line"
        case .segments: return "square.stack.3d.up"
        case .events: return "list.bullet"
        }
    }
}

struct SettingsView: View {
    @AppStorage("autoOpenDiagnostics") private var autoOpenDiagnostics = false
    @AppStorage(Appearance.defaultsKey) private var appearance = Appearance.system
    @AppStorage(Updater.autoCheckKey) private var checkForUpdates = true

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: appearance) { _, new in new.apply() }
            Toggle("Show Diagnostics automatically when playback fails", isOn: $autoOpenDiagnostics)
            Text("Measurements are always recorded in the background, so Diagnostics shows the full history whenever you open it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if Updater.shared.isAvailable {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                Text("Once a day, Jancast asks GitHub for the newest release. Installing an update is always up to you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
