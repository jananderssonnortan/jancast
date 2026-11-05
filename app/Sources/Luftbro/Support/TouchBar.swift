import AppKit
import Observation
import SwiftUI

/// Luftbro's part of the Touch Bar (while it is the active app, with the
/// Touch Bar set to show app controls): one full-width item on a gradient
/// in the film's accent colour, with what plays, −10 / play-pause / +30,
/// Skip Intro / Next Episode when they apply, and the time. Set on NSApp, the
/// end of the responder chain, so a text field's own bar still wins.
///
/// On a Mac without a Touch Bar (or with it set to the Control Strip only)
/// the bar is never visible, and nothing is updated: the feature just isn't there.
@MainActor
final class PlayerTouchBar: NSObject, NSTouchBarDelegate {
    static let shared = PlayerTouchBar()
    private static let itemID = NSTouchBarItem.Identifier("com.luftbro.player")

    private let bar = NSTouchBar()
    private let backdrop = TouchBarGradientView()
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private var back: NSButton!
    private var playPause: NSButton!
    private var forward: NSButton!
    private var marker: NSButton!
    private var visibility: NSKeyValueObservation?
    /// Following the model, only while the bar is on screen.
    private var following = false

    func install() {
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.itemID]
        buildViews()
        NSApp.touchBar = bar
        visibility = bar.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.visibilityChanged() } }
        }
        // Also when Luftbro comes to the front, in case the KVO change never arrives.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
    }

    private func visibilityChanged() {
        guard bar.isVisible, !following else { return }
        following = true
        observe()
    }

    nonisolated func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        MainActor.assumeIsolated {
            guard identifier == Self.itemID else { return nil }
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = backdrop
            return item
        }
    }

    // MARK: - Views

    private func buildViews() {
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        time.textColor = NSColor.white.withAlphaComponent(0.75)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        back = transport("gobackward.10", "Back 10 seconds", #selector(skipBack))
        playPause = transport("play.fill", "Play", #selector(togglePlay))
        forward = transport("goforward.30", "Forward 30 seconds", #selector(skipForward))
        marker = NSButton(title: "Skip Intro", target: self, action: #selector(runMarker))
        marker.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
        marker.imagePosition = .imageLeading

        let stack = NSStackView(views: [title, back, playPause, forward, marker, time])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(14, after: forward)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        // As wide as the app's part of the bar allows: the title gives way first.
        let wide = backdrop.widthAnchor.constraint(equalToConstant: 2000)
        wide.priority = .defaultLow
        wide.isActive = true
    }

    private func transport(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                         target: self, action: action)
        b.bezelColor = NSColor.black.withAlphaComponent(0.25)
        b.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return b
    }

    // MARK: - Following the model

    private func observe() {
        // Hidden (another app in front, no Touch Bar): stop until it shows again.
        guard bar.isVisible else { following = false; return }
        withObservationTracking { update() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    private func update() {
        guard let m = AppModel.current else { return }
        let session = m.canControl && m.hasSession
        let tint = m.ambience?.tint.map { NSColor($0) } ?? NSColor.controlAccentColor
        backdrop.tint = tint

        if session, let file = m.live?.session?.file {
            let n = Fmt.name(file.name ?? "", file.nameInfo)
            title.stringValue = n.title
            let duration = file.durationS ?? m.live?.playback?.duration
            time.stringValue = Fmt.clock(m.displayPosition) + " / " + Fmt.clock(duration)
        } else if let p = m.probe {
            title.stringValue = Fmt.name(p.displayName, p.nameInfo).title
            time.stringValue = Fmt.clock(p.durationS)
        } else {
            title.stringValue = "Luftbro"
            time.stringValue = ""
        }

        let paused = !session || m.isPaused
        playPause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                  accessibilityDescription: paused ? "Play" : "Pause")
        playPause.bezelColor = tint
        playPause.isEnabled = session || m.canPlay
        back.isHidden = !session
        forward.isHidden = !session

        switch m.activeMarker {
        case .intro:
            marker.title = "Skip Intro"
            marker.isHidden = false
        case .credits:
            marker.title = "Next Episode"
            marker.isHidden = false
        case nil:
            marker.isHidden = true
        }
        marker.bezelColor = tint
    }

    // MARK: - Actions

    @objc private func skipBack() { AppModel.current?.skip(-10) }
    @objc private func skipForward() { AppModel.current?.skip(30) }
    @objc private func runMarker() { AppModel.current?.runMarker() }

    @objc private func togglePlay() {
        guard let m = AppModel.current else { return }
        if m.canControl && m.hasSession { m.togglePause() } else if m.canPlay { m.playLibrarySelection() }
    }
}

/// The item's background: the accent colour fading to black (an OLED strip:
/// kept dim, bright only at the left).
final class TouchBarGradientView: NSView {
    private let gradient = CAGradientLayer()

    var tint: NSColor = .controlAccentColor {
        didSet { if tint != oldValue { applyColors() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 6
        layer?.addSublayer(gradient)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    private func applyColors() {
        // The film's tint is a dynamic colour: take its dark-mode variant (the
        // Touch Bar is always dark), in sRGB; a colour that won't convert gets
        // a plain grey instead of crashing on its components.
        var resolved: NSColor?
        (NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            resolved = tint.usingColorSpace(.sRGB)
        }
        let c = resolved ?? NSColor(srgbRed: 0.45, green: 0.45, blue: 0.5, alpha: 1)
        func shade(_ f: CGFloat) -> CGColor {
            NSColor(srgbRed: c.redComponent * f, green: c.greenComponent * f, blue: c.blueComponent * f, alpha: 1).cgColor
        }
        gradient.colors = [shade(0.8), shade(0.35), NSColor.black.cgColor]
        gradient.locations = [0, 0.55, 1]
    }
}
