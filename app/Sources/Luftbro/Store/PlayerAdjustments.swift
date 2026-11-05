import AppKit
import CoreImage

/// This Mac's picture and sound settings (the control bar's Picture & Sound
/// popover; volume also on the remote and ⌘↑ / ⌘↓). Kept across films.
///
/// The picture is adjusted with Core Image filters on the video view: an HLS
/// stream ignores AVVideoComposition (and AVAudioMix), so the layer is the
/// only place left. A filtered layer is drawn through Core Image, which loses
/// HDR highlights, so at the neutral settings there are no filters at all.
@MainActor @Observable
final class PlayerAdjustments {
    /// −1…1: midtones darker / lighter (a gamma curve, so black stays black
    /// and white stays white). 0 is the film as it is.
    var brightness: Double { didSet { changed("brightness", brightness) } }
    /// 0.5…1.5, 1 as it is.
    var contrast: Double { didSet { changed("contrast", contrast) } }
    /// 0…2 (0 is black and white), 1 as it is.
    var saturation: Double { didSet { changed("saturation", saturation) } }
    /// Fill the window or screen (cropping), instead of fitting the whole picture.
    var fill: Bool { didSet { changed("fill", fill) } }
    /// 0…1, the player's own volume (the Mac's volume on top of it).
    var volume: Double { didSet { changed("volume", volume) } }
    var muted: Bool { didSet { changed("muted", muted) } }

    /// Applies the settings to the player (LocalPlayer sets it).
    @ObservationIgnored var onChange: () -> Void = {}

    static let brightnessRange = -1.0...1.0
    static let contrastRange = 0.5...1.5
    static let saturationRange = 0.0...2.0

    private static let prefix = "thisMac."

    init() {
        let d = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: Self.prefix + key) as? Double ?? fallback
        }
        brightness = double("brightness", 0)
        contrast = double("contrast", 1)
        saturation = double("saturation", 1)
        volume = double("volume", 1)
        fill = d.bool(forKey: Self.prefix + "fill")
        muted = d.bool(forKey: Self.prefix + "muted")
    }

    private func changed(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
        onChange()
    }

    // MARK: - Picture

    /// A slider let go a hair off the middle counts as the middle.
    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.025 }

    var pictureIsNeutral: Bool {
        Self.near(brightness, 0) && Self.near(contrast, 1) && Self.near(saturation, 1)
    }

    func resetPicture() {
        brightness = 0
        contrast = 1
        saturation = 1
    }

    /// The view's content filters; none at the neutral settings.
    var filters: [CIFilter] {
        var out: [CIFilter] = []
        if !Self.near(brightness, 0), let f = CIFilter(name: "CIGammaAdjust") {
            f.setDefaults()
            // Power 0.57…1.74: below 1 lifts the midtones.
            f.setValue(pow(2, -0.8 * brightness), forKey: "inputPower")
            out.append(f)
        }
        if !Self.near(contrast, 1) || !Self.near(saturation, 1), let f = CIFilter(name: "CIColorControls") {
            f.setDefaults()
            f.setValue(contrast, forKey: kCIInputContrastKey)
            f.setValue(saturation, forKey: kCIInputSaturationKey)
            out.append(f)
        }
        return out
    }

    // MARK: - Sound

    /// The volume the player actually plays at.
    var effectiveVolume: Float { muted ? 0 : Float(volume) }

    /// ⌘↑ / ⌘↓: a tenth up or down; going up unmutes.
    func stepVolume(up: Bool) {
        if up { muted = false }
        volume = min(1, max(0, ((volume + (up ? 0.1 : -0.1)) * 10).rounded() / 10))
    }

    var volumeText: String {
        muted ? "Muted" : "\(Int((volume * 100).rounded())) %"
    }

    var volumeSymbol: String {
        if muted || volume == 0 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}
