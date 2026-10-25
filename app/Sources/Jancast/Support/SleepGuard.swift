import Foundation

/// Keeps the Mac awake while it streams. The Apple TV fetches every segment
/// from this Mac, and nobody touches the Mac while watching the TV, so macOS
/// idle-slept it mid-film (display off, "Idle Sleep" five seconds later) and
/// the AirPlay connection was lost. The display may still turn off, a paused
/// film lets the Mac sleep, and closing the lid still sleeps it.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()
    private var activity: NSObjectProtocol?

    func update(streaming: Bool) {
        if streaming, activity == nil {
            // .userInitiated includes .idleSystemSleepDisabled (not display sleep) and keeps App Nap off.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                             reason: "Streaming video to an Apple TV")
        } else if !streaming, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}
