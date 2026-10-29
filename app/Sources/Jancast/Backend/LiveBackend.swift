import AppKit

/// HTTP client for the real Python backend (docs/API.md).
@MainActor
final class LiveBackend: Backend {
    let isMock = false
    private let process = BackendProcess()
    private var baseURL: URL?
    private let session: URLSession

    var onUnexpectedExit: ((String, String) -> Void)? {
        get { process.onUnexpectedExit }
        set { process.onUnexpectedExit = newValue }
    }

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)
    }

    func start() async throws {
        if let port = ProcessInfo.processInfo.environment["JANCAST_API_PORT"].flatMap(Int.init) {
            // Attach to an already-running backend (development convenience).
            baseURL = URL(string: "http://127.0.0.1:\(port)")
        } else {
            let port = try await process.start()
            baseURL = URL(string: "http://127.0.0.1:\(port)")
        }
        // A few tries: right after the ready line a slow first start can
        // still take a moment to answer.
        for attempt in 1...3 {
            do {
                let _: HealthResponse = try await get("/api/health", timeout: 10)
                return
            } catch where attempt < 3 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func shutdown() {
        // Leave the backend at the default probe rate (matters when attached
        // to a backend that outlives the app; window onDisappear doesn't fire on quit).
        if let base = baseURL, var req = Optional(URLRequest(url: base.appendingPathComponent("/api/telemetry"))) {
            req.httpMethod = "POST"
            req.timeoutInterval = 0.5
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONCoding.encoder.encode(TelemetryRequest(level: "basic"))
            let done = DispatchSemaphore(value: 0)
            session.dataTask(with: req) { _, _, _ in done.signal() }.resume()
            _ = done.wait(timeout: .now() + 0.6)
        }
        process.shutdown()
    }

    func probe(path: String) async throws -> ProbeResult {
        try await get("/api/probe", query: [URLQueryItem(name: "path", value: path)], timeout: 60)
    }

    func peek(path: String) async throws -> ProbeResult {
        try await get("/api/probe", query: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "remember", value: "0")],
                      timeout: 60)
    }

    func recent(limit: Int) async throws -> RecentResponse {
        try await get("/api/recent", query: [URLQueryItem(name: "limit", value: String(limit))], timeout: 10)
    }

    func devices(_ query: DeviceQuery) async throws -> DevicesResponse {
        switch query {
        case .cached: return try await get("/api/devices", timeout: 30)
        case .probe: return try await get("/api/devices", query: [URLQueryItem(name: "probe", value: "1")], timeout: 6)
        case .refresh: return try await get("/api/devices", query: [URLQueryItem(name: "refresh", value: "1")], timeout: 30)
        }
    }

    func pair(deviceID: String) async throws -> OKResponse {
        try await post("/api/pair", body: PairRequest(deviceId: deviceID), timeout: 30)
    }

    func submitPin(_ pin: String) async throws -> OKResponse {
        try await post("/api/pair/pin", body: PinRequest(pin: pin), timeout: 30)
    }

    func play(_ request: PlayRequest) async throws -> OKResponse {
        try await post("/api/play", body: request, timeout: 30)
    }

    func control(_ request: ControlRequest) async throws -> OKResponse {
        try await post("/api/control", body: request, timeout: 15)
    }

    func state(since: Int) async throws -> StateResponse {
        try await get("/api/state", query: [URLQueryItem(name: "since", value: String(since))], timeout: 5)
    }

    func thumbs(path: String, make: Bool) async throws -> ThumbsInfo {
        var query = [URLQueryItem(name: "path", value: path)]
        if !make { query.append(URLQueryItem(name: "make", value: "0")) }
        return try await get("/api/thumbs", query: query, timeout: 10)
    }

    func thumbnail(_ info: ThumbsInfo, index: Int) async throws -> NSImage {
        try await image(info.url + "\(index).jpg")
    }

    func palette(_ info: ThumbsInfo) async throws -> NSImage {
        guard let path = info.palette else { throw BackendError.http(404, nil) }
        return try await image(path)
    }

    private func image(_ path: String) async throws -> NSImage {
        var req = URLRequest(url: try url(path, []))
        req.timeoutInterval = 5
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let image = NSImage(data: data) else { throw BackendError.http(code, nil) }
        return image
    }

    func localReport(_ report: LocalReport) async throws -> OKResponse {
        try await post("/api/local/report", body: report, timeout: 5)
    }

    func ocrStatus(path: String, subtitle: Int) async throws -> OCRStatus {
        try await get("/api/ocr", query: [URLQueryItem(name: "path", value: path),
                                          URLQueryItem(name: "subtitle", value: String(subtitle))], timeout: 10)
    }

    func setTelemetry(level: String) async throws -> OKResponse {
        try await post("/api/telemetry", body: TelemetryRequest(level: level), timeout: 5)
    }

    // MARK: - HTTP

    private func url(_ path: String, _ query: [URLQueryItem]) throws -> URL {
        guard let base = baseURL, var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw BackendError.notRunning
        }
        if !query.isEmpty {
            comps.queryItems = query
            // URLComponents leaves "+" as is, and the backend (like any form
            // decoder) reads it as a space: "S03 + Extras" became "S03   Extras".
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let u = comps.url else { throw BackendError.notRunning }
        return u
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> T {
        var req = URLRequest(url: try url(path, query))
        req.timeoutInterval = timeout
        return try await send(req)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, timeout: TimeInterval) async throws -> T {
        var req = URLRequest(url: try url(path, []))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONCoding.encoder.encode(body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            // Error bodies are {"ok": false, "error": "..."}; surface the message.
            // For OKResponse callers, pass the body through so they see ok=false.
            if T.self == OKResponse.self, let r = try? JSONCoding.decoder.decode(T.self, from: data) { return r }
            let msg = (try? JSONCoding.decoder.decode(OKResponse.self, from: data))?.error
            throw BackendError.http(code, msg)
        }
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw BackendError.decoding(String(describing: error))
        }
    }
}
