import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The picture's mood for the remote: a soft wash of the poster frame behind
/// it and a tint taken from its colours. Made once per image on a tiny copy
/// (a millisecond or two) and drawn as a plain image — no live blur, which
/// would redraw the whole window every frame (see docs/DESIGN.md).
@MainActor
enum Ambience {
    struct Look {
        let backdrop: NSImage
        /// The image's most vivid colour, made legible; nil for a grey picture
        /// (the system accent stays).
        let tint: Color?
    }

    private final class Box { let look: Look?; init(_ look: Look?) { self.look = look } }
    private static let cache = NSCache<NSImage, Box>()
    private static let scenes = NSCache<NSImage, NSImage>()
    private static let glows = NSCache<NSImage, NSImage>()
    private static let liftedImages = NSCache<NSImage, NSImage>()
    private final class Scores { let values: [Double]; init(_ v: [Double]) { values = v } }
    private static let scores = NSCache<NSImage, Scores>()
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let width: CGFloat = 48

    static func look(for image: NSImage?) -> Look? {
        guard let image else { return nil }
        if let hit = cache.object(forKey: image) { return hit.look }
        let look = make(image)
        cache.setObject(Box(look), forKey: image)
        return look
    }

    /// A frame softened into light and colour, no shapes: sharper, it read as
    /// a smudge behind the title rather than as a picture.
    static func scene(for image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        if let hit = scenes.object(forKey: image) { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = standardShape(CIImage(cgImage: cg))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(input.extent.width / 30)
        guard let out = blur.outputImage?.cropped(to: input.extent),
              let soft = context.createCGImage(out, from: input.extent) else { return nil }
        let scene = NSImage(cgImage: soft, size: NSSize(width: input.extent.width, height: input.extent.height))
        scenes.setObject(scene, forKey: image)
        return scene
    }

    /// The film's palette (one colour per 10 s) as a soft glow: its three
    /// strongest colours as large blurred pools of light, low in the window,
    /// rather than stripes (a stretched palette read as a blurry barcode).
    static func glow(for palette: NSImage?) -> NSImage? {
        guard let palette else { return nil }
        if let hit = glows.object(forKey: palette) { return hit }
        guard let cg = palette.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0 else { return nil }
        let w = cg.width
        var px = [UInt8](repeating: 0, count: w * 4)
        guard let row = CGContext(data: &px, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        row.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: 1))
        // Hue bins, each colour counting by how vivid it is: the heaviest bins,
        // averaged, are the film's main colours.
        var bins = [(r: Double, g: Double, b: Double, weight: Double)](repeating: (0, 0, 0, 0), count: 12)
        for i in 0..<w {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
            let weight = Double(sat * sat * bri) + 0.01
            let k = min(11, Int(hue * 12))
            bins[k].r += r * weight; bins[k].g += g * weight; bins[k].b += b * weight; bins[k].weight += weight
        }
        let main = bins.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }.prefix(3)
            .map { CGColor(srgbRed: $0.r / $0.weight, green: $0.g / $0.weight, blue: $0.b / $0.weight, alpha: 1) }
        guard let first = main.first else { return nil }

