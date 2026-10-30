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
    /// For streamed uploads (`Admission.stream`): the file holding the body. The handler owns it
    /// and must move or delete it.
    var bodyFile: URL? = nil
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]
    /// Streams this file from disk instead of `body` (for large downloads).
    var file: (url: URL, length: Int)? = nil

    /// A response that streams `url` from disk, or nil if it isn't a readable regular file.
    static func file(_ url: URL, contentType: String) -> HTTPResponse? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        var response = HTTPResponse(status: 200, contentType: contentType, body: Data())
        response.file = (url, size)
        return response
    }

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
    /// Read up to `maxBody` bytes of body into memory, then call the handler.
    case accept(maxBody: Int)
    /// Write up to `maxBody` bytes of body straight to `file` (never held in memory), then call
    /// the handler with `bodyFile` set. Partial files are deleted if the upload breaks off.
    case stream(maxBody: Int, to: URL)
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
    /// Largest in-memory body (`Admission.accept`).
    static let maxBodySize = 30 * 1024 * 1024
    /// Sanity cap on any declared Content-Length; streamed uploads are limited by their admission.
    static let maxDeclaredLength = 64 * 1024 * 1024 * 1024
    /// Streams (uploads and downloads) are cut off after this long without progress.
    static let streamIdleTimeout: TimeInterval = 60
    static let streamChunk = 512 * 1024
    static let maxConnections = 64
    /// A client must deliver its whole request within this time (slowloris protection).
    static let requestTimeout: TimeInterval = 20
    /// How long a finished response may wait for the client to close before it is cut off.
    static let lingerTimeout: TimeInterval = 30

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
        // Streamed upload state.
        var sink: FileHandle?
        var sinkURL: URL?
        var received = 0
        var bodyDelivered = false
        init(_ nw: NWConnection) { self.nw = nw }

        /// Deletes a partially received upload (connection broke or request was refused).
        func discardPartialUpload() {
            try? sink?.close()
            sink = nil
            if let url = sinkURL, !bodyDelivered { try? FileManager.default.removeItem(at: url) }
            sinkURL = nil
        }
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
                self?.connections[id]?.discardPartialUpload()
                self?.connections[id] = nil
            default: break
            }
        }
        connection.timeout = scheduleTimer(after: Self.requestTimeout) { _ in nw.cancel() }
        nw.start(queue: .main)
        receive(connection)
    }

    private func receive(_ connection: Connection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.nw.cancel(); return }
            if let data, !data.isEmpty {
                if connection.sink != nil {
                    guard self.write(data, to: connection) else { return }
                } else {
                    connection.buffer.append(data)
                }
            }

            if connection.head == nil {
                switch Self.parseHead(connection.buffer) {
                case .incomplete:
                    break
                case .invalid(let status):
                    self.finish(connection, .text("Bad request", status: status))
                    return
                case .head(let head, let bodyStart):
                    // Decide on auth/limits from the headers alone, before reading any body.
                    switch self.admit(head) {
                    case .reject(let response):
                        self.finish(connection, response)
                        return
                    case .accept(let maxBody):
                        guard head.contentLength <= min(maxBody, Self.maxBodySize) else {
                            self.finish(connection, .text("Payload too large", status: 413))
                            return
                        }
                        connection.head = head
                        connection.bodyStart = bodyStart
                    case .stream(let maxBody, let file):
                        guard head.contentLength <= maxBody else {
                            self.finish(connection, .text("Payload too large", status: 413))
                            return
                        }
                        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                             attributes: [.posixPermissions: 0o600]),
                              let sink = try? FileHandle(forWritingTo: file) else {
                            self.finish(connection, .text("Cannot store the upload", status: 500))
                            return
                        }
                        connection.head = head
                        connection.sink = sink
                        connection.sinkURL = file
                        // Body bytes that arrived together with the headers.
                        let early = connection.buffer.dropFirst(bodyStart)
                        connection.buffer = Data()
                        if !early.isEmpty { guard self.write(Data(early), to: connection) else { return } }
                    }
                }
            }

            if let head = connection.head {
                if connection.sink != nil {
                    if connection.received >= head.contentLength {
                        self.deliverStreamedBody(connection, head: head)
                        return
                    }
                    self.resetIdleTimer(connection)
                } else {
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

    /// Appends upload bytes to the sink (never past Content-Length). Returns false after a failure.
    private func write(_ data: Data, to connection: Connection) -> Bool {
        guard let sink = connection.sink else { return false }
        let limit = (connection.head?.contentLength ?? 0) - connection.received
        let chunk = data.count > limit ? data.prefix(max(limit, 0)) : data
        do {
            try sink.write(contentsOf: chunk)
            connection.received += chunk.count
            return true
        } catch {
            NSLog("ClipSync: writing upload failed: %@", String(describing: error))
            connection.discardPartialUpload()
            finish(connection, .text("Cannot store the upload", status: 507))
            return false
        }
    }

    private func deliverStreamedBody(_ connection: Connection, head: HTTPRequestHead) {
        connection.timeout?.invalidate()
        try? connection.sink?.close()
        connection.sink = nil
        connection.bodyDelivered = true   // the handler owns the file from here on
        var request = HTTPRequest(method: head.method, path: head.path, query: head.query,
                                  headers: head.headers, body: Data())
        request.bodyFile = connection.sinkURL
        handler(request) { [weak self] response in
            self?.finish(connection, response)
        }
    }

    private func resetIdleTimer(_ connection: Connection) {
        connection.timeout?.invalidate()
        connection.timeout = scheduleTimer(after: Self.streamIdleTimeout) { _ in connection.nw.cancel() }
    }

    private func finish(_ connection: Connection, _ response: HTTPResponse) {
        connection.timeout?.invalidate()
        if !connection.bodyDelivered { connection.discardPartialUpload() }

        var fileHandle: FileHandle?
        if let file = response.file {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                finish(connection, .text("Not found", status: 404))
                return
            }
            fileHandle = handle
        }

        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Type"] = response.contentType
        headers["Content-Length"] = String(response.file?.length ?? response.body.count)
        headers["Connection"] = "close"
        if headers["Cache-Control"] == nil { headers["Cache-Control"] = "no-store" }
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        headers["X-Frame-Options"] = "DENY"
        // Deliberately no CORS headers: only the same-origin web client may read responses.
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        guard let fileHandle else {
            var out = Data(head.utf8)
            out.append(response.body)
            sendFinal(out, on: connection)
            return
        }
        connection.nw.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? fileHandle.close(); connection.nw.cancel(); return }
            self?.pump(fileHandle, to: connection)
        })
    }

    /// Streams a file in chunks; the next chunk is read only once the previous one was taken
    /// by the network stack, so memory use stays flat whatever the file size.
    private func pump(_ handle: FileHandle, to connection: Connection) {
        let chunk: Data?
        do { chunk = try handle.read(upToCount: Self.streamChunk) } catch { chunk = nil }
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            sendFinal(nil, on: connection)
            return
        }
        resetIdleTimer(connection)
        connection.nw.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? handle.close(); connection.nw.cancel(); return }
            self.pump(handle, to: connection)
        })
    }

    /// Sends the last bytes as the final message (TLS close_notify + FIN after the data), then lets
    /// the client finish reading and close first. Cancelling as soon as the data is handed to the
    /// stack can cut off large responses still in flight — phones then got a truncated stylesheet.
    private func sendFinal(_ data: Data?, on connection: Connection) {
        connection.nw.send(content: data, contentContext: .finalMessage, isComplete: true,
                           completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.nw.cancel(); return }
            connection.timeout?.invalidate()
            connection.timeout = scheduleTimer(after: Self.lingerTimeout) { _ in connection.nw.cancel() }
            self?.drainUntilClosed(connection)
        })
    }

    /// Reads (and discards) until the client closes its side, then releases the connection.
    private func drainUntilClosed(_ connection: Connection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil || self == nil {
                connection.timeout?.invalidate()
                connection.nw.cancel()
                return
            }
            self?.drainUntilClosed(connection)
        }
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
        guard length <= maxDeclaredLength else { return .invalid(status: 413) }

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
        case 303: return "See Other"
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
        case 500: return "Internal Server Error"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}
