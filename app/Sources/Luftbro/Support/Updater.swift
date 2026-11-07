import AppKit
import CryptoKit

/// Updates from the GitHub releases, without a framework: the newest release
/// carries `latest.json` (build number, zip, SHA-256; package-app.sh writes
/// it) and `latest.json.sig`, its Ed25519 signature, made by
/// scripts/publish_release.py with a key that never goes to GitHub. A feed
/// whose signature doesn't verify against `updateKey` is ignored, so write
/// access to the releases alone can't ship an update. The app checks at
/// launch (at most daily, if allowed in Settings) and from the app menu;
/// Install downloads the zip, checks it, and a small shell helper swaps the
/// app once Luftbro has quit, then reopens it.
///
/// Only the downloadable app updates itself: a development build keeps its
/// sources. LUFTBRO_UPDATE_FEED points at another latest.json and
/// LUFTBRO_UPDATE_KEY at another public key (testing).
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

        /// Only a release the feed can't have been tampered into: the zip
        /// from GitHub over https (the download follows GitHub's redirect to
        /// its object store, which is fine) and a checksum that is one.
        var looksGenuine: Bool {
            url.scheme == "https" && url.host == "github.com"
                && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
        }
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
    /// Why the last Install didn't get as far as replacing the app (a stalled
    /// download, a quit that didn't happen): shown with the offer to try again.
    private(set) var installError: String?

    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    static let releasesPage = URL(string: "https://github.com/luftbro/luftbro/releases/latest")!

    /// The public half of the release signing key (base64, raw Ed25519).
    private static let updateKey = "WVw7TweVdKxQhn7PCjkYE+nXLx0jilfwqUa8xulu+S8="

    private let feed: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    /// Downloads with limits, so a stalled connection ends instead of leaving
    /// "Downloading the update…" up for good. A request may wait a minute for
    /// data, the whole zip a quarter of an hour.
    private let downloads: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: cfg)
    }()

    private init() {
        if let f = ProcessInfo.processInfo.environment["LUFTBRO_UPDATE_FEED"], !f.isEmpty {
            feed = f.hasPrefix("/") ? URL(fileURLWithPath: f) : URL(string: f)
        } else if BackendProcess.bundledRuntime != nil {
            feed = URL(string: "https://github.com/luftbro/luftbro/releases/latest/download/latest.json")
        } else {
            feed = nil
        }
        let key = ProcessInfo.processInfo.environment["LUFTBRO_UPDATE_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.updateKey
        publicKey = Data(base64Encoded: key).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
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
        let testing = ProcessInfo.processInfo.environment["LUFTBRO_UPDATE_FEED"] != nil
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
            a.messageText = "A newer Luftbro is available"
            a.informativeText = "Luftbro \(r.version) (build \(r.build)) — you have \(Self.currentVersion) (build \(Self.currentBuild))."
                + (Self.canInstallInPlace ? " Luftbro quits, updates and opens again." : "")
                + (r.notes.map { "\n\n" + Self.plainNotes($0) } ?? "")
            a.addButton(withTitle: Self.canInstallInPlace ? "Install and Relaunch" : "Download")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { install() }
        case .upToDate:
            alert("Luftbro is up to date", "Luftbro \(Self.currentVersion) (build \(Self.currentBuild)) is the newest version.")
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
            let data = try await fetch(feed)
            let sigURL = feed.deletingLastPathComponent().appendingPathComponent(feed.lastPathComponent + ".sig")
            let sigText = try await fetch(sigURL, ifMissing: "This release isn’t signed, so Luftbro won’t install it.")
            guard let sig = Data(base64Encoded: String(decoding: sigText, as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)),
                  publicKey?.isValidSignature(sig, for: data) == true else {
                throw UpdateError("This release isn’t signed with Luftbro’s key, so Luftbro won’t install it.")
            }
            let r = try JSONDecoder().decode(Release.self, from: data)
            guard r.looksGenuine else { throw UpdateError("The update feed doesn’t look like Luftbro’s.") }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            state = r.build > Self.currentBuild ? .available(r) : .upToDate
        } catch {
            state = .checkFailed(error.localizedDescription)
        }
    }

    private func fetch(_ url: URL, ifMissing: String? = nil) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Luftbro/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 404, let ifMissing { throw UpdateError(ifMissing) }
            throw UpdateError("The update server answered HTTP \(http.statusCode).")
        }
        return data
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
        installError = nil
        state = .downloading(r)
        Task {
            do {
                let app = try await download(r)
                try relaunch(replacingWith: app, release: r)
            } catch let e as DownloadError {
                // The network let us down, not the release: offer Install again.
                installError = e.message
                state = .available(r)
            } catch {
                state = .installFailed(error.localizedDescription)
            }
        }
    }

    /// The new Luftbro.app, unpacked next to the zip and checked: the checksum
    /// from the feed, then that it is a real app folder claiming to be this
    /// app at the promised build, with a signature that still verifies.
    private func download(_ r: Release) async throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/luftbro/update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp: URL, response: URLResponse
        do {
            (tmp, response) = try await downloads.download(from: r.url)
        } catch {
            throw DownloadError("The download didn’t finish: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError("The download failed (HTTP \(http.statusCode)).")
        }
        let zip = dir.appendingPathComponent("Luftbro.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)

        let digest = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == r.sha256.lowercased() else { throw UpdateError("The download is damaged (checksum mismatch).") }

        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], failure: "Unpacking the update failed.")
        let app = dir.appendingPathComponent("Luftbro.app")
        // A symlink named Luftbro.app would make the helper swap in whatever
        // it points at; attributesOfItem doesn't follow links.
        let type = (try? FileManager.default.attributesOfItem(atPath: app.path))?[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw UpdateError("The download doesn’t contain a Luftbro app.") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard Int(info?["CFBundleVersion"] as? String ?? "") == r.build,
              info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download doesn’t contain the expected Luftbro build.")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                      failure: "The downloaded Luftbro isn’t signed as expected.")
        return app
    }

    /// Hands over to a shell helper and quits: once Luftbro has exited it
    /// moves the new app into place (the old one back if that fails) and
    /// opens it again. Quitting goes through AppDelegate.quit(): AppKit
    /// refuses a plain terminate while a sheet is up. If the app is still
    /// here two seconds later the quit was cancelled: the helper is stopped
    /// (it would otherwise swap the app under a running Luftbro) and the
    /// offer comes back.
    private func relaunch(replacingWith new: URL, release: Release) throws {
        let script = """
        waited=0
        while /bin/kill -0 "$1" 2>/dev/null; do
          /bin/sleep 0.2; waited=$((waited + 1))
          [ "$waited" -ge 300 ] && exit 1
        done
        old="$2"; new="$3"; backup="$(dirname "$old")/.Luftbro-previous.app"
        /bin/rm -rf "$backup"
        if /bin/mv "$old" "$backup"; then
          if /bin/mv "$new" "$old"; then /bin/rm -rf "$backup"; else /bin/mv "$backup" "$old"; fi
        fi
        /usr/bin/open "$old"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "luftbro-update", String(getpid()), Bundle.main.bundleURL.path, new.path]
        try p.run()
        AppDelegate.quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                if p.isRunning { p.terminate() }
                self.installError = "Luftbro didn’t quit, so the update wasn’t installed."
                self.state = .available(release)
            }
        }
    }

    private func run(_ tool: String, _ args: [String], failure: String) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw UpdateError(failure) }
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

/// A download that didn't arrive (as opposed to one that arrived wrong).
private struct DownloadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
