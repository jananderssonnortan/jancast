import AppKit

/// Development aid: renders the app's own window to PNG files without needing
/// Screen Recording permission. Enabled only when LUFTBRO_SNAPSHOT_DIR is set.
///
///   LUFTBRO_SNAPSHOT_DIR=/tmp/shots LUFTBRO_SNAPSHOT_PLAN="setup@3,overview@25" Luftbro --mock
///
/// Each plan entry is <page>@<seconds after launch> (a ":dark" suffix is
/// accepted and ignored; the app is always dark). Pages: player, setup, empty (drawer closed), a
/// Diagnostics tab (overview, charts, segments, events — opens the drawer on
/// it), diagwin (drawer open, tab unchanged), do-arrowright3 / do-arrowleft
/// (synthesized arrow keys to the player), do-pause (toggle pause),
/// do-playrecent (play the first recent file), do-seek75, do-libdown /
/// do-libup (the library's ↓ / ↑), do-stop, do-return (play the selection),
/// do-openrecent1, do-openmatchQuiet (by name), do-front or do-moveplayer. The app quits after the last
/// snapshot when LUFTBRO_SNAPSHOT_QUIT=1.
@MainActor
enum Snapshotter {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["LUFTBRO_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let plan = (env["LUFTBRO_SNAPSHOT_PLAN"] ?? "overview@20").split(separator: ",")
        var latest = 0.0
        let size = env["LUFTBRO_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        for entry in plan {
            let parts = entry.split(separator: "@")
            guard parts.count == 2 else { continue }
            let page = String(parts[0])
            var timeSpec = String(parts[1])
            if timeSpec.hasSuffix(":dark") { timeSpec = String(timeSpec.dropLast(5)) }
            guard let t = Double(timeSpec) else { continue }
            latest = max(latest, t)
            if page.hasPrefix("do-") {
                // Synthesized input against the player, e.g. do-arrowright3.
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    MainActor.assumeIsolated { perform(String(page.dropFirst(3))) }
                }
                continue
            }
            if let size, size.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + t - 1.2) {
                    MainActor.assumeIsolated {
                        // The main window only (not This Mac's player or the Diagnostics panel).
                        mainWindow?.setFrame(NSRect(x: 0, y: 0, width: size[0], height: size[1]), display: true)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t - 2.5) {
                MainActor.assumeIsolated {
                    guard let m = AppModel.current else { return }
                    if let item = DiagSection(rawValue: page) { m.showDiagnostics(item) }
                    if page == "diagwin" { m.showDiagnostics() }   // keep the tab
                    if ["setup", "empty", "player"].contains(page) { m.diagnosticsOpen = false }
                    if page == "setup" { m.playerVisible = false }
                    if page == "empty" { m.playerVisible = false; m.closeFile() }
                    if page == "player" { m.playerVisible = true }
                }
            }
            // Changing the appearance right before capturing forces a full redraw,
            // which cacheDisplay needs for layer-backed content (Form, Table). Both
            // in one turn of the run loop, so nothing is ever drawn light.
            DispatchQueue.main.asyncAfter(deadline: .now() + t - 0.8) {
                MainActor.assumeIsolated {
                    NSApp.appearance = NSAppearance(named: .aqua)
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                MainActor.assumeIsolated {
                    capture(to: URL(fileURLWithPath: dir).appendingPathComponent("\(page)-\(Int(t)).png"))
                }
            }
        }
        if env["LUFTBRO_SNAPSHOT_QUIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + latest + 1) { NSApp.terminate(nil) }
        }
    }

    static func capture(to url: URL) {
        guard let window = mainWindow, let view = window.contentView?.superview ?? window.contentView else { return }
        var target: NSView = view
        if ProcessInfo.processInfo.environment["LUFTBRO_SNAPSHOT_FULL"] == "1", url.lastPathComponent.hasPrefix("overview"),
           let doc = largestScrollDocument(in: view) {
            target = doc   // whole scrollable content, not just the visible part
        }
        let bounds = target.bounds
        guard let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        target.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private static func largestScrollDocument(in view: NSView) -> NSView? {
        var best: NSView?
        func visit(_ v: NSView) {
            if let sv = v as? NSScrollView, let doc = sv.documentView,
               doc.bounds.height > (best?.bounds.height ?? 0), doc.bounds.width > 400 {
                best = doc
            }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    // MARK: - Synthesized input (development aid)

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true
            && $0.identifier?.rawValue != DiagnosticsSidePanel.identifier }
    }

    private static func postArrow(_ right: Bool, to w: NSWindow) {
        let ch = String(Character(UnicodeScalar(right ? 0xF703 : 0xF702)!))
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                     context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                     isARepeat: false, keyCode: right ? 124 : 123) {
            NSApp.postEvent(ev, atStart: false)
        }
    }

