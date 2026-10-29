import SwiftUI

/// Main window: the remote (stream, or the loaded file ready to play) with
/// the library under it, and the opt-in Diagnostics drawer sliding
/// up from the bottom.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @AppStorage("diagnosticsDrawerHeight") private var drawerHeight = 380.0

    /// The window is remote-shaped and its width fixed: exactly the remote's
    /// column, so every screen gets the same layout. Only the height changes
    /// (from 640 pt, which fits the smallest MacBook screens).
    static let width = RemoteLayout.columnWidth

    /// Remote height the drawer leaves when it can (pill to transport).
    private static let remoteKeep = 560.0

    /// Space the player / setup form keeps above the drawer.
    private static let minContentHeight = 320.0

    var body: some View {
        @Bindable var model = model
        detail
        // The film's accent everywhere, the drawer and toolbar included.
        .tint(model.ambience?.tint)
        .frame(width: Self.width)
        .frame(minHeight: 640)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .modifier(HiddenWindowTitle())
        .modifier(ClearToolbar())
        .modifier(WindowBackdrop())
        .dropDestination(for: URL.self) { urls, _ in
            guard model.backendStatus == .running, let url = urls.first(where: { $0.isFileURL }) else { return false }
            model.playerVisible = false
            Task { await model.openFile(path: url.path) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .environment(\.isDropTargeted, dropTargeted)
        .task { await model.start() }
        .sheet(isPresented: Binding(get: { model.pairingDeviceID != nil }, set: { if !$0 { model.cancelPairing() } })) {
            PinSheet().environment(model)
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
    }

    private var detail: some View {
        GeometryReader { geo in
            // The drawer takes the library's space first and only then the
            // remote's: it leaves the remote up to the transport (≈560 pt).
            let keep = max(Self.minContentHeight, min(Double(model.remoteHeight), Self.remoteKeep))
            let maxDrawer = max(DiagnosticsDrawer.minHeight, geo.size.height - keep)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.diagnosticsOpen && model.backendStatus == .running {
                    let h = min(max(drawerHeight, DiagnosticsDrawer.minHeight), maxDrawer)
                    DiagnosticsDrawer(height: $drawerHeight, maxHeight: maxDrawer)
                        .frame(height: h)
                        .transition(.modifier(active: DrawerReveal(fraction: 0, height: h),
                                              identity: DrawerReveal(fraction: 1, height: h)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Animated opening only: while the drawer shrinks away its AppKit
            // controls aren't clipped and linger as ghost text, so it closes at once.
            .animation(model.diagnosticsOpen ? .snappy(duration: 0.28) : nil, value: model.diagnosticsOpen)
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            switch model.backendStatus {
            case .starting:
                Color.clear
            case .failed(let message, let log):
                BackendFailedView(message: message, log: log)
            case .running:
                // Laid out (and measured) while hidden; shown at once when ready.
                RemoteLayout()
                    .opacity(model.ready ? 1 : 0)
                    .allowsHitTesting(model.ready)
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.ready)
        .overlay {
            if case .failed = model.backendStatus {} else if !model.ready { StartingView() }
        }
    }

    private var title: String {
        if model.showsPlayer, let file = model.live?.session?.file, let name = file.name {
            return Fmt.name(name, file.nameInfo).title
        }
        return "Jancast"
    }

    private var subtitle: String {
        if model.isMock { return "Mock mode — simulated data" }
        return ""
    }
}

/// Opens the drawer by growing its height (a layout change), its top edge
/// rising with the header on it. A `.move` transition only offsets the
/// drawing, and AppKit-backed controls (the tab picker, buttons) don't follow
/// that: they appeared in place while the rest slid up.
private struct DrawerReveal: ViewModifier, Animatable {
    var fraction: Double
    let height: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height, alignment: .top)
            .frame(height: height * fraction, alignment: .top)
            .clipped()
    }
}

/// The now card already shows the title, and the narrow toolbar needs the
/// room for the device menu: the title stays set (Window menu, Mission
/// Control) but isn't drawn. (macOS 14 keeps drawing it.)
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// The toolbar lets the remote's backdrop show through instead of drawing a
/// band of its own above it (macOS 15+; older systems keep the band).
private struct ClearToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// The remote's ambience as the window's background: from the top of the
/// window (under the toolbar) to about where the library starts (a fixed
/// height, `RemoteLayout.backdropHeight`),
/// over a fainter wash of the same colours under the library.
private struct WindowBackdrop: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(for: .window) {
                GeometryReader { geo in
                    AmbientBackdrop(image: model.ambience?.backdrop, scene: model.backdropScene)
                        .frame(height: min(model.remoteTop + RemoteLayout.backdropHeight, geo.size.height))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .background {
                    LibraryWash(palette: model.washPalette, fallback: model.ambience?.backdrop).background(.background)
                }
            }
        } else {
            content
        }
    }
}

private struct DropTargetedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isDropTargeted: Bool {
        get { self[DropTargetedKey.self] }
        set { self[DropTargetedKey.self] = newValue }
    }
}

private struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        // Where it plays, and how the stream is doing, live here — once —
        // so the remote starts at what is on.
        // Plain text and icon, not a glass capsule: it reads as where it
        // plays, not as one more button (macOS 26; older systems keep the capsule).
        if #available(macOS 26.0, *) {
            deviceItem.sharedBackgroundVisibility(.hidden)
        } else {
            deviceItem
        }
        // Without the title there is no flexible space before the buttons, so
        // they would sit right after the TV menu instead of at the right edge.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.presentOpenPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open a video (⌘O)")
            Toggle(isOn: Binding(get: { model.diagnosticsOpen }, set: { model.diagnosticsOpen = $0 })) {
                Label { Text("Diagnostics") } icon: { DiagnosticsGlyph() }
            }
            .help(diagnosticsHelp)
            .disabled(model.backendStatus != .running)
        }
    }

    private var deviceItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Group {
                if model.showsPlayer, let name = model.live?.session?.device?.name {
                    DeviceSwitchMenu(name: name)
                } else if model.backendStatus == .running && model.ready {
                    DevicePicker()
                }
            }
            .padding(.leading, Self.deviceInset)
        }
    }

    /// On macOS 26 the menu is bare text right after the window buttons, which
    /// looks cramped; older systems draw it in a capsule that already has room.
    private static var deviceInset: CGFloat {
        if #available(macOS 26.0, *) { return 14 }
        return 0
    }

    private var diagnosticsHelp: String {
        let h = model.streamHealth
        let state = !DiagnosticsGlyph.showsHealth(model) ? "" : h <= .good ? " — stream healthy"
            : " — " + (model.live?.diagnosis?.headline ?? "stream problem")
        return (model.diagnosticsOpen ? "Hide Diagnostics (⌥⌘I)" : "Show Diagnostics (⌥⌘I)") + state
    }
}

