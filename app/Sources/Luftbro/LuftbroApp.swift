import AppKit
import SwiftUI

@main
struct LuftbroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.makeFromEnvironment()

    var body: some Scene {
        Window("Luftbro", id: "main") {
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

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.checkFromMenu() } }
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit Luftbro") { AppDelegate.quit() }
                .keyboardShortcut("q")
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
            Button("Skip Forward 10 s (→)") { model.skip(10) }
                .disabled(!model.canControl || !model.playerHasKeyFocus)
            Button("Skip Back 10 s (←)") { model.skip(-10) }
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
            // On This Mac: the player's own volume.
            Button(model.playsOnThisMac ? "Volume Up" : "TV Volume Up") { model.changeTVVolume(up: true) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canControl)
            Button(model.playsOnThisMac ? "Volume Down" : "TV Volume Down") { model.changeTVVolume(up: false) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!model.canControl)
            // Plain keys (M, H / J, the arrows) are handled by the key monitor,
            // which steps aside for text fields; as menu shortcuts they'd take
            // those keys from a text field. Listed here with the key, so they
            // can be found.
            Button(model.playsOnThisMac && model.localPlayer.adjustments.muted ? "Unmute (M)" : "Mute (M)") {
                model.toggleThisMacMute()
            }
                .disabled(!model.muteKeyApplies)
            // Plain H / J as in VLC on the Mac; the key monitor handles them
            // (not in text fields), listed here so they can be found.
            Button("Subtitles Earlier (H)") { model.nudgeSubtitleDelay(by: -AppModel.subtitleDelayStep) }
                .disabled(!model.subtitleDelayKeysApply)
            Button("Subtitles Later (J)") { model.nudgeSubtitleDelay(by: AppModel.subtitleDelayStep) }
                .disabled(!model.subtitleDelayKeysApply)
            Divider()
            Menu("Sleep Timer") { SleepTimerItems().environment(model) }
                .disabled(!model.canControl)
            Toggle("Mac Volume Keys Control the TV", isOn: Binding(
                get: { VolumeKeys.shared.enabled }, set: { VolumeKeys.shared.enabled = $0 }))
            Divider()
            // ↑ / ↓ and ⌥↑ / ⌥↓ handled by the key monitor (main window only,
            // with Home / End and Page Up / Down); listed here so they can be found.
            Button("Previous in Library (↑)") { model.moveLibrarySelection(by: -1) }
                .disabled(!model.libraryHasKeyFocus)
            Button("Next in Library (↓)") { model.moveLibrarySelection(by: 1) }
                .disabled(!model.libraryHasKeyFocus)
            Button("First in Library (⌥↑)") { model.moveLibrarySelection(toLast: false) }
                .disabled(!model.libraryHasKeyFocus)
            Button("Last in Library (⌥↓)") { model.moveLibrarySelection(toLast: true) }
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

    /// AppKit refuses to quit while a window has a sheet (the PIN sheet, an
    /// alert): ⌘Q beeps and `osascript -e 'quit app "Luftbro"'` fails with
    /// "User canceled". Every quit goes through here instead, which closes the
    /// sheets first and quits once they're gone.
    @MainActor static func quit() {
        let sheets = NSApp.windows.compactMap { w in w.attachedSheet.map { (w, $0) } }
        guard !sheets.isEmpty else { NSApp.terminate(nil); return }
        if let m = AppModel.current {
            if m.pairingDeviceID != nil { m.cancelPairing() }
            m.alert = nil
        }
        for (window, sheet) in sheets where window.attachedSheet === sheet { window.endSheet(sheet) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Replaces AppKit's handler for the quit Apple Event (AppleScript, the
        // Dock's Quit, logging out), so those close sheets first too.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { AppDelegate.quit() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            // Dark only: the film's colours glow on it, and there is one look to get right.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            Snapshotter.scheduleIfRequested()
            VolumeKeys.shared.startIfEnabled()
            PlayerTouchBar.shared.install()
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
            // Tab / ⇧Tab move Luftbro's own focus over the remote's controls
            // (KeyFocus.swift), also with macOS keyboard navigation off. Return
            // works the focused control (Space always plays or pauses what the
            // library has selected, below), ↑ / ↓ open a focused menu (rather
            // than move the list), Esc goes back to the library.
            if (event.keyCode == 48 && (mods.isEmpty || mods == .shift))
                || (mods.isEmpty && [36, 76, 53, 125, 126].contains(event.keyCode)),
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
                        guard m.keyFocus != .library else {
                            // Browsing during playback: back to what plays.
                            guard m.libraryBrowsesOnly, m.libraryCursor != nil else { return false }
                            m.libraryCursor = nil
                            return true
                        }
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
                    guard let m = AppModel.current, m.backendStatus == .running, m.pairingDeviceID == nil,
                          // While playing: only a browsed row (Return plays it).
                          m.showsPlayer ? m.libraryCursor != nil : (m.libraryCursor != nil || m.canPlay)
                    else { return false }
                    m.playLibrarySelection()
                    return true
                }
                if handled { return nil }
            }
            // Esc in a Diagnostics table: the keys go back to the library and player.
            if event.keyCode == 53, mods.isEmpty, responder is NSTableView,
               event.window?.identifier?.rawValue.hasPrefix("main") == true {
                event.window?.makeFirstResponder(nil)
                return nil
            }
            // Plain ← / → in the player: quick relative skip (repeats accumulate in
            // the model), also with a Diagnostics table focused (it uses ↑ / ↓ only).
            if event.keyCode == 123 || event.keyCode == 124,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               !(event.window?.firstResponder is NSText),
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
            // Plain H / J: subtitles half a second earlier / later (AVKit's own
            // J would shuttle backwards in the This Mac window).
            if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased(), ch == "h" || ch == "j",
               !(responder is NSText),
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true || inPlayerWindow {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, m.backendStatus == .running, m.pairingDeviceID == nil,
                          m.subtitleDelayApplies else { return false }
                    m.nudgeSubtitleDelay(by: ch == "h" ? -AppModel.subtitleDelayStep : AppModel.subtitleDelayStep)
                    return true
                }
                if handled { return nil }
            }
            // Plain J / K / L in the This Mac window: AVKit's shuttle (2×, reverse,
            // pause) behind the session's back. J is the subtitle nudge above
            // when there are subtitles; otherwise these keys do nothing there.
            if inPlayerWindow, mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased(),
               ["j", "k", "l"].contains(ch) {
                return nil
            }
            // Plain M: mute This Mac (the remote or the This Mac window).
            if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "m",
               !(responder is NSText),
               event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true || inPlayerWindow {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let m = AppModel.current, m.muteKeyApplies else { return false }
                    m.toggleThisMacMute()
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
            if responder is NSText { return event }          // a table has no use for Space
            if NSApp.isFullKeyboardAccessEnabled, responder is NSControl { return event }
            if event.window?.attachedSheet != nil || event.window?.isSheet == true { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let m = AppModel.current else { return false }
                // The This Mac window: what it shows. The main window: what the
                // library has selected, wherever Tab focus is.
                guard !inPlayerWindow else {
                    guard m.canControl else { return false }
                    if !m.spaceRunsMarker() { m.togglePause() }
                    m.localPlayer.revealControls()
                    return true
                }
                return m.playOrPauseLibrarySelection()
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
