import Foundation
import Observation

enum FrigateError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Frigate server in Settings."
        case .unauthorized: "Login failed. Check your username and password."
        case .http(let code): "The server returned HTTP \(code)."
        case .badResponse: "Unexpected response from the server."
        }
    }
}

/// Talks to the Frigate HTTP API.
///
/// - Port 5000: unauthenticated internal API (no username needed).
/// - Port 8971: authenticated API. We POST `/api/login`, and Frigate sets a
///   `frigate_token` cookie that the session sends on every later request.
@Observable
final class FrigateClient {
    let settings: ServerSettings

    private(set) var config: FrigateConfig?
    private(set) var version: String?
    /// Whether the server has any events at all; nil until checked.
    /// Detection may be off, in which case the app hides everything about events.
    private(set) var hasEvents: Bool?
    /// Cameras that aren't sending video right now, from the server's stats.
    private(set) var offlineCameras: Set<String> = []

    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var sessionAllowsSelfSigned: Bool
    @ObservationIgnored private var loggedIn = false

    init(settings: ServerSettings) {
        self.settings = settings
        sessionAllowsSelfSigned = settings.allowSelfSignedCertificates
        session = Self.makeSession(allowSelfSigned: sessionAllowsSelfSigned)
    }

    private static func makeSession(allowSelfSigned: Bool) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        let delegate = allowSelfSigned ? SelfSignedTrustDelegate() : nil
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// Call after the user edits settings.
    func reset() {
        loggedIn = false
        config = nil
        version = nil
        hasEvents = nil
        offlineCameras = []
        if let url = settings.baseURL, let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            cookies.forEach(HTTPCookieStorage.shared.deleteCookie)
        }
        if sessionAllowsSelfSigned != settings.allowSelfSignedCertificates {
            session.invalidateAndCancel()
            sessionAllowsSelfSigned = settings.allowSelfSignedCertificates
            session = Self.makeSession(allowSelfSigned: sessionAllowsSelfSigned)
        }
    }

    /// Enabled cameras in the user's chosen order.
    var cameraNames: [String] {
        settings.ordered(config?.cameraNames ?? [])
    }

    // MARK: - URLs

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = settings.baseURL else { throw FrigateError.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    func latestFrameURL(camera: String, height: Int) throws -> URL {
        try url("api/\(camera)/latest.jpg", query: [
            URLQueryItem(name: "h", value: String(height)),
            // Cache buster so each poll fetches a fresh frame.
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ])
    }

    /// Opens a WebSocket to the server (for example go2rtc's WebRTC signaling),
    /// using the same login cookie and certificate trust as every other request.
    func webSocket(path: String, query: [URLQueryItem] = []) async throws -> URLSessionWebSocketTask {
        try await ensureLoggedIn()
        var comps = URLComponents(url: try url(path, query: query), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        let task = session.webSocketTask(with: comps.url!)
        task.maximumMessageSize = 4 * 1024 * 1024
        return task
    }

    func thumbnailURL(event: FrigateEvent) throws -> URL {
        try url("api/events/\(event.id)/thumbnail.jpg")
    }

    func snapshotURL(event: FrigateEvent) throws -> URL {
        try url("api/events/\(event.id)/snapshot.jpg", query: [URLQueryItem(name: "bbox", value: "1")])
    }

    func clipURL(event: FrigateEvent) throws -> URL {
        try url("api/events/\(event.id)/clip.mp4")
    }

    // MARK: - Requests

    func login() async throws {
        guard settings.usesAuthentication else { return }
        var req = URLRequest(url: try url("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["user": settings.username, "password": settings.password])
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FrigateError.badResponse }
        if http.statusCode == 401 || http.statusCode == 400 { throw FrigateError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw FrigateError.http(http.statusCode) }
        loggedIn = true
    }

    func ensureLoggedIn() async throws {
        if settings.usesAuthentication && !loggedIn { try await login() }
    }

    /// GET with automatic login + one retry on 401.
    func data(from url: URL) async throws -> Data {
        if settings.usesAuthentication && !loggedIn { try await login() }
        var (data, response) = try await session.data(from: url)
        if (response as? HTTPURLResponse)?.statusCode == 401, settings.usesAuthentication {
            loggedIn = false
            try await login()
            (data, response) = try await session.data(from: url)
        }
        guard let http = response as? HTTPURLResponse else { throw FrigateError.badResponse }
        if http.statusCode == 401 { throw FrigateError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw FrigateError.http(http.statusCode) }
        return data
    }

    /// Downloads a file (e.g. a clip) to a temporary location and returns its local URL.
    func download(from url: URL, fileExtension: String) async throws -> URL {
        let data = try await data(from: url)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try data.write(to: dest)
        return dest
    }

    @discardableResult
    func loadConfig() async throws -> FrigateConfig {
        let data = try await data(from: url("api/config"))
        let cfg = try JSONDecoder().decode(FrigateConfig.self, from: data)
        config = cfg
        return cfg
    }

    @discardableResult
    func loadVersion() async throws -> String {
        let data = try await data(from: url("api/version"))
        let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
        version = v
        return v
    }

    func events(camera: String? = nil, label: String? = nil, before: Double? = nil, limit: Int = 50) async throws -> [FrigateEvent] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let camera { q.append(URLQueryItem(name: "cameras", value: camera)) }
        if let label { q.append(URLQueryItem(name: "labels", value: label)) }
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        let data = try await data(from: url("api/events", query: q))
        return try JSONDecoder().decode([FrigateEvent].self, from: data)
    }

    /// Checks whether the server (or one camera) has any events.
    func anyEvents(camera: String? = nil) async throws -> Bool {
        let found = try await !events(camera: camera, limit: 1).isEmpty
        if camera == nil { hasEvents = found }
        return found
    }

    /// Reads which cameras are offline. Frigate reports 0 frames per second for a
    /// camera whose stream has dropped.
    func refreshCameraStatus() async throws {
        struct Stats: Decodable {
            struct Camera: Decodable { let camera_fps: Double? }
            let cameras: [String: Camera]
        }
        let data = try await data(from: url("api/stats"))
        let stats = try JSONDecoder().decode(Stats.self, from: data)
        let offline = Set(stats.cameras.filter { ($0.value.camera_fps ?? 0) <= 0 }.keys)
        if offline != offlineCameras { offlineCameras = offline }
    }

    func isOffline(_ camera: String) -> Bool { offlineCameras.contains(camera) }

    func labels() async throws -> [String] {
        let data = try await data(from: url("api/labels"))
        return (try? JSONDecoder().decode([String].self, from: data))?.sorted() ?? []
    }
}

/// Accepts the server's certificate even if it is self-signed.
/// Only used when the user turns on "Allow self-signed certificate" in Settings.
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