    private static func postKey(down: Bool, to w: NSWindow) {
        let ch = String(Character(UnicodeScalar(down ? 0xF701 : 0xF700)!))
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                     context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                     isARepeat: false, keyCode: down ? 125 : 126) {
            NSApp.postEvent(ev, atStart: false)
        }
    }

    static func logPlayer(_ label: String) {
        guard let m = AppModel.current else { return }
        let skips = m.telemetry.events.filter { ($0.message ?? "").hasPrefix("Skip") }.map { $0.message ?? "" }
        print("[snapshot] \(label): tv=\(Fmt.clock(m.live?.playback?.position)) shown=\(Fmt.clock(m.displayPosition)) hint=\(m.skipHint.map { String(format: "%+.0f", $0) } ?? "-") skipRequests=\(skips)")
        fflush(stdout)
    }

    /// Plain-arrow tests against the player, e.g. "arrowright3" (three → presses).
    static func perform(_ action: String) {
        if action == "pause" { AppModel.current?.togglePause(); return }
        // Play the first recent file / jump to a time, e.g. "seek75".
        if action == "playrecent" {
            if let m = AppModel.current, let e = m.recents.first { m.playNow(e) }
            return
        }
        // The library's ↑ / ↓ and Stop, as the keys do them.
        if action == "libdown" { AppModel.current?.moveLibrarySelection(by: 1); return }
        if action == "libup" { AppModel.current?.moveLibrarySelection(by: -1); return }
        if action == "stop" { AppModel.current?.stop(); return }
        if action == "return" { AppModel.current?.playLibrarySelection(); return }
        // Open the n-th Recent entry (0 = top), as a click does.
        if action.hasPrefix("openrecent"), let n = Int(action.dropFirst(10)) {
            guard let m = AppModel.current, m.recents.indices.contains(n) else { return }
            let e = m.recents[n]
            m.playerVisible = false
            Task { await m.openFile(path: e.path, history: e) }
            return
        }
        // Open the Recent entry whose file name contains the text ("openmatchQuiet").
        if action.hasPrefix("openmatch") {
            let text = action.dropFirst(9)
            guard let m = AppModel.current,
                  let e = m.recents.first(where: { ($0.path as NSString).lastPathComponent.contains(text) }) else { return }
            m.playerVisible = false
            Task { await m.openFile(path: e.path, history: e) }
            return
        }
        // The main window in front, as the key window (an active-looking capture).
        if action == "front" {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
            return
        }
        // This Mac's player window to the screen's right edge, clear of the
        // main window and the Diagnostics panel (for screenshots).
        if action == "moveplayer" {
            guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == LocalPlayer.windowID }),
                  let screen = w.screen ?? NSScreen.main else { return }
            w.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - w.frame.width, y: screen.visibleFrame.minY))
            return
        }
        // A click at a fraction of the main window ("click0.75x0.5": x from the
        // left, y from the bottom), posted as mouse down / up inside the app.
        if action.hasPrefix("click") {
            let f = action.dropFirst(5).split(separator: "x").compactMap { Double($0) }
            guard f.count == 2, let w = mainWindow, let v = w.contentView else { return }
            w.makeKeyAndOrderFront(nil)
            let p = NSPoint(x: v.bounds.width * f[0], y: v.bounds.height * f[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(ev, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    print("[snapshot] click at \(f): hit=\(v.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil") firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
                    fflush(stdout)
                }
            }
            return
        }
        // A real ↓ key event into the main window (through the key monitor),
        // then where the keyboard focus is and what the library selects.
        if action == "keydown" {
            guard let w = mainWindow else { return }
            w.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated {
                    let before = AppModel.current?.libraryCursor ?? AppModel.current?.probe?.path ?? "-"
                    postKey(down: true, to: w)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated {
                            let m = AppModel.current
                            let after = m?.libraryCursor ?? m?.probe?.path ?? "-"
                            print("[snapshot] keydown: firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") keyFocus=\(String(describing: m?.keyFocus)) moved=\(before != after) (\((before as NSString).lastPathComponent) -> \((after as NSString).lastPathComponent))")
                            fflush(stdout)
                        }
                    }
                }
            }
            return
        }
        if action.hasPrefix("seek"), let t = Double(action.dropFirst(4)) {
            AppModel.current?.seek(to: t)
            return
        }
        guard action.hasPrefix("arrow") else { print("[snapshot] unknown action \(action)"); return }
        let right = action.hasPrefix("arrowright")
        let count = Int(action.drop { !$0.isNumber }) ?? 1
        guard let w = mainWindow else { print("[snapshot] \(action): window not found"); return }
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                for _ in 0..<count { postArrow(right, to: w) }
                let m = AppModel.current
                print("[snapshot] posted \(count)× \(right ? "→" : "←") keyWindow=\(NSApp.keyWindow?.identifier?.rawValue ?? "nil") playerHasKeyFocus=\(m?.playerHasKeyFocus ?? false) canControl=\(m?.canControl ?? false) firstResponder=\(String(describing: w.firstResponder.map { type(of: $0) }))")
                for d in [0.15, 1.5, 3.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                        MainActor.assumeIsolated { logPlayer("+\(d)s after \(action)") }
                    }
                }
            }
        }
    }
}
