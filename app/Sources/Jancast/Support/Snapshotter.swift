import AppKit

/// Development aid: renders the app's own window to PNG files without needing
/// Screen Recording permission. Enabled only when JANCAST_SNAPSHOT_DIR is set.
///
///   JANCAST_SNAPSHOT_DIR=/tmp/shots JANCAST_SNAPSHOT_PLAN="setup@3,overview@25" Jancast --mock
///
/// Each plan entry is <page>@<seconds after launch>; optional ":dark" suffix
/// renders in dark mode. Pages: player, setup, empty (drawer closed), a
/// Diagnostics tab (overview, charts, segments, events — opens the drawer on
/// it), diagwin (drawer open, tab unchanged), do-arrowright3 / do-arrowleft
/// (synthesized arrow keys to the player) or do-pause (toggle pause). The app quits after the last
/// snapshot when JANCAST_SNAPSHOT_QUIT=1.
@MainActor
enum Snapshotter {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["JANCAST_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let plan = (env["JANCAST_SNAPSHOT_PLAN"] ?? "overview@20").split(separator: ",")
        var latest = 0.0
        let size = env["JANCAST_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        for entry in plan {
            let parts = entry.split(separator: "@")
            guard parts.count == 2 else { continue }
            let page = String(parts[0])
            var timeSpec = String(parts[1])
            var dark = false
            if timeSpec.hasSuffix(":dark") { dark = true; timeSpec = String(timeSpec.dropLast(5)) }
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
                        for w in NSApp.windows where w.isVisible && w.frame.height > 200 {
                            w.setFrame(NSRect(x: 0, y: 0, width: size[0], height: size[1]), display: true)
                        }
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
            // Setting the appearance right before capturing forces a full redraw,
            // which cacheDisplay needs for layer-backed content (Form, Table).
            DispatchQueue.main.asyncAfter(deadline: .now() + t - 0.8) {
                MainActor.assumeIsolated { NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                MainActor.assumeIsolated {
                    capture(to: URL(fileURLWithPath: dir).appendingPathComponent("\(page)-\(Int(t))\(dark ? "-dark" : "").png"))
                }
            }
        }
        if env["JANCAST_SNAPSHOT_QUIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + latest + 1) { NSApp.terminate(nil) }
        }
    }

    static func capture(to url: URL) {
        guard let window = mainWindow, let view = window.contentView?.superview ?? window.contentView else { return }
        var target: NSView = view
        if ProcessInfo.processInfo.environment["JANCAST_SNAPSHOT_FULL"] == "1", url.lastPathComponent.hasPrefix("overview"),
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
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
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

    static func logPlayer(_ label: String) {
        guard let m = AppModel.current else { return }
        let skips = m.telemetry.events.filter { ($0.message ?? "").hasPrefix("Skip") }.map { $0.message ?? "" }
        print("[snapshot] \(label): tv=\(Fmt.clock(m.live?.playback?.position)) shown=\(Fmt.clock(m.displayPosition)) hint=\(m.skipHint.map { String(format: "%+.0f", $0) } ?? "-") skipRequests=\(skips)")
        fflush(stdout)
    }

    /// Plain-arrow tests against the player, e.g. "arrowright3" (three → presses).
    static func perform(_ action: String) {
        if action == "pause" { AppModel.current?.togglePause(); return }
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
