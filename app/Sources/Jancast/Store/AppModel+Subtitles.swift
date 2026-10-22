import Foundation

/// Subtitle delay and the text recognition (OCR) of picture subtitles.
extension AppModel {
    static let subtitleDelayStep = 0.5

    /// Delay of the subtitles that are playing (from the backend).
    var sessionSubtitleDelay: Double { live?.session?.subtitle?.delay ?? 0 }

    /// The delay the subtitle menu shows: the playing one in the player, else Setup's.
    var shownSubtitleDelay: Double { showsPlayer ? sessionSubtitleDelay : subtitleDelay }

    /// Earlier (−) or later (+). Mid-playback this restarts the stream at the
    /// current position, like a track switch.
    func changeSubtitleDelay(by delta: Double?) {
        let new = delta.map { (shownSubtitleDelay + $0).rounded(toPlaces: 1) } ?? 0
        if showsPlayer && canControl {
            switchTracks(subtitleDelay: new)
        } else {
            subtitleDelay = new
        }
    }

    /// Start (and follow) the OCR of the selected picture subtitle track, so it
    /// is usually done before Play is pressed.
    func followOCR() {
        ocrTask?.cancel()
        ocrStatus = nil
        guard let probe, let sub = selectedSubtitle, sub.viaOCR else { return }
        let path = probe.path, id = sub.id
        ocrTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = try? await self.backend.ocrStatus(path: path, subtitle: id)
                guard !Task.isCancelled, self.probe?.path == path, self.subtitleID == id else { return }
                self.ocrStatus = status
                if let s = status?.status, s != "working" { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10, Double(places))
        return (self * f).rounded() / f
    }
}
