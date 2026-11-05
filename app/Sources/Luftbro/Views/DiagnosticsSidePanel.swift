import AppKit
import SwiftUI

/// Diagnostics as a panel that slides out from beneath the main window, like
/// the drawers of classic Mac apps. The main window keeps its size and place,
/// so the remote, the TV menu and the toolbar buttons never move (widening the
/// window would move the Diagnostics button ~520 pt and slide the remote). The
/// panel is a child window ordered below the main one: it follows it, and is
/// tucked a few points under its edge. To the right when the screen has room,
/// else to the left; else (or in full screen) the drawer under the remote.
@MainActor
final class DiagnosticsSidePanel: NSObject {
    static let shared = DiagnosticsSidePanel()
    /// Starts with "main": the app's key handling treats it as the main window
    /// (keys pressed while it has the focus act on the library and player).
    static let identifier = "main.diagnostics"
    static let width: CGFloat = 520
    /// How far it reaches under the main window, and how much shorter it is.
    private static let overlap: CGFloat = 8
    private static let inset: CGFloat = 14

    private enum Side { case left, right }

    private var panel: SidePanel?
    private var side: Side = .right
    private var observers: [NSObjectProtocol] = []

    static var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.identifier?.rawValue != identifier && !($0 is NSPanel)
        }
    }

    /// Slides the panel out; false when there is no room beside the window
    /// (then the drawer under the remote is used).
    func show(model: AppModel) -> Bool {
        guard let main = Self.mainWindow, let screen = main.screen, !main.styleMask.contains(.fullScreen) else { return false }
        let visible = screen.visibleFrame
        if main.frame.maxX - Self.overlap + Self.width <= visible.maxX {
            side = .right
        } else if main.frame.minX + Self.overlap - Self.width >= visible.minX {
            side = .left
        } else {
            return false
        }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        panel.setFrame(hiddenFrame(main), display: false)
        main.addChildWindow(panel, ordered: .below)
        panel.orderFront(nil)
        main.addChildWindow(panel, ordered: .below)      // ordered below again after orderFront
        move(panel, to: shownFrame(main))
        follow(main)
        return true
    }

    func hide() {
        stopFollowing()
        guard let panel, let main = panel.parent else { self.panel?.orderOut(nil); return }
        // Its own key focus (a table, the Events filter) goes back to the main window.
        if panel.isKeyWindow { main.makeKey() }
        move(panel, to: hiddenFrame(main)) {
            main.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    // MARK: - Geometry

    private func shownFrame(_ main: NSWindow) -> NSRect {
        let f = main.frame
        let x = side == .right ? f.maxX - Self.overlap : f.minX + Self.overlap - Self.width
        return NSRect(x: x, y: f.minY + Self.inset, width: Self.width, height: max(200, f.height - 2 * Self.inset))
    }

    /// Behind the main window, where it slides out from. It is wider than the
    /// window: aligned with the window's far edge, the rest shows on the side
    /// it slides out to (aligned with the near edge, a sliver would stick out
    /// on the opposite side while it moves).
    private func hiddenFrame(_ main: NSWindow) -> NSRect {
        var r = shownFrame(main)
        r.origin.x = side == .right ? main.frame.minX : main.frame.maxX - Self.width
        return r
    }

    private func move(_ panel: NSWindow, to frame: NSRect, then done: (() -> Void)? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }

    /// Keeps its height with the main window's; full screen gets the drawer.
    private func follow(_ main: NSWindow) {
        stopFollowing()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: main, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                panel.setFrame(self.shownFrame(main), display: true)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: main, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let m = AppModel.current, m.diagnosticsBeside else { return }
                DiagnosticsSidePanel.shared.hide()
                m.diagnosticsBeside = false          // the drawer under the remote instead
            }
        })
    }

    private func stopFollowing() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: - The window

    private func makePanel(model: AppModel) -> SidePanel {
        let panel = SidePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true          // a click on a chart doesn't take the keys
        panel.isMovable = false                      // it moves with the main window
        let host = NSHostingView(rootView: SidePanelContent().environment(model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        panel.contentView = host
        return panel
    }
}

/// Takes the keys when a table or the Events filter is clicked, but never
/// becomes the main window: the main window stays active-looking.
private final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The drawer's content, full height, in the film's accent colour.
private struct SidePanelContent: View {
    @Environment(AppModel.self) private var model
    @State private var height = 0.0

    var body: some View {
        DiagnosticsDrawer(height: $height, maxHeight: 0, beside: true)
            .tint(model.ambience?.tint)
            // Solid: the drawer's own background lets a little of the window
            // behind it through, which here is the desktop.
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
