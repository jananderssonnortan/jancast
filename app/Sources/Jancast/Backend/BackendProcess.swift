import Foundation

/// Spawns `<backend_dir>/.venv/bin/python -m jancast serve --api-port 0`,
/// waits for `JANCAST_READY {"port": N}` on stdout and keeps the child's stdin
/// pipe open for the lifetime of the app (the backend exits when it closes).
/// It runs as "Jancast Backend" (a copy of Python's launcher) so Activity
/// Monitor names it, falling back to plain Python if that copy won't start.
@MainActor
final class BackendProcess {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var readyContinuation: CheckedContinuation<Int, Error>?
    private var timeoutTask: Task<Void, Never>?
    private(set) var logTail = ""
    private var isShuttingDown = false
    private var didBecomeReady = false

    var onUnexpectedExit: ((String, String) -> Void)?

    static var backendDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["JANCAST_BACKEND_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        // build-app.sh puts the bundle at <project>/build/Jancast.app, so the
        // project (with .venv) is two levels up - this survives moving the folder.
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let project = bundle.deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.isExecutableFile(atPath: project.appendingPathComponent(".venv/bin/python").path) {
                return project
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("development/jancast", isDirectory: true)
    }

    func start(timeout: TimeInterval = 30) async throws -> Int {
        let dir = Self.backendDirectory
        let python = dir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw BackendError.launch(
                "Python environment not found at \(python.path). Set JANCAST_BACKEND_DIR to the folder containing .venv and the jancast package.",
                log: "")
        }
        if let named = Self.namedLauncher(for: python) {
            do {
                return try await launch(named, venvPython: python, dir: dir, timeout: timeout)
            } catch {
                let log = logTail
                reset()
                appendLog(Data("[Jancast Backend launcher failed, using python: \(error.localizedDescription)]\n\(log)\n".utf8))
            }
        }
        return try await launch(python, venvPython: nil, dir: dir, timeout: timeout)
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

    /// A copy of the venv's Python launcher named "Jancast Backend", in the
    /// cache, refreshed when Python changes (Homebrew upgrades move it).
    /// `__PYVENV_LAUNCHER__` tells it which venv it belongs to.
    private static func namedLauncher(for python: URL) -> URL? {
        let fm = FileManager.default
        // <framework>/Versions/3.x/bin/python3.x → <framework>/Versions/3.x/Resources/Python.app/…
        let real = python.resolvingSymlinksInPath()
        let source = real.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
        guard fm.isExecutableFile(atPath: source.path) else { return nil }
        let cache = ProcessInfo.processInfo.environment["JANCAST_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/jancast")
        let bin = cache.appendingPathComponent("bin", isDirectory: true)
        let target = bin.appendingPathComponent("Jancast Backend")
        let stamp = bin.appendingPathComponent("Jancast Backend.source")
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? -1
        let want = "\(source.path)\n\(size)"
        if fm.isExecutableFile(atPath: target.path), (try? String(contentsOf: stamp, encoding: .utf8)) == want {
            return target
        }
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let tmp = bin.appendingPathComponent("Jancast Backend.tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
            try want.write(to: stamp, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    private func launch(_ executable: URL, venvPython: URL?, dir: URL, timeout: TimeInterval) async throws -> Int {
        let p = Process()
        p.executableURL = executable
        p.arguments = ["-m", "jancast", "serve", "--api-port", "0"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
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

    // MARK: - Private

    private func handleStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if line.hasPrefix("JANCAST_READY") {
                let json = line.dropFirst("JANCAST_READY".count).trimmingCharacters(in: .whitespaces)
                if let d = json.data(using: .utf8), let ready = try? JSONDecoder().decode(ReadyLine.self, from: d) {
                    succeedReady(ready.port)
                } else {
                    failReady("Could not parse the backend's ready line: \(line)")
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
    }

    private func succeedReady(_ port: Int) {
        timeoutTask?.cancel()
        didBecomeReady = true
        readyContinuation?.resume(returning: port)
        readyContinuation = nil
    }

    private func failReady(_ message: String) {
        timeoutTask?.cancel()
        // Give stderr a moment to flush so the tail includes the traceback.
        let cont = readyContinuation
        readyContinuation = nil
        guard let cont else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                cont.resume(throwing: BackendError.launch(message, log: self.logTail))
            }
        }
    }
}
