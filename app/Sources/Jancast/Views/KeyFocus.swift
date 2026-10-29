import AppKit
import SwiftUI

/// Keyboard focus of our own, so Tab reaches the remote's controls also with
/// macOS keyboard navigation off (the default, where Tab only visits text
/// fields and lists and these buttons and menus were out of reach). The key
/// monitor (AppDelegate) moves it; each control marks itself with
/// `.keyFocus(…)`, draws the ring while it has it and says what Return /
/// Space do. The library is where focus starts and where Esc brings it back.
enum KeyFocus: Hashable, CaseIterable {
    // Tab order: as on screen, top to bottom. The ready screen has startOver,
    // play, audio and subtitles; the player stop … sleep (play is Play/Pause).
    case device, startOver, stop, back, play, forward, volume, audio, subtitles, sleep, library
}

extension View {
    /// A button Tab can reach: Return / Space run `action`.
    func keyFocus(_ target: KeyFocus, radius: CGFloat, action: @escaping () -> Void) -> some View {
        modifier(KeyFocusRing(target: target, radius: radius, opensMenu: false) { _ in action() })
    }

    /// A menu Tab can reach: Return / Space (or ↑ / ↓) open `menu` under the
    /// control, the same items a click shows.
    func keyFocus(_ target: KeyFocus, radius: CGFloat, @ViewBuilder menu: @escaping () -> some View) -> some View {
        modifier(KeyFocusRing(target: target, radius: radius, opensMenu: true) { anchor in
            KeyFocusMenu.open(menu(), under: anchor)
        })
    }
}

/// What the key monitor can do with a focused control.
struct KeyFocusAction {
    let token: ObjectIdentifier
    let opensMenu: Bool
    let run: () -> Void
}

private struct KeyFocusRing: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: KeyFocus
    let radius: CGFloat
    let opensMenu: Bool
    let activate: (NSView?) -> Void

    func body(content: Content) -> some View {
        content
            .background(KeyFocusAnchor(model: model, target: target, opensMenu: opensMenu, activate: activate))
            .overlay {
                if model.keyFocus == target && model.mainWindowIsKey {
                    RoundedRectangle(cornerRadius: radius + 3.5, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3.5)
                        .padding(-3.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// An invisible AppKit view behind the control: registers the control while
/// it is on screen and is where its menu opens.
private struct KeyFocusAnchor: NSViewRepresentable {
    let model: AppModel
    let target: KeyFocus
    let opensMenu: Bool
    let activate: (NSView?) -> Void

    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        weak var model: AppModel?
        var target: KeyFocus?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        let c = context.coordinator
        if let old = c.target, old != target { model.unregisterKeyFocus(old, token: ObjectIdentifier(c)) }
        c.model = model
        c.target = target
        let activate = activate
        model.keyActions[target] = KeyFocusAction(token: ObjectIdentifier(c), opensMenu: opensMenu) { [weak view] in
            activate(view)
        }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        guard let target = coordinator.target else { return }
        coordinator.model?.unregisterKeyFocus(target, token: ObjectIdentifier(coordinator))
    }
}

@MainActor
enum KeyFocusMenu {
    static func open(_ content: some View, under anchor: NSView?) {
        guard let anchor, anchor.window != nil, let model = AppModel.current else { return }
        // NSHostingMenu builds the AppKit menu from the same SwiftUI items.
        guard #available(macOS 14.4, *) else { return }
        let menu = NSHostingMenu(rootView: content.environment(model))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }
}

extension AppModel {
    /// Tab / ⇧Tab: the next / previous control on screen, round the loop.
    func moveKeyFocus(back: Bool) {
        let order = KeyFocus.allCases.filter { $0 == .library || keyActions[$0] != nil }
        let i = order.firstIndex(of: keyFocus) ?? order.firstIndex(of: .library)!
        keyFocus = order[(i + (back ? order.count - 1 : 1)) % order.count]
    }

    /// The focused control's action (Return / Space); false on the library.
    func activateKeyFocus(menusOnly: Bool = false) -> Bool {
        guard keyFocus != .library, let a = keyActions[keyFocus] else { return false }
        if menusOnly && !a.opensMenu { return false }
        a.run()
        return true
    }

    func unregisterKeyFocus(_ target: KeyFocus, token: ObjectIdentifier) {
        guard keyActions[target]?.token == token else { return }   // another view took it over
        keyActions[target] = nil
        if keyFocus == target { keyFocus = .library }
    }
}
