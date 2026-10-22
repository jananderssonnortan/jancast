// jancast OCR helper: recognises the text in subtitle images with Vision.
//
//   jancast-ocr <file listing one PNG path per line> [--fast] [language ...]
//
// Prints one JSON object per image: {"file": "...", "text": "line 1\nline 2"}.
// Built by jancast/ocrsubs.py with `swiftc -O` on first use.
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 2, let listing = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: jancast-ocr <listing> [languages...]\n".data(using: .utf8)!)
    exit(2)
}
let files = listing.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
let fast = args.dropFirst(2).contains("--fast")      // ~7x quicker, nearly as good on subtitles
let languages = args.dropFirst(2).filter { $0 != "--fast" }
var results = [String](repeating: "", count: files.count)
let lock = NSLock()

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
    // Printed as soon as each image is done, so the caller can show progress.
    let obj: [String: String] = ["file": files[i], "text": text]
    lock.lock()
    results[i] = text
    if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
    lock.unlock()
}
