import AppKit
import CryptoKit

/// Updates from the GitHub releases, without a framework: the newest release
/// carries `latest.json` (build number, zip, SHA-256; package-app.sh writes
/// it). The app checks it at launch (at most daily, if allowed in Settings)
/// and from the app menu; Install downloads the zip, checks it, and a small
/// shell helper swaps the app once Jancast has quit, then reopens it.
///
/// Only the downloadable app updates itself: a development build keeps its
/// sources. JANCAST_UPDATE_FEED points at another latest.json (testing).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Decodable, Equatable {
        let version: String
        let build: Int
        let url: URL
        let sha256: String
        /// What's new, in Markdown (docs/releases/<version>.md).
        var notes: String? = nil
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release)
        case checkFailed(String)
        /// Shown in the window (a failed check stays quiet).
        case installFailed(String)
    }

    private(set) var state = State.idle

    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    static let releasesPage = URL(string: "https://github.com/jananderssonnortan/jancast/releases/latest")!

    private let feed: URL?

    private init() {
        if let f = ProcessInfo.processInfo.environment["JANCAST_UPDATE_FEED"], !f.isEmpty {
            feed = f.hasPrefix("/") ? URL(fileURLWithPath: f) : URL(string: f)
        } else if BackendProcess.bundledRuntime != nil {
            feed = URL(string: "https://github.com/jananderssonnortan/jancast/releases/latest/download/latest.json")
        } else {
            feed = nil
        }
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
    }

    /// Whether this copy checks at all (not a development build).
    var isAvailable: Bool { feed != nil }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// Where the app can replace itself: not run from the disk image or from
    /// Downloads through App Translocation, and in a folder it may write to.
    static var canInstallInPlace: Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    // MARK: - Check

    /// At launch: at most once a day, when allowed in Settings.
    func checkAtLaunch() async {
        guard isAvailable, UserDefaults.standard.bool(forKey: Self.autoCheckKey) else { return }
        let testing = ProcessInfo.processInfo.environment["JANCAST_UPDATE_FEED"] != nil
        if !testing, let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 20 * 3600 { return }
        await check()
    }

    /// From the menu: says what it found, also when there is nothing new.
    func checkFromMenu() async {
        guard isAvailable else {
            alert("Updates", "This is a development build: it updates from its sources, not from the releases.")
            return
        }
        await check()
        switch state {
        case .available(let r):
            let a = NSAlert()
            a.messageText = "A newer Jancast is available"
            a.informativeText = "Jancast \(r.version) (build \(r.build)) — you have \(Self.currentVersion) (build \(Self.currentBuild))."
                + (Self.canInstallInPlace ? " Jancast quits, updates and opens again." : "")
                + (r.notes.map { "\n\n" + Self.plainNotes($0) } ?? "")
            a.addButton(withTitle: Self.canInstallInPlace ? "Install and Relaunch" : "Download")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { install() }
        case .upToDate:
            alert("Jancast is up to date", "Jancast \(Self.currentVersion) (build \(Self.currentBuild)) is the newest version.")
        case .checkFailed(let m):
            alert("Couldn’t check for updates", m)
        default:
            break
        }
    }

    private func check() async {
        guard let feed, !isBusy else { return }
        state = .checking
        do {
            var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("Jancast/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError("The update server answered HTTP \(http.statusCode).")
            }
            let r = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            state = r.build > Self.currentBuild ? .available(r) : .upToDate
        } catch {
            state = .checkFailed(error.localizedDescription)
        }
    }

    private var isBusy: Bool {
        if case .downloading = state { return true }
        return state == .checking
    }

    // MARK: - Install

    /// Install button: download, verify, swap and relaunch; where the app
    /// can't replace itself, the release page instead.
    func install() {
        guard case .available(let r) = state else { return }
        guard Self.canInstallInPlace else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        state = .downloading(r)
        Task {
            do {
                let app = try await download(r)
                try relaunch(replacingWith: app)
            } catch {
                state = .installFailed(error.localizedDescription)
            }
        }
    }

    /// The new Jancast.app, unpacked next to the zip and checked.
    private func download(_ r: Release) async throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/jancast/update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let (tmp, response) = try await URLSession.shared.download(from: r.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed (HTTP \(http.statusCode)).")
        }
        let zip = dir.appendingPathComponent("Jancast.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)

        let digest = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == r.sha256.lowercased() else { throw UpdateError("The download is damaged (checksum mismatch).") }

        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent("Jancast.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard Int(info?["CFBundleVersion"] as? String ?? "") == r.build else {
            throw UpdateError("The download doesn’t contain the expected Jancast build.")
        }
        return app
    }

    /// Hands over to a shell helper and quits: once Jancast has exited it
    /// moves the new app into place (the old one back if that fails) and
    /// opens it again.
    private func relaunch(replacingWith new: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        old="$2"; new="$3"; backup="$(dirname "$old")/.Jancast-previous.app"
        rm -rf "$backup"
        if mv "$old" "$backup"; then
          if mv "$new" "$old"; then rm -rf "$backup"; else mv "$backup" "$old"; fi
        fi
        open "$old"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "jancast-update", String(getpid()), Bundle.main.bundleURL.path, new.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw UpdateError("Unpacking the update failed.") }
        }.value
    }

    /// The notes without Markdown's marks, for an alert.
    static func plainNotes(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var l = String(line)
            if l.hasPrefix("#") { l = l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
