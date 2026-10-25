import SwiftUI

/// The device that is playing, as a toolbar menu: pick another Apple TV (or
/// This Mac) and playback moves there at the current position.
struct DeviceSwitchMenu: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let current = model.live?.session?.device?.id
        Menu {
            DeviceSwitchItems()
        } label: {
            // While moving: "Living Room → Bedroom…" until the new TV reports.
            if let pending = model.pendingDeviceID, pending != current,
               let target = model.devices.first(where: { $0.id == pending }) {
                Label("\(name) → \(target.displayName)…", systemImage: "airplayvideo")
            } else {
                Label(name, systemImage: "airplayvideo")
            }
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Move playback to another Apple TV or This Mac — it continues where it is")
        .keyFocus(.device, radius: 8) { DeviceSwitchItems() }
    }
}

/// The menu's items, for the toolbar menu and for its keyboard menu.
private struct DeviceSwitchItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.live?.session?.device?.id
        Section("Play on") {
            ForEach(model.devices) { d in
                Button {
                    model.switchDevice(d.id)
                } label: {
                    if d.id == current {
                        Label(d.displayName, systemImage: "checkmark")
                    } else {
                        Text(d.displayName + Self.status(d))
                    }
                }
                .disabled(d.reachability == .offline || d.id == current || !model.canControl)
            }
        }
        Divider()
        Button("Scan for Apple TVs") { Task { await model.loadDevices(.refresh) } }
            .disabled(model.scanning)
    }

    private static func status(_ d: Device) -> String {
        switch d.reachability {
        case .online: return d.needsPairing ? " — needs pairing" : ""
        case .notResponding: return " — not responding"
        case .offline: return " — offline"
        }
    }
}
