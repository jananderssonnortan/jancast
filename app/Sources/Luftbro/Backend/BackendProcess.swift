import Foundation

/// Spawns `<backend_dir>/.venv/bin/python -m luftbro serve --api-port 0`,
/// waits for `LUFTBRO_READY {"port": N, "token": "…"}` on stdout and keeps the
/// child's stdin pipe open for the lifetime of the app (the backend exits when
/// it closes). The token goes with every request (LiveBackend), so nothing
/// else on the Mac can drive the backend's local port.
/// It runs as "Luftbro Backend" (a copy of Python's launcher) so Activity
/// Monitor names it, falling back to plain Python if that copy won't start.
/// The downloadable app (package-app.sh) brings its own Python, backend,
/// ffmpeg and OCR helper in Contents/Resources and uses those instead.
@MainActor
final class BackendProcess {
    /// What the ready line says: where to connect and the secret to say so.
    struct Endpoint {
        let port: Int
        let token: String?
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var readyContinuation: CheckedContinuation<Endpoint, Error>?
    private var timeoutTask: Task<Void, Never>?
    private(set) var logTail = ""
    private var isShuttingDown = false
    private var didBecomeReady = false
    /// Who waits for the process to end in `stop()` (the restart path).
    private var exitContinuation: CheckedContinuation<Void, Never>?

    var onUnexpectedExit: ((String, String) -> Void)?

    static var backendDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["LUFTBRO_BACKEND_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let res = bundledRuntime { return res }
        // build-app.sh puts the bundle at <project>/build/Luftbro.app, so the
        // project (with .venv) is two levels up - this survives moving the folder.
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let project = bundle.deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.isExecutableFile(atPath: project.appendingPathComponent(".venv/bin/python").path) {
                return project
            }
        }
        // A development build run from SwiftPM's build folder: the project is
        // the nearest folder above it with .venv and the luftbro package
        // (whatever the folder is called).
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            if FileManager.default.isExecutableFile(atPath: d.appendingPathComponent(".venv/bin/python").path),
               FileManager.default.fileExists(atPath: d.appendingPathComponent("luftbro/__init__.py").path) {
                return d
            }
            dir = d.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("development/luftbro", isDirectory: true)
    }

    /// Contents/Resources of the self-contained app, or nil for a development build.
    static var bundledRuntime: URL? {
        guard let res = Bundle.main.resourceURL,
              FileManager.default.isExecutableFile(atPath: res.appendingPathComponent("python/bin/python3").path),
              FileManager.default.fileExists(atPath: res.appendingPathComponent("backend/luftbro").path)
        else { return nil }
        return res
    }

