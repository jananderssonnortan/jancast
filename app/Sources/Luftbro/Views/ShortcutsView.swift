import SwiftUI

/// Help → Keyboard Shortcuts (⌘/): every key Luftbro answers to, in one place.
struct ShortcutsView: View {
    struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    struct Section: Identifiable {
        let title: String
        let items: [Shortcut]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Playing", items: [
            Shortcut(keys: "Space", action: "Play or pause (in the main window: the file selected in the library)"),
            Shortcut(keys: "← / →", action: "Back / forward 10 s (quick presses add up)"),
            Shortcut(keys: "⌘← / ⌘→", action: "Back / forward 30 s"),
            Shortcut(keys: "⌘.", action: "Stop"),
            Shortcut(keys: "⌘↩", action: "Play or resume the loaded file"),
            Shortcut(keys: "⏭ · Space", action: "Skip Intro / Next Episode (Space while the button is new)"),
            Shortcut(keys: "H / J", action: "Subtitles half a second earlier / later"),
            Shortcut(keys: "⌘↑ / ⌘↓", action: "Volume: the TV's, or This Mac's"),
            Shortcut(keys: "M", action: "Mute / unmute This Mac"),
        ]),
        Section(title: "Library", items: [
            Shortcut(keys: "↑ / ↓", action: "Previous / next file; while playing only the highlight moves"),
            Shortcut(keys: "⌥↑ / ⌥↓ · Home / End", action: "First / last file"),
            Shortcut(keys: "Page Up / Page Down", action: "Five files up / down"),
            Shortcut(keys: "Return", action: "Play the selected or highlighted file"),
            Shortcut(keys: "Esc", action: "While playing: the highlight back to what plays"),
            Shortcut(keys: "Tab / ⇧Tab", action: "Move between the TV menu, the buttons, Audio, Subtitles and the library"),
            Shortcut(keys: "Return · Esc", action: "Use what Tab moved to · back to the library"),
        ]),
        Section(title: "This Mac window", items: [
            Shortcut(keys: "Double-click", action: "Full screen (Esc leaves it)"),
            Shortcut(keys: "Move the mouse", action: "Show the controls"),
        ]),
        Section(title: "App", items: [
            Shortcut(keys: "⌘O", action: "Open a video"),
            Shortcut(keys: "⌥⌘I", action: "Show / hide Diagnostics"),
            Shortcut(keys: "⇧⌘C", action: "Copy the Diagnostics report"),
            Shortcut(keys: "⌘/", action: "This list"),
        ]),
    ]

    var body: some View {
        ScrollView {
            // One grid for all sections: the keys line up down the whole list.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Self.sections) { section in
                    GridRow {
                        Text(section.title.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(2)
                            .padding(.top, section.id == Self.sections.first?.id ? 0 : 12)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.items) { s in
                        GridRow {
                            Text(s.keys)
                                .font(.body.weight(.semibold))
                                .gridColumnAlignment(.trailing)
                            Text(s.action)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 560)
    }
}
