// luftbro helper for what only macOS frameworks can do: subtitle OCR with
// Vision, and hearing where people speak with SoundAnalysis.
//
//   luftbro-ocr <file listing one PNG path per line> [--fast] [language ...]
//   luftbro-ocr --speech <16 kHz mono float32 PCM file> ...
//
// OCR prints one JSON object per image: {"file": "...", "text": "line 1\nline 2"}.
// Speech prints one JSON object per PCM file: {"file": "...", "window": 0.5,
// "hop": 0.1, "speech": [confidence per window, 0-1000]} - window n starts
// n * hop seconds into the file.
// Built by luftbro/ocrsubs.py with `swiftc -O` on first use.
import Foundation
import AVFoundation
import SoundAnalysis
import Vision

let args = CommandLine.arguments
let lock = NSLock()

func emit(_ obj: [String: Any]) {
    // Printed as soon as each item is done, so the caller can show progress.
    lock.lock()
    if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
    lock.unlock()
}

// MARK: - Speech

/// The built-in sound classifier's "speech" confidence along a PCM file.
/// Half-second windows every tenth of a second: fine enough to place a
/// subtitle to a fraction of a second, and the classifier is robust to music
/// and noise under the voice, where loudness alone is not.
let speechWindow = 0.5
let speechHop = 0.1

final class SpeechObserver: NSObject, SNResultsObserving {
    var confidences: [Double] = []
    var failure: String?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        confidences.append(r.classification(forIdentifier: "speech")?.confidence ?? 0)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        failure = error.localizedDescription
    }

    func requestDidComplete(_ request: SNRequest) {}
}

func analyseSpeech(_ path: String) {
    let rate = 16000.0
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
          let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else {
        emit(["file": path, "error": "could not read the audio or load the sound classifier"])
        return
    }
    request.windowDuration = CMTime(seconds: speechWindow, preferredTimescale: Int32(rate))
    request.overlapFactor = 1 - speechHop / speechWindow
    let analyzer = SNAudioStreamAnalyzer(format: format)
    let observer = SpeechObserver()
    guard (try? analyzer.add(request, withObserver: observer)) != nil else {
        emit(["file": path, "error": "the sound classifier is not available"])
        return
    }
    let frames = data.count / 4
    let chunk = Int(rate) * 10
    var position = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
        while position < frames {
            let n = min(chunk, frames - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let channel = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(n)
            memcpy(channel[0], base + position, n * 4)
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += n
        }
    }
    analyzer.completeAnalysis()
    if let failure = observer.failure {
        emit(["file": path, "error": failure])
    } else {
        emit(["file": path, "window": speechWindow, "hop": speechHop,
              "speech": observer.confidences.map { Int(($0 * 1000).rounded()) }])
    }
}

if args.count >= 3, args[1] == "--speech" {
    let files = Array(args.dropFirst(2))
    DispatchQueue.concurrentPerform(iterations: files.count) { analyseSpeech(files[$0]) }
    exit(0)
}

// MARK: - OCR

guard args.count >= 2, let listing = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: luftbro-ocr <listing> [languages...] | --speech <pcm>...\n".data(using: .utf8)!)
    exit(2)
}
let files = listing.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
let fast = args.dropFirst(2).contains("--fast")      // ~7x quicker, nearly as good on subtitles
let languages = args.dropFirst(2).filter { $0 != "--fast" }

DispatchQueue.concurrentPerform(iterations: files.count) { i in
    let url = URL(fileURLWithPath: files[i])
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = fast ? .fast : .accurate
    request.usesLanguageCorrection = true
    if !languages.isEmpty { request.recognitionLanguages = languages }
    let handler = VNImageRequestHandler(url: url, options: [:])
    var text = ""
    if (try? handler.perform([request])) != nil, let observations = request.results {
        // Top to bottom (Vision's y axis points up).
        let lines = observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
        text = lines.joined(separator: "\n")
    }
    emit(["file": files[i], "text": text])
}
