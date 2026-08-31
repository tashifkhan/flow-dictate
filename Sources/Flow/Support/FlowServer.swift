import Foundation
import Network
import OSLog

private let maximumHTTPRequestBytes = 1_048_576

/// A small HTTP API over loopback, so scripts, Raycast, and anything else on this Mac
/// can read Flow's data and drive a dictation.
///
/// Deliberately conservative: bound to 127.0.0.1 so nothing off-machine can reach it,
/// gated behind a bearer token, and off until you switch it on. Flow's whole premise is
/// that your speech stays on this Mac; an open port would undercut that.
@MainActor
final class FlowServer {
    private var listener: NWListener?
    private let log = Logger(subsystem: "sh.taf.flow", category: "server")
    private unowned let env: AppEnvironment

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Generated once and kept in defaults. Shown in Settings so you can copy it.
    static var token: String {
        let key = "apiToken"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static func regenerateToken() {
        UserDefaults.standard.removeObject(forKey: "apiToken")
        _ = token
    }

    // MARK: - Lifecycle

    func start(port: UInt16) {
        stop()
        lastError = nil
        do {
            let parameters = NWParameters.tcp
            // Loopback only. This is the security boundary, not the token.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in self?.receive(on: connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.log.info("API listening on 127.0.0.1:\(port, privacy: .public)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            log.error("API failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Request handling

    private func receive(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else { connection.cancel(); return }

                var accumulated = buffer
                if let data { accumulated.append(data) }

                guard accumulated.count <= maximumHTTPRequestBytes else {
                    let response = self.json(
                        ["error": "request too large"],
                        status: 413,
                        statusText: "Content Too Large"
                    )
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }

                // Wait for the full head, then for the body Content-Length promises.
                guard let request = HTTPRequest(accumulated) else {
                    if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: accumulated) }
                    return
                }

                let response = self.route(request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func route(_ request: HTTPRequest) -> Data {
        // Health is unauthenticated so a script can check "is Flow up" cheaply; it
        // reveals nothing but the version and whether the app is ready.
        if request.method == "GET", request.path == "/v1/health" {
            return json([
                "ok": true,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                "ready": !env.needsSetup,
            ])
        }

        guard request.bearer == Self.token else {
            return json(["error": "unauthorized"], status: 401, statusText: "Unauthorized")
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/stats"):
            let range = StatsRange(rawValue: request.query["range"] ?? "allTime") ?? .allTime
            let stats = Stats.compute(from: env.library.dailyStats, range: range)
            return json([
                "range": range.rawValue,
                "totalWords": stats.totalWords,
                "dictations": stats.dictationCount,
                "wordsPerMinute": stats.wordsPerMinute,
                "speakingSeconds": Int(stats.totalDuration.rounded()),
                "timeSavedSeconds": Int(stats.timeSaved.rounded()),
            ])

        case ("GET", "/v1/activity"):
            let stats = Stats.compute(from: env.library.dailyStats, range: .allTime)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            let days = stats.wordsByDay
                .sorted { $0.key < $1.key }
                .map { ["date": formatter.string(from: $0.key), "words": "\($0.value)"] }
            return json(["days": days])

        case ("GET", "/v1/history"):
            let limit = min(max(Int(request.query["limit"] ?? "") ?? 50, 0), 500)
            let query = request.query["q"]
            let rows = env.library.dictations
                .filter { record in
                    guard let query else { return true }
                    return record.raw.localizedCaseInsensitiveContains(query)
                        || record.cleaned.localizedCaseInsensitiveContains(query)
                }
                .prefix(limit)
                .map { record -> [String: Any] in
                    [
                        "id": record.id.uuidString,
                        "text": record.inserted,
                        "raw": record.raw,
                        "app": record.appName,
                        "pinned": record.pinned,
                        "durationSeconds": record.duration,
                        "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
                    ]
                }
            return json(["dictations": Array(rows)])

        case ("GET", "/v1/notes"):
            let rows = env.library.notes.map { note -> [String: Any] in
                [
                    "id": note.id.uuidString,
                    "title": note.displayTitle,
                    "text": note.text,
                    "pinned": note.pinned,
                    "summary": note.summary ?? "",
                    "updatedAt": ISO8601DateFormatter().string(from: note.updatedAt),
                ]
            }
            return json(["notes": rows])

        case ("POST", "/v1/notes"):
            guard let text = request.jsonBody?["text"] as? String else {
                return json(["error": "expected {\"text\": \"…\"}"], status: 400, statusText: "Bad Request")
            }
            var note = env.library.newNote()
            note.text = text
            env.library.save(note)
            return json(["id": note.id.uuidString])

        case ("POST", "/v1/dictate"):
            let action = request.jsonBody?["action"] as? String ?? "toggle"
            switch action {
            case "start" where !env.controller.phase.isBusy, "toggle":
                env.toggleFromUI()
            case "stop":
                if env.controller.phase.isBusy { env.toggleFromUI() }
            case "cancel":
                env.controller.cancel()
            default:
                break
            }
            return json(["phase": String(describing: env.controller.phase)])

        case ("POST", "/v1/insert"):
            guard let text = request.jsonBody?["text"] as? String else {
                return json(["error": "expected {\"text\": \"…\"}"], status: 400, statusText: "Bad Request")
            }
            env.controller.reinsert(text)
            return json(["inserted": true])

        default:
            return json(["error": "no such endpoint"], status: 404, statusText: "Not Found")
        }
    }

    private func json(_ object: Any, status: Int = 200, statusText: String = "OK") -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Just enough HTTP/1.1 to serve a local JSON API.
private struct HTTPRequest {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body = Data()

    var bearer: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        return String(parts[1])
    }

    var jsonBody: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// Returns nil when the request is not fully received yet.
    init?(_ data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = data.range(of: separator) else { return nil }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0])

        let target = String(requestLine[1])
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                query[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        } else {
            path = target
        }

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased().trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }

        guard let expected = Int(headers["content-length"] ?? "0"),
              expected >= 0,
              expected <= maximumHTTPRequestBytes else { return nil }
        let bodyStart = headEnd.upperBound
        let available = data.count - bodyStart
        guard available >= expected else { return nil }
        body = data[bodyStart..<(bodyStart + expected)]
    }
}
