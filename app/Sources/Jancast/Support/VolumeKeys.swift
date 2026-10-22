import AppKit
import ApplicationServices
import Observation

/// Opt-in: the Mac's volume keys turn the TV's volume while Jancast is the
/// active app and a stream plays on an Apple TV. Anywhere else (another app
/// in front, This Mac, nothing playing) the keys work the Mac as usual.
///
/// Volume keys never reach an app's own event handling, so this needs a
/// session event tap, which needs the Accessibility permission (asked for
/// when switched on). An ad-hoc signed build counts as a new app to that
/// permission, so after a rebuild it may need to be granted again.
@MainActor @Observable
final class VolumeKeys {
    static let shared = VolumeKeys()

    private static let defaultsKey = "volumeKeysControlTV"
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var waitTimer: Timer?

    var enabled: Bool = UserDefaults.standard.bool(forKey: VolumeKeys.defaultsKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            if enabled { start(prompt: true) } else { stop() }
        }
    }

    func startIfEnabled() {
        if enabled { start(prompt: false) }
    }

    private func start(prompt: Bool) {
        guard tap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            // Wait for the permission to be granted in System Settings.
            waitTimer?.invalidate()
            waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard VolumeKeys.shared.enabled else { VolumeKeys.shared.waitTimer?.invalidate(); return }
                    if AXIsProcessTrusted() {
                        VolumeKeys.shared.waitTimer?.invalidate()
                        VolumeKeys.shared.start(prompt: false)
                    }
                }
            }
            return
        }
        let mask = CGEventMask(1 << 14)     // NX_SYSDEFINED: media and volume keys
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: volumeKeyCallback, userInfo: nil) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
    }

    private func stop() {
        waitTimer?.invalidate()
        waitTimer = nil
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }

    /// The system turns a slow tap off; turn it back on.
    fileprivate func reenable() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// true = the key was for the TV (swallow it), false = let the Mac have it.
    fileprivate func handle(up: Bool, pressed: Bool) -> Bool {
        guard NSApp.isActive, let m = AppModel.current, m.showsPlayer, m.canControl, m.playsOnAppleTV
        else { return false }
        if pressed { m.changeTVVolume(up: up) }
        return true
    }
}

/// Runs on the main run loop (where the tap's source was added).
private func volumeKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { VolumeKeys.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    // data1: key code in the high 16 bits, 0xA (down) / 0xB (up) in bits 8-15.
    let key = (ns.data1 & 0xFFFF_0000) >> 16
    let state = (ns.data1 & 0xFF00) >> 8
    guard key == 0 || key == 1 else { return Unmanaged.passUnretained(event) }   // NX_KEYTYPE_SOUND_UP / _DOWN
    let swallow = MainActor.assumeIsolated {
        VolumeKeys.shared.handle(up: key == 0, pressed: state == 0xA)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