        let size = 48
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(first.copy(alpha: 0.35) ?? first)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Where the pools sit (x, y from the top, radius), as fractions: mostly
        // under the remote, where the library is.
        let spots: [(Double, Double, Double)] = [(0.15, 0.62, 0.55), (0.88, 0.78, 0.55), (0.45, 1.0, 0.6)]
        for (colour, (x, y, r)) in zip(main, spots) {
            let clear = colour.copy(alpha: 0) ?? colour
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            colors: [colour, clear] as CFArray, locations: [0, 1]) else { continue }
            let centre = CGPoint(x: x * Double(size), y: (1 - y) * Double(size))
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: r * Double(size), options: [])
        }
        guard let drawn = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: drawn)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 6
        // Films are mostly dark: lift it so the colours glow rather than murk.
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = blur.outputImage
        exposure.ev = 0.8
        let color = CIFilter.colorControls()
        color.inputImage = exposure.outputImage
        color.saturation = 1.4
        guard let out = color.outputImage?.cropped(to: input.extent),
              let soft = context.createCGImage(out, from: input.extent) else { return nil }
        let glow = NSImage(cgImage: soft, size: NSSize(width: size, height: size))
        glows.setObject(glow, forKey: palette)
        return glow
    }

    /// The middle 16:9 of a frame. Films are 2.39:1, 1.85:1 or 16:9, and each
    /// filled into the same backdrop at its own scale, so changing title (or
    /// scene) zoomed the background in and out; this way it only fades.
    private static func standardShape(_ image: CIImage) -> CIImage {
        let e = image.extent, target: CGFloat = 16.0 / 9.0
        var r = e
        if e.width / e.height > target {
            r.size.width = (e.height * target).rounded()
            r.origin.x = (e.midX - r.width / 2).rounded()
        } else {
            r.size.height = (e.width / target).rounded()
            r.origin.y = (e.midY - r.height / 2).rounded()
        }
        return image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    /// A brighter, airier version for light mode: a dark frame under a white
    /// veil only turns into grey.
    static func lifted(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        if let hit = liftedImages.object(forKey: image) { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = input
        exposure.ev = 1.4
        let color = CIFilter.colorControls()
        color.inputImage = exposure.outputImage
        color.saturation = 0.9
        guard let out = color.outputImage?.cropped(to: input.extent),
              let bright = context.createCGImage(out, from: input.extent) else { return nil }
        let result = NSImage(cgImage: bright, size: image.size)
        liftedImages.setObject(result, forKey: image)
        return result
    }

    /// How well each thumbnail would read as a backdrop, from the palette (one
    /// pixel per thumbnail): lit and colourful beats black titles and night sky.
    static func frameScores(_ palette: NSImage?) -> [Double] {
        guard let palette else { return [] }
        if let hit = scores.object(forKey: palette) { return hit.values }
        guard let cg = palette.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let w = cg.width
        var px = [UInt8](repeating: 0, count: w * 4)
        guard let ctx = CGContext(data: &px, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: 1))
        let values = (0..<w).map { i -> Double in
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let chroma = max(r, g, b) - min(r, g, b)
            return chroma - 2 * abs(luma - 0.45)
        }
        scores.setObject(Scores(values), forKey: palette)
        return values
    }

    private static func make(_ image: NSImage) -> Look? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let raw = CIImage(cgImage: cg)
        guard raw.extent.width > 0, raw.extent.height > 0 else { return nil }
        let input = raw.extent.height < 8 ? raw : standardShape(raw)     // a palette strip stays as it is
        // A 1-pixel-high palette strip is stretched into a band first.
        let sx = width / input.extent.width
        let sy = max(sx, 24 / input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let extent = small.extent.integral

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = small.clampedToExtent()
        blur.radius = 5
        let color = CIFilter.colorControls()
        color.inputImage = blur.outputImage
        color.saturation = 1.3
        guard let out = color.outputImage?.cropped(to: extent),
              let backdrop = context.createCGImage(out, from: extent) else { return nil }
        return Look(backdrop: NSImage(cgImage: backdrop, size: NSSize(width: extent.width, height: extent.height)),
                    tint: tint(small, extent))
    }

    /// Average hue of the pixels weighted by how vivid they are, at a
    /// saturation and brightness that read well in both light and dark mode.
    private static func tint(_ image: CIImage, _ extent: CGRect) -> Color? {
        let w = Int(extent.width), h = Int(extent.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: extent, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var x = 0.0, y = 0.0, weight = 0.0, sat = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255,
                            blue: CGFloat(px[i + 2]) / 255, alpha: 1)
            var hue: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&hue, saturation: &s, brightness: &b, alpha: &a)
            let wgt = Double(s * s * b)
            x += cos(Double(hue) * 2 * .pi) * wgt
            y += sin(Double(hue) * 2 * .pi) * wgt
            weight += wgt
            sat += Double(s) * Double(b)
        }
        let n = Double(w * h)
        guard weight > 0, sat / n > 0.03 else { return nil }   // graded films are muted, not grey
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let s = min(0.72, max(0.5, sat / n * 2.2))
        // Bright enough to glow on the dark wash; in light mode deep enough
        // for white text on it (Resume) and for itself as text.
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hue: hue, saturation: s, brightness: 0.78, alpha: 1)
                : NSColor(hue: hue, saturation: min(0.85, s + 0.1), brightness: 0.5, alpha: 1)
        })
    }
}