/// The Diagnostics button's glyph: a small coloured dot when the stream has a
/// problem (none while healthy — calm), bouncing once when it gets worse.
private struct DiagnosticsGlyph: View {
    @Environment(AppModel.self) private var model

    /// Only for a stream that runs, or one whose remote is still on screen
    /// (a failure being looked at) — not an old failed or finished one once
    /// another file is loaded.
    static func showsHealth(_ model: AppModel) -> Bool {
        model.hasSession && (model.phase.isActive || model.showsPlayer)
    }

    var body: some View {
        let h = model.streamHealth
        let shown = Self.showsHealth(model)
        Image(systemName: "waveform.path.ecg")
            .overlay(alignment: .topTrailing) {
                if shown && h >= .warning {
                    Circle().fill(h.color)
                        .frame(width: 7, height: 7)
                        .offset(x: 4, y: -3)
                }
            }
            .symbolEffect(.bounce, value: model.healthAlertTick)
            .accessibilityValue(!shown ? "" : h <= .good ? "Stream healthy" : "Stream problem")
    }
}

/// Only when starting takes a while (the first run, a slow disk): a quick
/// launch shows just the window's colours and then the remote, no flash of this.
private struct StartingView: View {
    @State private var shown = false
    @State private var slow = false

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Starting Jancast…").font(.title3)
            Text("Launching the streaming backend").foregroundStyle(.secondary)
            if slow {
                Text("The first start after installing or updating can take up to a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .transition(.opacity)
            }
        }
        .animation(.easeIn(duration: 0.3), value: slow)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .animation(.easeIn(duration: 0.3), value: shown)
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            shown = true
            try? await Task.sleep(for: .seconds(7))
            slow = true
        }
    }
}

private struct BackendFailedView: View {
    @Environment(AppModel.self) private var model
    let message: String
    let log: String

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("The Backend Couldn’t Start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                HStack {
                    Button("Try Again") { Task { await model.restartBackend() } }
                        .keyboardShortcut(.defaultAction)
                    if !log.isEmpty {
                        Button("Copy Log") { AppModel.copyToPasteboard(log) }
                    }
                }
            }
            .frame(maxHeight: 260)
            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backend output (stderr)").font(.headline)
                    ScrollView {
                        Text(String(log.suffix(6000)))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 30)
            }
            Text(BackendProcess.bundledRuntime != nil
                 ? "The backend is inside the app. Launch with --mock to preview the app without it."
                 : "Backend folder: \(BackendProcess.backendDirectory.path) (override with JANCAST_BACKEND_DIR). Launch with --mock to preview the app without it.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
