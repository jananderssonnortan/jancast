import SwiftUI

/// Sleep timer: playback stops after a while, as Stop would (the position is
/// saved for Resume, and the Apple TV goes to sleep on its own schedule).
/// It belongs to what is playing, so it ends with it.
extension AppModel {
    static let sleepMinutes = [15, 30, 45, 60, 90, 120]

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes else { sleepAt = nil; return }
        let at = Date().addingTimeInterval(Double(minutes) * 60)
        sleepAt = at
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.sleepAt = nil
            self.sleepTask = nil
            if self.canControl { self.stop() }
        }
    }
}

/// The timer's choices, for the player's menu, its keyboard menu and the
/// Playback menu.
struct SleepTimerItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(AppModel.sleepMinutes, id: \.self) { m in
            Button(m < 60 ? "In \(m) Minutes" : m == 60 ? "In 1 Hour" : m == 90 ? "In 1½ Hours" : "In \(m / 60) Hours") {
                model.setSleepTimer(minutes: m)
            }
        }
        if model.sleepAt != nil {
            Divider()
            Button("Turn Off Sleep Timer") { model.setSleepTimer(minutes: nil) }
        }
    }
}

/// Under the player's tracks: "Sleep Timer", or when it stops.
struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let label = model.sleepAt.map { "Stops at " + $0.formatted(date: .omitted, time: .shortened) } ?? "Sleep Timer"
        Menu {
            SleepTimerItems()
        } label: {
            Label(label, systemImage: model.sleepAt == nil ? "moon.zzz" : "moon.zzz.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.callout)
        .foregroundStyle(model.sleepAt == nil ? .secondary : .primary)
        .help("Stop playing after a while; Resume continues from there")
        .disabled(!model.canControl)
        .keyFocus(.sleep, radius: 8) { SleepTimerItems() }
    }
}