extension AppModel {
    /// Where the now card's poster frame is taken: the session's start (a
    /// resume point) or the ready file's resume point, else 10 % in.
    var heroPosterAt: Double? {
        if showsPlayer {
            let duration = max(1, live?.session?.file?.durationS ?? live?.playback?.duration ?? 1)
            let start = live?.session?.startPosition ?? 0
            return start > 0 ? start : duration * 0.1
        }
        guard let probe, thumbs.path == probe.path else { return nil }
        return resumeEntry?.resumePosition ?? max(1, probe.durationS ?? 1) * 0.1
    }

    var heroPoster: NSImage? { heroPosterAt.flatMap { thumbs.image(at: $0) } }

    /// The scene behind the remote: not the poster's frame (an echo of the
    /// tile) but the best-lit, most colourful frame of the current five
    /// minutes (of the first tenth near the start, where titles and black
    /// openings are), so it drifts with the episode.
    var backdropSceneAt: Double? {
        let duration: Double, at: Double
        if showsPlayer {
            duration = max(1, live?.session?.file?.durationS ?? live?.playback?.duration ?? 1)
            at = displayPosition ?? live?.session?.startPosition ?? 0
        } else {
            guard let probe, thumbs.path == probe.path else { return nil }
            duration = max(1, probe.durationS ?? 1)
            at = resumeEntry?.resumePosition ?? duration * 0.05
        }
        let step = 300.0
        var from = (at / step).rounded(.down) * step, to = from + step
        if at < 600 { from = 0; to = max(to, duration * 0.12) }
        let scores = Ambience.frameScores(thumbs.palette)
        if let interval = thumbs.info?.intervalS, interval > 0, !scores.isEmpty {
            let first = min(scores.count - 1, Int(from / interval))
            let last = min(scores.count - 1, Int(to / interval))
            if let best = (first...last).max(by: { scores[$0] < scores[$1] }) {
                return (Double(best) + 0.5) * interval
            }
        }
        return min(max(30, from), max(30, duration - 60))
    }

    private var backdropFrame: NSImage? {
        guard showsPlayer || probe != nil else { return launch?.frame }
        return backdropSceneAt.flatMap { thumbs.image(at: $0) } ?? launch?.frame
    }

    /// The palette behind the library: this file's, or last run's while it loads.
    var washPalette: NSImage? { thumbs.palette ?? launch?.palette }

    /// The file on screen: playing, else loaded.
    private var currentPath: String? {
        showsPlayer ? live?.session?.file?.path : probe?.path
    }

    /// Last run's pictures, while they can still be this file's: before
    /// anything is loaded, or for the same file.
    private var launch: SavedLook.Pictures? {
        guard let l = launchLook else { return nil }
        if let path = currentPath, path != l.path { return nil }
        return l
    }

    /// On quit: what the next launch opens with (or nothing, with no file).
    func saveLook() {
        UserDefaults.standard.set(remoteTop, forKey: "lastRemoteTop")
        if let path = currentPath {
            SavedLook.save(SavedLook.Pictures(path: path, frame: backdropFrame, poster: heroPoster ?? launch?.poster,
                                              palette: washPalette))
        } else {
            SavedLook.clear()
        }
    }

    var backdropScene: NSImage? { Ambience.scene(for: backdropFrame) }

    /// The remote's mood: the wash from the backdrop's frame, the tint from
    /// the poster's (it stays put while the scene drifts).
    var ambience: Ambience.Look? {
        guard showsPlayer || probe != nil || launch != nil else { return nil }
        let poster = heroPoster ?? launch?.poster
        guard let wash = Ambience.look(for: backdropFrame ?? poster ?? washPalette) else { return nil }
        return Ambience.Look(backdrop: wash.backdrop, tint: Ambience.look(for: poster)?.tint ?? wash.tint)
    }
}

/// The window's colours from the last run: the pictures behind them, saved on
/// quit and shown from the first frame of the next launch until the restored
/// file's own load (the backend and thumbnails take a second or two, and the
/// window used to open grey with the colours fading in after it).
enum SavedLook {
    struct Pictures {
        let path: String
        let frame: NSImage?
        let poster: NSImage?
        let palette: NSImage?
    }

