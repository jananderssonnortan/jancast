import AppKit
import SwiftUI

@main
struct JancastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.makeFromEnvironment()

    var body: some Scene {
        Window("Jancast", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 500, height: 900)
        .windowResizability(.contentSize)     // RootView caps the width
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Diagnostics Report") { AppModel.copyToPasteboard(model.diagnosticsReport()) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.hasSession)
        }
        CommandGroup(before: .sidebar) {
            Button(model.diagnosticsOpen ? "Hide Diagnostics" : "Show Diagnostics") { model.toggleDiagnostics() }
                // ⌥⌘I as for an inspector; ⌥⌘D is macOS's "Turn Dock Hiding On/Off".
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.backendStatus != .running)
            Divider()
        }
        CommandMenu("Playback") {
            Button(model.resumeEntry?.resumePosition != nil ? "Resume on Apple TV" : "Play on Apple TV") {
                model.play(startPosition: model.resumeEntry?.resumePosition)
            }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canPlay)
            // Space is handled by a key monitor (AppDelegate) so it never
            // steals spaces typed into text fields.
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                .disabled(!model.canControl)
            Button("Stop") { model.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.canControl)
            Divider()
            // Plain ← / → only while the player is the key window, so arrows in
            // forms, tables and search fields elsewhere are never captured.
            Button("Skip Forward 10 s") { model.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            Button("Skip Back 10 s") { model.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            Button("Skip Forward 30 s") { model.skip(30) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!model.canControl)
            Button("Skip Back 30 s") { model.skip(-30) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!model.canControl)
            Divider()
            // Plain ↑ / ↓ handled like ← / → (key monitor, player window only).
            Button("TV Volume Up") { model.changeTVVolume(up: true) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            Button("TV Volume Down") { model.changeTVVolume(up: false) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            Toggle("Mac Volume Keys Control the TV", isOn: Binding(
                get: { VolumeKeys.shared.enabled }, set: { VolumeKeys.shared.enabled = $0 }))
            Divider()
            Button("Scan for Apple TVs") { Task { await model.loadDevices(refresh: true) } }
                .keyboardShortcut("r")
                .disabled(model.scanning || model.backendStatus != .running)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            Snapshotter.scheduleIfRequested()
            VolumeKeys.shared.startIfEnabled()
        }

        let updateKey = {
            MainActor.assumeIsolated {
                AppModel.current?.mainWindowIsKey = NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in updateKey() }
        }
        // The main window may already be key before the observers exist.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { updateKey() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // ← / → (plain, or ⌘ via the menu): while held, skips only accumulate;
            // the TV jumps once the presses stop (shortly after the last release).
            if event.keyCode == 123 || event.keyCode == 124 {
                let down = event.type == .keyDown
                MainActor.assumeIsolated {
                    if down { AppModel.current?.skipKeyPressed() } else { AppModel.current?.skipKeyReleased() }
                }
                if !down { return event }
            }
            guard event.type == .keyDown else { return event }
            // The This Mac window: Esc leaves full screen; ← / → and Space below
            // control the session as in the main window (not AVKit's frame steps).
            let inPlayerWindow = event.window?.identifier?.rawValue == LocalPlayer.windowID
            if inPlayerWindow, event.keyCode == 53, event.window?.styleMask.contains(.fullScreen) == true {
                event.window?.toggleFullScreen(nil)
                return nil
            }
            // Plain ↑ / ↓ in the player: TV volume.
            if event.keyCode == 125 || event.keyCode == 126,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               !(event.window?.firstResponder is NSText),
               !(event.window?.firstResponder is NSTableView),
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, m.showsPlayer, m.canControl else { return false }
                    m.changeTVVolume(up: event.keyCode == 126)
                    return true
                }
                if handled { return nil }
            }
            // Plain ← / → in the player: quick relative skip (repeats accumulate in the model).
            if event.keyCode == 123 || event.keyCode == 124,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               !(event.window?.firstResponder is NSText),
               !(event.window?.firstResponder is NSTableView),   // Diagnostics drawer tables
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true || inPlayerWindow {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, m.showsPlayer || inPlayerWindow, m.canControl else { return false }
                    m.skip(event.keyCode == 124 ? 10 : -10)
                    return true
                }
                if handled { return nil }
            }
            guard event.keyCode == 49, // space
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty
            else { return event }
            // Let text fields, tables with type-select, etc. keep the space.
            if let responder = event.window?.firstResponder, responder is NSText || responder is NSTextView {
                return event
            }
            if event.window?.attachedSheet != nil || event.window?.isSheet == true { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let m = AppModel.current, m.canControl else { return false }
                m.togglePause()
                return true
            }
            return handled ? nil : event
        }
    }

    /// Finder "Open With…" / dropping a file on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        MainActor.assumeIsolated { AppModel.current?.requestOpen(path: url.path) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.current?.shutdown() }
    }
}
