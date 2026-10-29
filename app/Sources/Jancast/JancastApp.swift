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
        .defaultSize(width: RootView.width, height: 900)
        .windowResizability(.contentSize)     // RootView fixes the width
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
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.checkFromMenu() } }
        }
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
                .disabled(!model.canControl || model.pairingDeviceID != nil)   // ⌘. cancels the PIN sheet
            Divider()
            // Plain ← / → only while the player is the key window, so arrows in
            // forms, tables and search fields elsewhere are never captured.
            Button("Skip Forward 10 s") { model.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            Button("Skip Back 10 s") { model.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            // Only with the playing picture in front (not from another file's
            // ready screen); in text fields the key monitor keeps ⌘← / ⌘→.
            Button("Skip Forward 30 s") { model.skip(30) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!model.canControl || !model.skipKeysApply)
            Button("Skip Back 30 s") { model.skip(-30) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!model.canControl || !model.skipKeysApply)
            Divider()
            // ⌘↑ / ⌘↓, as in Music: plain ↑ / ↓ move through the library.
            Button("TV Volume Up") { model.changeTVVolume(up: true) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canControl)
            Button("TV Volume Down") { model.changeTVVolume(up: false) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!model.canControl)
            Menu("Sleep Timer") { SleepTimerItems().environment(model) }
                .disabled(!model.canControl)
            Toggle("Mac Volume Keys Control the TV", isOn: Binding(
                get: { VolumeKeys.shared.enabled }, set: { VolumeKeys.shared.enabled = $0 }))
            Divider()
            // ↑ / ↓ and ⌥↑ / ⌥↓ handled by the key monitor (main window only,
            // with Home / End and Page Up / Down); listed here so they can be found.
            Button("Previous in Library") { model.moveLibrarySelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!model.libraryHasKeyFocus)
            Button("Next in Library") { model.moveLibrarySelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!model.libraryHasKeyFocus)
            Button("First in Library") { model.moveLibrarySelection(toLast: false) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(!model.libraryHasKeyFocus)
            Button("Last in Library") { model.moveLibrarySelection(toLast: true) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(!model.libraryHasKeyFocus)
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
            Appearance.saved.apply()
            Snapshotter.scheduleIfRequested()
            VolumeKeys.shared.startIfEnabled()
        }

        let updateKey = {
            MainActor.assumeIsolated {
                AppModel.current?.mainWindowIsKey = NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true
                AppModel.current?.playerWindowIsKey = NSApp.keyWindow?.identifier?.rawValue == LocalPlayer.windowID
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in updateKey() }
        }
        // An arrow held while switching apps never sends its key-up here.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.current?.skipKeyReleased() }
        }
        // The main window may already be key before the observers exist.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { updateKey() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // ← / → (plain, or ⌘ via the menu): while held, skips only accumulate;
            // the TV jumps once the presses stop (shortly after the last release).
            // Pressed is noted only where the key skips (below and for ⌘ ← / →).
            if event.keyCode == 123 || event.keyCode == 124, event.type == .keyUp {
                MainActor.assumeIsolated { AppModel.current?.skipKeyReleased() }
                return event
            }
            guard event.type == .keyDown else { return event }
            let responder = event.window?.firstResponder
            // ⌘ + arrows in a text field (PIN, Events filter, Settings) edit the
            // text: hand them over before the menu's skip / volume shortcuts.
            if [123, 124, 125, 126].contains(Int(event.keyCode)),
               event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               let text = responder as? NSTextView {
                text.keyDown(with: event)
                return nil
            }
            if event.keyCode == 123 || event.keyCode == 124, event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated {
                    if AppModel.current?.skipKeysApply == true { AppModel.current?.skipKeyPressed() }
                }
            }
            // The This Mac window: Esc leaves its full screen (whichever window has
            // the keys, unless a sheet or text field wants Esc); ← / → and Space
            // below control the session as in the main window (not AVKit's frame steps).
            let inPlayerWindow = event.window?.identifier?.rawValue == LocalPlayer.windowID
            if event.keyCode == 53, event.window?.attachedSheet == nil, !(event.window?.firstResponder is NSText),
               let player = NSApp.windows.first(where: { $0.identifier?.rawValue == LocalPlayer.windowID && $0.styleMask.contains(.fullScreen) }) {
                player.toggleFullScreen(nil)
                return nil
            }
            // The library, also while something plays (TV volume is ⌘↑ / ⌘↓,
            // in the menu): ↑ / ↓ the previous / next file, ⌥↑ / ⌥↓ and Home /
            // End the first / last, Page Up / Down (fn ↑ / ↓) a few rows.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Tab / ⇧Tab move Jancast's own focus over the remote's controls
            // (KeyFocus.swift), also with macOS keyboard navigation off. Return /
            // Space work the focused control, ↑ / ↓ open a focused menu (and no
            // longer move the list), Esc goes back to the library.
            if (event.keyCode == 48 && (mods.isEmpty || mods == .shift))
                || (mods.isEmpty && [36, 76, 49, 53, 125, 126].contains(event.keyCode)),
               !(responder is NSText), !(responder is NSTableView),
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, m.backendStatus == .running, m.pairingDeviceID == nil else { return false }
                    switch event.keyCode {
                    case 48:
                        m.moveKeyFocus(back: mods == .shift)
                        return true
                    case 53:
                        guard m.keyFocus != .library else { return false }
                        m.keyFocus = .library
                        return true
                    case 125, 126:
                        guard m.keyFocus != .library else { return false }
                        _ = m.activateKeyFocus(menusOnly: true)
                        return true
                    default:
                        return m.activateKeyFocus()
                    }
                }
                if handled { return nil }
            }
            let libraryMove: ((AppModel) -> Void)? = switch (event.keyCode, mods) {
            case (126, []): { $0.moveLibrarySelection(by: -1) }
            case (125, []): { $0.moveLibrarySelection(by: 1) }
            case (126, .option), (115, []): { $0.moveLibrarySelection(toLast: false) }
            case (125, .option), (119, []): { $0.moveLibrarySelection(toLast: true) }
            case (116, []): { $0.moveLibrarySelection(by: -AppModel.libraryPage) }
            case (121, []): { $0.moveLibrarySelection(by: AppModel.libraryPage) }
            default: nil
            }
            if let libraryMove,
               !(event.window?.firstResponder is NSText),
               !(event.window?.firstResponder is NSTableView),
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, m.backendStatus == .running, m.pairingDeviceID == nil,
                          m.keyFocus == .library else { return false }
                    libraryMove(m)
                    return true
                }
                if handled { return nil }
            }
            // Return / Enter on the ready screen: play the selected file. Only when
            // there is one to play (else Return stays with the default button,
            // e.g. "Choose File…"), and not in the Diagnostics tables.
            if event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               !(event.window?.firstResponder is NSText),
               !(event.window?.firstResponder is NSTableView),
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, !m.showsPlayer, m.backendStatus == .running, m.pairingDeviceID == nil,
                          m.libraryCursor != nil || m.canPlay else { return false }
                    m.playLibrarySelection()
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
                    m.skipKeyPressed()
                    m.skip(event.keyCode == 124 ? 10 : -10)
                    if inPlayerWindow { m.localPlayer.revealControls() }
                    return true
                }
                if handled { return nil }
            }
            // The This Mac window: plain ↑ / ↓ would step AVKit's picture; they
            // only bring up the control bar (TV volume is ⌘↑ / ⌘↓).
            if inPlayerWindow, event.keyCode == 125 || event.keyCode == 126,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                MainActor.assumeIsolated { AppModel.current?.localPlayer.revealControls() }
                return nil
            }
            guard event.keyCode == 49, // space
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty
            else { return event }
            // Only in the main and This Mac windows (not Settings); text fields and
            // tables keep the space, and so does a button focused with Full
            // Keyboard Access (Space presses it).
            guard event.window?.identifier?.rawValue.hasPrefix("main") == true || inPlayerWindow else { return event }
            if responder is NSText || responder is NSTableView { return event }
            if NSApp.isFullKeyboardAccessEnabled, responder is NSControl { return event }
            if event.window?.attachedSheet != nil || event.window?.isSheet == true { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let m = AppModel.current, m.canControl else { return false }
                m.togglePause()
                if inPlayerWindow { m.localPlayer.revealControls() }
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