    /// 90 s: the first start after installing or updating can be slow while
    /// macOS checks the thousands of files in the bundled Python (30 s can
    /// run out, "did not report ready").
    func start(timeout: TimeInterval = 90) async throws -> Endpoint {
        let dir = Self.backendDirectory
        if dir == Self.bundledRuntime { return try await startBundled(dir, timeout: timeout) }
        let python = dir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw BackendError.launch(
                "Python environment not found at \(python.path). Set LUFTBRO_BACKEND_DIR to the folder containing .venv and the luftbro package.",
                log: "")
        }
        if let named = Self.namedLauncher(for: python) {
            do {
                return try await launch(named, venvPython: python, dir: dir, timeout: timeout)
            } catch {
                let log = logTail
                reset()
                appendLog(Data("[Luftbro Backend launcher failed, using python: \(error.localizedDescription)]\n\(log)\n".utf8))
            }
        }
        return try await launch(python, venvPython: nil, dir: dir, timeout: timeout)
    }

    /// Python, ffmpeg/ffprobe and the OCR helper all from inside the app.
    private func startBundled(_ res: URL, timeout: TimeInterval) async throws -> Endpoint {
        await Self.clearQuarantine(res)
        let bin = res.appendingPathComponent("python/bin")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let env = [
            "PYTHONPATH": res.appendingPathComponent("backend").path,
            "PYTHONDONTWRITEBYTECODE": "1",          // the signed bundle must not change
            "PATH": res.appendingPathComponent("bin").path + ":" + path,
            "LUFTBRO_OCR_HELPER": res.appendingPathComponent("bin/luftbro-ocr").path,
        ]
        let named = bin.appendingPathComponent("Luftbro Backend")
        if FileManager.default.isExecutableFile(atPath: named.path) {
            do {
                return try await launch(named, venvPython: nil, dir: res, extraEnv: env, isolated: true, timeout: timeout)
            } catch {
                let log = logTail
                reset()
                appendLog(Data("[Luftbro Backend launcher failed, using python3: \(error.localizedDescription)]\n\(log)\n".utf8))
            }
        }
        return try await launch(bin.appendingPathComponent("python3"), venvPython: nil, dir: res, extraEnv: env,
                                isolated: true, timeout: timeout)
    }

    /// A downloaded app keeps macOS's quarantine flag on every file inside. Once
    /// the user has allowed Luftbro itself, clear it from the bundled Python and
    /// tools too, so starting them isn't blocked separately (best effort: a
    /// read-only or translocated bundle keeps it). xattr walks the whole
    /// bundle (seconds on the first launch), so it runs off the main thread.
    private static func clearQuarantine(_ res: URL) async {
        let python = res.appendingPathComponent("python/bin/python3").resolvingSymlinksInPath().path
        guard getxattr(python, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return }
        let path = res.path
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", "com.apple.quarantine", path]
            try? p.run()
            p.waitUntilExit()
        }.value
    }

    private func reset() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdinPipe = nil
        stdoutBuffer = Data()
        logTail = ""
        didBecomeReady = false
    }

    /// A copy of the venv's Python launcher named "Luftbro Backend", in the
    /// cache, refreshed when Python changes (Homebrew upgrades move it).
    /// `__PYVENV_LAUNCHER__` tells it which venv it belongs to.
    private static func namedLauncher(for python: URL) -> URL? {
        let fm = FileManager.default
        // <framework>/Versions/3.x/bin/python3.x → <framework>/Versions/3.x/Resources/Python.app/…
        let real = python.resolvingSymlinksInPath()
        let source = real.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
        guard fm.isExecutableFile(atPath: source.path) else { return nil }
        let cache = ProcessInfo.processInfo.environment["LUFTBRO_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/luftbro")
        let bin = cache.appendingPathComponent("bin", isDirectory: true)
        let target = bin.appendingPathComponent("Luftbro Backend")
        let stamp = bin.appendingPathComponent("Luftbro Backend.source")
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? -1
        let want = "\(source.path)\n\(size)"
        if fm.isExecutableFile(atPath: target.path), (try? String(contentsOf: stamp, encoding: .utf8)) == want {
            return target
        }
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let tmp = bin.appendingPathComponent("Luftbro Backend.tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
            try want.write(to: stamp, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    /// The child's environment. The bundled Python (`isolated`) gets only what
    /// it needs, so PYTHONHOME, PYTHONSTARTUP and the like, and code in
    /// ~/.local site-packages (whose .pth files run at start, ahead of the
    /// bundle's own packages), can't run inside Luftbro. A development
    /// venv keeps the shell's environment (its tools may need it), minus the
    /// two variables that run or swap out code before the backend starts.
    private static func environment(isolated: Bool, extra: [String: String]) -> [String: String] {
        let all = ProcessInfo.processInfo.environment
        var env: [String: String]
        if isolated {
            let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "TERM"]
            env = all.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") || $0.key.hasPrefix("LUFTBRO_") }
        } else {
            env = all
            env["PYTHONSTARTUP"] = nil
            env["PYTHONHOME"] = nil
        }
        env["PYTHONUNBUFFERED"] = "1"
        env.merge(extra) { _, new in new }
        return env
    }

    private func launch(_ executable: URL, venvPython: URL?, dir: URL, extraEnv: [String: String] = [:],
                        isolated: Bool = false, timeout: TimeInterval) async throws -> Endpoint {
        let p = Process()
        p.executableURL = executable
        // -s: no user site-packages, -B: no .pyc files written (the bundle is
        // signed) — for the bundled Python only; a venv already keeps both.
        p.arguments = (isolated ? ["-s", "-B"] : []) + ["-m", "luftbro", "serve", "--api-port", "0"]
        p.currentDirectoryURL = dir
        var env = Self.environment(isolated: isolated, extra: extraEnv)
        if let venvPython { env["__PYVENV_LAUNCHER__"] = venvPython.path }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleStdout(data) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendLog(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleExit(status) } }
        }

        do {
            try p.run()
        } catch {
            throw BackendError.launch("Could not launch the backend: \(error.localizedDescription)", log: "")
        }
        process = p
        stdinPipe = inPipe

        return try await withCheckedThrowingContinuation { cont in
            self.readyContinuation = cont
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.failReady("The backend did not report ready within \(Int(timeout)) s.")
                self.process?.terminate()
            }
        }
    }

    /// At quit (applicationWillTerminate): synchronous, the app is going away.
    func shutdown() {
        isShuttingDown = true
        timeoutTask?.cancel()
        // Closing stdin is the documented way to stop the backend. Give it a
        // moment to stop the session and delete its work dir (a full-size copy
        // of the stream), then SIGTERM as backup (the backend cleans up on that too).
        try? stdinPipe?.fileHandleForWriting.close()
        guard let p = process else { return }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
    }

    /// The same for a restart ("Try Again"), without holding the main thread
    /// for the seconds the backend takes to clean up. Waits for the exit (up
    /// to 2 s), then SIGTERM.
    func stop() async {
        isShuttingDown = true
        timeoutTask?.cancel()
        try? stdinPipe?.fileHandleForWriting.close()
        guard let p = process, p.isRunning else { return }
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if p.isRunning { p.terminate() }
            self?.resumeExit()
        }
        // Registered before anything else can run on the main actor, so an
        // exit that is already on its way to handleExit can't slip past it.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exitContinuation = cont
        }
        deadline.cancel()
    }

    // MARK: - Private

    private func handleStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if line.hasPrefix("LUFTBRO_READY") {
                let json = line.dropFirst("LUFTBRO_READY".count).trimmingCharacters(in: .whitespaces)
                if let d = json.data(using: .utf8), let ready = try? JSONDecoder().decode(ReadyLine.self, from: d) {
                    succeedReady(Endpoint(port: ready.port, token: ready.token))
                } else {
                    // The line is logged without the token: the log tail ends up
                    // in the failure view and in copied reports.
                    failReady("Could not parse the backend's ready line.")
                }
            } else if !line.isEmpty {
                appendLog(Data((line + "\n").utf8))
            }
        }
    }

    private func appendLog(_ data: Data) {
        logTail += String(decoding: data, as: UTF8.self)
        if logTail.count > 16_000 { logTail = String(logTail.suffix(12_000)) }
    }

    private func handleExit(_ status: Int32) {
        if readyContinuation != nil {
            failReady("The backend exited during startup (exit code \(status)).")
        } else if didBecomeReady && !isShuttingDown {
            onUnexpectedExit?("The backend stopped unexpectedly (exit code \(status)).", logTail)
        }
        resumeExit()
    }

    private func resumeExit() {
        exitContinuation?.resume()
        exitContinuation = nil
    }

    private func succeedReady(_ endpoint: Endpoint) {
        timeoutTask?.cancel()
        didBecomeReady = true
        readyContinuation?.resume(returning: endpoint)
        readyContinuation = nil
    }

    /// Fails the start after a moment, so stderr has flushed and the tail
    /// includes the traceback. The continuation stays until then: a ready line
    /// that lands in that moment (the exit and the stdout data race to the main
    /// queue) still wins.
    private func failReady(_ message: String) {
        timeoutTask?.cancel()
        guard readyContinuation != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                guard let cont = self.readyContinuation else { return }     // ready, or failed, meanwhile
                self.readyContinuation = nil
                cont.resume(throwing: BackendError.launch(message, log: self.logTail))
            }
        }
    }
}