    private static var dir: URL {
        let cache = ProcessInfo.processInfo.environment["JANCAST_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/jancast")
        return cache.appendingPathComponent("look", isDirectory: true)
    }

    static func load() -> Pictures? {
        guard let path = try? String(contentsOf: dir.appendingPathComponent("path.txt"), encoding: .utf8),
              !path.isEmpty else { return nil }
        func image(_ name: String) -> NSImage? { NSImage(contentsOf: dir.appendingPathComponent(name)) }
        let p = Pictures(path: path, frame: image("frame.png"), poster: image("poster.png"), palette: image("palette.png"))
        return (p.frame ?? p.poster ?? p.palette) == nil ? nil : p
    }

    static func save(_ p: Pictures) {
        clear()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, image) in [("frame.png", p.frame), ("poster.png", p.poster), ("palette.png", p.palette)] {
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent(name))
        }
        try? p.path.write(to: dir.appendingPathComponent("path.txt"), atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The ambience image behind the remote, veiled more towards the bottom so
/// it fades into the window and never fights the text on it.
struct AmbientBackdrop: View {
    let image: NSImage?
    /// A softened frame over the top of the wash, fading out by the timeline.
    var scene: NSImage? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let image = dark ? image : Ambience.lifted(image)
        let scene = dark ? scene : Ambience.lifted(scene)
        ZStack {
            FadingImage(image: image, gravity: .resizeAspectFill)
                .opacity(dark ? 0.9 : 0.75)
            // Keeps text on it readable; stronger towards the bottom.
            Rectangle().fill(.background)
                .mask(LinearGradient(stops: [.init(color: .black.opacity(dark ? 0.2 : 0.3), location: 0),
                                             .init(color: .black.opacity(dark ? 0.55 : 0.6), location: 0.45),
                                             .init(color: .black.opacity(dark ? 0.85 : 0.85), location: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
            GeometryReader { geo in
                FadingImage(image: scene, gravity: .resizeAspectFill, duration: 1.5)
                    .frame(width: geo.size.width, height: geo.size.width * 0.62)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: 0.45),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(0.35)
            }
        }
        // Fades to nothing at the bottom, so whatever the window draws below
        // (its colour differs between systems and is translucent on macOS 26)
        // continues without a seam.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.6),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Under the whole window: where the remote's backdrop fades out, the library
/// sits on the film's palette as a soft glow (the colours of the whole film,
/// start to end), so it doesn't turn plain grey. Before the palette exists,
/// the remote's wash, fainter.
struct LibraryWash: View {
    let palette: NSImage?
    let fallback: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let glow = Ambience.glow(for: palette)
        let source = glow ?? fallback
        ZStack {
            FadingImage(image: dark ? source : Ambience.lifted(source), gravity: .resize)
                .opacity(glow != nil ? (dark ? 0.7 : 0.5) : (dark ? 0.55 : 0.4))
            // Keeps the rows readable on it.
            Rectangle().fill(.background).opacity(source == nil ? 0 : 0.35)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A picture filling its frame that fades to the next one in Core Animation (a
/// layer's contents with a fade transition). With SwiftUI's insert/remove
/// transitions the incoming picture briefly laid out at another size, so the
/// background zoomed in and out when browsing between titles; here a change of
/// picture can't touch any geometry.
struct FadingImage: NSViewRepresentable {
    let image: NSImage?
    var gravity: CALayerContentsGravity = .resizeAspectFill
    var duration: Double = 0.8

    final class View: NSView {
        var shown: NSImage?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }     // only a picture
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.wantsLayer = true
        v.layer?.contentsGravity = gravity
        v.layer?.masksToBounds = true
        v.layer?.minificationFilter = .trilinear
        v.layer?.magnificationFilter = .linear
        v.shown = image
        v.layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return v
    }

    func updateNSView(_ v: View, context: Context) {
        v.layer?.contentsGravity = gravity
        guard v.shown !== image, let layer = v.layer else { return }
        v.shown = image
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade")
        layer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
