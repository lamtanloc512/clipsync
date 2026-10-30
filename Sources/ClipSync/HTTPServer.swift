import Foundation
import Network
import Security

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }

    static func html(_ s: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(s.utf8))
    }

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func data(_ d: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: contentType, body: d)
    }
}

/// Result of looking at a request's headers before its body is read.
enum Admission {
    /// Read up to `maxBody` bytes of body, then call the handler.
    case accept(maxBody: Int)
    /// Answer immediately without reading the body.
    case reject(HTTPResponse)
}

struct HTTPRequestHead {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
    let contentLength: Int
}

/// Minimal HTTPS (HTTP/1.1 over TLS) server: one request per connection, Connection: close.
/// Everything runs on the main queue, which keeps pasteboard access simple.
final class HTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    typealias Admit = (HTTPRequestHead) -> Admission

    static let maxHeaderSize = 16 * 1024
    static let maxBodySize = 30 * 1024 * 1024
    static let maxConnections = 64
    /// A client must deliver its whole request within this time (slowloris protection).
    static let requestTimeout: TimeInterval = 20

    let port: UInt16
    private let identity: SecIdentity
    private let admit: Admit
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    var onStateChange: ((String) -> Void)?

    private final class Connection {
        let nw: NWConnection
        var buffer = Data()
        var head: HTTPRequestHead?
        var bodyStart = 0
        var sentContinue = false
        var timeout: Timer?
        init(_ nw: NWConnection) { self.nw = nw }
    }

    init(port: UInt16, identity: SecIdentity, admit: @escaping Admit, handler: @escaping Handler) {
        self.port = port
        self.identity = identity
        self.admit = admit
        self.handler = handler
    }

    func start() throws {
        let tls = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ClipSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        // No Bonjour advertisement: nothing uses it and it would broadcast the Mac's name.
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?("ready")
            case .failed(let error): self?.onStateChange?("failed: \(error.localizedDescription)")
            case .cancelled: self?.onStateChange?("stopped")
            default: break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.nw.cancel() }
        connections.removeAll()
    }

    // MARK: - Connection handling

    private func accept(_ nw: NWConnection) {
        // The listener binds every interface; only talk to local-network peers
        // (not global IPv6, public IPs or anything else that can reach the port).
        guard Self.isLocalNetwork(nw.endpoint), connections.count < Self.maxConnections else {
            nw.cancel()
            return
        }
        let connection = Connection(nw)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections[id]?.timeout?.invalidate()
                self?.connections[id] = nil
            default: break
            }
        }
        connection.timeout = scheduleTimer(after: Self.requestTimeout) { _ in nw.cancel() }
        nw.start(queue: .main)
        receive(connection)
    }

    private func receive(_ connection: Connection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.nw.cancel(); return }
            if let data { connection.buffer.append(data) }

            if connection.head == nil {
                switch Self.parseHead(connection.buffer) {
                case .incomplete:
                    break
                case .invalid(let status):
                    self.finish(connection, .text("Bad request", status: status))
                    return
                case .head(let head, let bodyStart):
                    // Decide on auth/limits from the headers alone, before buffering any body.
                    switch self.admit(head) {
                    case .reject(let response):
                        self.finish(connection, response)
                        return
                    case .accept(let maxBody):
                        guard head.contentLength <= min(maxBody, Self.maxBodySize) else {
                            self.finish(connection, .text("Payload too large", status: 413))
                            return
                        }
                    }
                    connection.head = head
                    connection.bodyStart = bodyStart
                }
            }

            if let head = connection.head {
                let available = connection.buffer.count - connection.bodyStart
                if available >= head.contentLength {
                    connection.timeout?.invalidate()
                    let start = connection.bodyStart
                    let body = Data(connection.buffer[start..<(start + head.contentLength)])
                    connection.buffer = Data()
                    let request = HTTPRequest(method: head.method, path: head.path, query: head.query,
                                              headers: head.headers, body: body)
                    self.handler(request) { response in
                        self.finish(connection, response)
                    }
                    return
                }
                if !connection.sentContinue, head.headers["expect"]?.lowercased() == "100-continue" {
                    // curl and some clients wait for this before sending large bodies.
                    connection.sentContinue = true
                    connection.nw.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                }
            }

            if error != nil || isComplete {
                connection.nw.cancel()
                return
            }
            self.receive(connection)
        }
    }

    private func finish(_ connection: Connection, _ response: HTTPResponse) {
        connection.timeout?.invalidate()
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Type"] = response.contentType
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        if headers["Cache-Control"] == nil { headers["Cache-Control"] = "no-store" }
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        headers["X-Frame-Options"] = "DENY"
        // Deliberately no CORS headers: only the same-origin web client may read responses.
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.nw.send(content: out, completion: .contentProcessed { _ in
            connection.nw.cancel()
        })
    }

    // MARK: - Peer filtering

    static func isLocalNetwork(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isPrivateIPv4(Array(address.rawValue))
        case .ipv6(let address):
            let b = Array(address.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }          // ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                      // fe80::/10 link-local
            if (b[0] & 0xfe) == 0xfc { return true }                                      // fc00::/7 unique local
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {      // ::ffff:a.b.c.d
                return isPrivateIPv4(Array(b[12..<16]))
            }
            return false
        default:
            return false
        }
    }

    /// Same ranges the CA's name constraints allow.
    static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168), (169, 254): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    // MARK: - Parsing

    enum HeadResult {
        case incomplete
        case invalid(status: Int)
        case head(HTTPRequestHead, bodyStart: Int)
    }

    static func parseHead(_ buffer: Data) -> HeadResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderSize ? .invalid(status: 431) : .incomplete
        }
        guard headerEnd.lowerBound - buffer.startIndex <= maxHeaderSize else { return .invalid(status: 431) }
        guard let text = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid(status: 400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(status: 400) }
        guard length <= maxBodySize else { return .invalid(status: 413) }

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://localhost" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        let head = HTTPRequestHead(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            contentLength: length
        )
        return .head(head, bodyStart: headerEnd.upperBound - buffer.startIndex)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        default: return "Status"
        }
    }
}
