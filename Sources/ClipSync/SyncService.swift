import Foundation
import CoreServices
import UniformTypeIdentifiers

/// Glues the HTTPS server to the clipboard store, handles pairing and per-device auth.
final class SyncService {
    let store = ClipboardStore()
    let devices = DeviceStore()
    let certificates = CertificateManager()
    let hostnamePublisher = HostnamePublisher()
    private var server: HTTPServer?
    private var addressTimer: Timer?

    let macName = Host.current().localizedName ?? "Mac"
    /// Changes every launch, so phones can tell a restarted Mac (whose versions start over) apart.
    let epoch = String(UUID().uuidString.prefix(8))

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "port")
        return (1024...65535).contains(stored) ? UInt16(stored) : 8765
    }

    /// Called when a phone pushes something to the Mac.
    var onReceive: ((ClipItem) -> Void)?
    /// Called when a phone sent a file (already saved in Downloads): (file, device name).
    var onFileReceived: ((URL, String) -> Void)?

    /// Largest file a phone may send (default 20 GB; `defaults write com.lamtanloc.clipsync maxUploadGB -int N`).
    var maxUploadBytes: Int {
        let gb = UserDefaults.standard.integer(forKey: "maxUploadGB")
        return (gb > 0 ? gb : 20) * 1024 * 1024 * 1024
    }

    /// Short-lived download links for file items: ticket → (item id, expiry).
    private var downloadTickets: [String: (itemID: String, expires: Date)] = [:]
    static let ticketLifetime: TimeInterval = 600
    var onServerState: ((String) -> Void)?

    func start() throws {
        store.start()
        hostnamePublisher.update(addresses: Self.localIPv4Interfaces())
        try startServer()
        // Wi‑Fi changes give the Mac a new IP; reissue the certificate so phones keep connecting.
        addressTimer = scheduleTimer(after: 15, repeats: true) { [weak self] _ in
            self?.checkAddresses()
        }
    }

    private func startServer() throws {
        let identity = try certificates.serverIdentity(dnsNames: dnsNames, ips: Self.localIPv4Addresses())
        let server = HTTPServer(port: port, identity: identity, admit: { [weak self] head in
            self?.admit(head) ?? .reject(.text("Gone", status: 503))
        }, handler: { [weak self] request, respond in
            guard let self else { respond(.text("Gone", status: 503)); return }
            self.handle(request, respond: respond)
        })
        server.onStateChange = { [weak self] state in self?.onServerState?(state) }
        try server.start()
        self.server = server
    }

    func checkAddresses() {
        hostnamePublisher.update(addresses: Self.localIPv4Interfaces())
        guard !certificates.covers(dnsNames: dnsNames, ips: Self.localIPv4Addresses()) else { return }
        server?.stop()
        server = nil
        onServerState?("restarting…")
        // Give the old listener a moment to release the port.
        scheduleTimer(after: 1) { [weak self] _ in
            do { try self?.startServer() } catch { self?.onServerState?("failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - URLs

    /// The neutral name phones use ("clipsync.local", published by `HostnamePublisher`).
    /// Unlike the IP it survives DHCP changes, and unlike the Mac's own Bonjour name it doesn't
    /// reveal the owner's name. The certificate is issued for it (plus IPs for the fallback).
    var hostname: String { hostnamePublisher.hostname }
    var dnsNames: [String] { [hostname] }

    /// QR targets: the published name first, the current IP as a fallback for phones that can't
    /// resolve .local names. The one-time secret goes in the #fragment, which browsers never send.
    func pairingURLs(secret: String) -> [String] {
        let hosts = dnsNames + Array(Self.localIPv4Addresses().prefix(1))
        return hosts.map { "https://\($0):\(port)/#k=\(secret)" }
    }

    // MARK: - Admission (headers only, before any body is read)

    static let maxTextBytes = 2 * 1024 * 1024
    private static let publicRoutes: Set<String> = [
        "GET /", "GET /index.html", "GET /app.css", "GET /app.js", "GET /manifest.webmanifest", "GET /icon.svg",
        "GET /icon-180.png", "GET /icon-192.png", "GET /icon-512.png", "GET /icon-maskable-512.png",
        "GET /ca.crt", "GET /ca.mobileconfig",
        "POST /api/pair", "GET /api/pair/status",
    ]

    private func admit(_ head: HTTPRequestHead) -> Admission {
        // DNS-rebinding / misdirected-request defence: the Host must be one of our own names.
        let allowedHosts = Set(dnsNames + Self.localIPv4Addresses() + ["localhost", "127.0.0.1"])
        guard let host = Self.hostName(fromHostHeader: head.headers["host"]), allowedHosts.contains(host) else {
            return .reject(.text("Unknown host", status: 400))
        }
        // Browsers send Origin on cross-site requests; only the web client's own origin may call us.
        // (Shortcuts and curl send no Origin.)
        if let origin = head.headers["origin"] {
            let allowedOrigins = Set(allowedHosts.map { "https://\($0):\(port)" })
            guard allowedOrigins.contains(origin.lowercased()) else {
                return .reject(.json(["error": "cross-origin request refused"], status: 403))
            }
        }
        if Self.publicRoutes.contains("\(head.method) \(head.path)") {
            return .accept(maxBody: 4096)
        }
        // Download links carry their own short-lived ticket instead of the device token (browsers
        // can't add headers to a download).
        if head.method == "GET", head.path.hasPrefix("/dl/") {
            return .accept(maxBody: 0)
        }
        guard head.path.hasPrefix("/api/") else {
            return .reject(.text("Not found", status: 404))
        }
        // Unauthenticated clients never get to upload a body.
        guard Self.authorizedDevice(headers: head.headers, devices: devices) != nil else {
            return .reject(.json(["error": "unauthorized"], status: 401))
        }
        if head.method == "POST", head.path == "/api/files" {
            return admitUpload(head)
        }
        return .accept(maxBody: HTTPServer.maxBodySize)
    }

    /// File uploads are written straight to disk next to their destination (same volume, so the
    /// final move is atomic) — never held in memory.
    private func admitUpload(_ head: HTTPRequestHead) -> Admission {
        guard head.contentLength > 0 else { return .reject(.json(["error": "empty file"], status: 400)) }
        guard head.contentLength <= maxUploadBytes else {
            return .reject(.json(["error": "file too large", "max": maxUploadBytes], status: 413))
        }
        let downloads = Self.downloadsFolder
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard Int64(head.contentLength) + 256 * 1024 * 1024 < free else {
            return .reject(.json(["error": "not enough space on the Mac"], status: 507))
        }
        return .stream(maxBody: head.contentLength,
                       to: downloads.appendingPathComponent(".clipsync-\(UUID().uuidString).part"))
    }

    static func hostName(fromHostHeader header: String?) -> String? {
        guard var host = header?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") {                       // [ipv6]:port
            guard let end = host.firstIndex(of: "]") else { return nil }
            return String(host[host.index(after: host.startIndex)..<end])
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    // MARK: - Routing

    private func handle(_ req: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            var page = HTTPResponse.html(WebAssets.indexHTML)
            // No inline scripts at all: the client is served as /app.js.
            page.headers["Content-Security-Policy"] =
                "default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; " +
                "img-src 'self' blob:; connect-src 'self'; manifest-src 'self'; " +
                "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
            respond(page)
            return
        case ("GET", "/app.css"):
            respond(Self.staticAsset(WebAssets.appCSS, gzipped: Self.appCSSGzip, type: "text/css; charset=utf-8", request: req))
            return
        case ("GET", "/app.js"):
            respond(Self.staticAsset(WebAssets.appJS, gzipped: Self.appJSGzip, type: "text/javascript; charset=utf-8", request: req))
            return
        case ("GET", "/manifest.webmanifest"):
            respond(Self.staticAsset(WebAssets.manifest, type: "application/manifest+json", request: req))
            return
        case ("GET", "/icon.svg"):
            respond(Self.staticAsset(WebAssets.iconSVG, type: "image/svg+xml", request: req))
            return
        case ("GET", let path) where WebAssets.pngIcons[path] != nil:
            var response = HTTPResponse.data(Data(base64Encoded: WebAssets.pngIcons[path] ?? "") ?? Data(),
                                             contentType: "image/png")
            response.headers["Cache-Control"] = "no-cache"
            respond(response)
            return
        case ("GET", "/ca.crt"):
            guard let der = certificates.caCertificateDER else { respond(.text("No CA", status: 404)); return }
            var response = HTTPResponse.data(der, contentType: "application/x-x509-ca-cert")
            response.headers["Content-Disposition"] = "attachment; filename=\"ClipSync-CA.crt\""
            respond(response)
            return
        case ("GET", "/ca.mobileconfig"):
            guard let profile = certificates.mobileConfig(name: hostname) else {
                respond(.text("No CA", status: 404))
                return
            }
            respond(.data(profile, contentType: "application/x-apple-aspen-config"))
            return
        case ("POST", "/api/pair"):
            startPairing(req, respond: respond)
            return
        case ("GET", "/api/pair/status"):
            pairStatus(req, respond: respond)
            return
        default:
            break
        }

        if req.method == "GET", req.path.hasPrefix("/dl/") {
            respond(ticketDownload(req.path))
            return
        }
        guard req.path.hasPrefix("/api/") else {
            respond(.text("Not found", status: 404))
            return
        }
        guard let device = Self.authorizedDevice(headers: req.headers, devices: devices) else {
            respond(.json(["error": "unauthorized"], status: 401))
            return
        }

        switch (req.method, req.path) {
        case ("GET", "/api/ping"):
            respond(.json(["mac": macName, "device": device.name, "version": store.version]))

        case ("GET", "/api/clipboard"):
            // Long poll: ?since=<version>&wait=<seconds>
            let since = Int(req.query["since"] ?? "") ?? -1
            let wait = min(max(Double(req.query["wait"] ?? "0") ?? 0, 0), 30)
            if wait > 0 {
                store.waitForChange(since: since, timeout: wait) { [weak self] in
                    guard let self else { return }
                    // The device may have been unpaired while this request was waiting.
                    guard self.devices.devices.contains(where: { $0.id == device.id }) else {
                        respond(.json(["error": "unauthorized"], status: 401))
                        return
                    }
                    respond(.json(self.currentJSON(for: device)))
                }
            } else {
                respond(.json(currentJSON(for: device)))
            }

        case ("GET", "/api/clipboard/raw"):
            // Text as text/plain, image as image/png, a file as itself — handy for iOS Shortcuts.
            guard let item = store.current else { respond(.text("")); return }
            switch item.kind {
            case .text: respond(.text(item.text ?? ""))
            case .image: respond(.data(item.image ?? Data(), contentType: "image/png"))
            case .file: respond(Self.download(item) ?? .text("File no longer available", status: 410))
            }

        case ("POST", "/api/files"):
            respond(finishUpload(req, device: device))

        case ("POST", "/api/files/ticket"):
            guard let id = req.query["id"], let item = store.file(withID: id),
                  let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) else {
                respond(.json(["error": "file no longer available"], status: 410))
                return
            }
            let now = Date()
            downloadTickets = downloadTickets.filter { $0.value.expires > now }
            let ticket = randomString(length: 32)
            downloadTickets[ticket] = (item.id, now.addingTimeInterval(Self.ticketLifetime))
            let name = item.text ?? "file"
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "file"
            respond(.json(["url": "/dl/\(ticket)/\(encoded)"]))

        case ("GET", "/api/clipboard/image"):
            guard let item = store.current, item.kind == .image, let png = item.image else {
                respond(.text("No image", status: 404))
                return
            }
            respond(.data(png, contentType: "image/png"))

        case ("POST", "/api/clipboard"):
            respond(receive(req, device: device))

        case ("POST", "/api/unpair"):
            devices.unpair(id: device.id)
            respond(.json(["ok": true]))

        default:
            respond(.text("Not found", status: 404))
        }
    }

    // MARK: - Pairing

    private func startPairing(_ req: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        let name = body?["name"] as? String ?? "Phone"
        let secret = body?["secret"] as? String ?? ""
        switch devices.createRequest(name: name, secret: secret) {
        case .success(let request):
            respond(.json(["id": request.id, "code": request.code])) // no Mac name to unpaired clients
        case .failure(.invalidSecret):
            respond(.json(["error": "invalid_secret"], status: 403))
        case .failure(.tooManyRequests):
            respond(.json(["error": "too_many_requests"], status: 429))
        }
    }

    private func pairStatus(_ req: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let id = req.query["id"] ?? ""
        let wait = min(max(Double(req.query["wait"] ?? "0") ?? 0, 0), 30)
        devices.waitForResolution(id: id, timeout: wait) { [weak self] in
            guard let self else { return }
            guard let request = self.devices.takeStatus(id: id) else {
                respond(.json(["state": "expired"], status: 410))
                return
            }
            var obj: [String: Any] = ["state": request.state.rawValue]
            if let token = request.token { obj["token"] = token }
            respond(.json(obj))
        }
    }

    // MARK: - Clipboard

    private func receive(_ req: HTTPRequest, device: PairedDevice) -> HTTPResponse {
        let contentType = (req.headers["content-type"] ?? "").lowercased()
        var text: String?

        if contentType.hasPrefix("application/json") {
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let value = obj["text"] as? String else {
                return .json(["error": "expected {\"text\": \"...\"}"], status: 400)
            }
            text = value
        } else if !contentType.hasPrefix("image/"), let value = String(data: req.body, encoding: .utf8), !value.isEmpty {
            text = value
        }

        if let text {
            guard text.utf8.count <= Self.maxTextBytes else {
                return .json(["error": "text too large"], status: 413)
            }
            store.setText(text, source: device.name, sourceID: device.id)
        } else {
            // image/* or an untyped binary body (e.g. Shortcuts "File" with a photo).
            switch store.setImage(req.body, source: device.name, sourceID: device.id) {
            case .ok: break
            case .tooLarge: return .json(["error": "image too large"], status: 413)
            case .unsupported: return .json(["error": "unsupported content"], status: 415)
            }
        }

        if let item = store.current { onReceive?(item) }
        return .json(["ok": true, "version": store.version])
    }

    private func currentJSON(for device: PairedDevice) -> [String: Any] {
        var obj: [String: Any] = ["version": store.version, "epoch": epoch]
        if let item = store.current {
            obj["id"] = item.id
            obj["kind"] = item.kind.rawValue
            if item.kind == .file { obj["size"] = item.fileSize ?? 0 }
            obj["source"] = item.source
            // Lets the phone skip echoing back what it just sent.
            obj["mine"] = item.sourceID == device.id
            obj["date"] = item.date.timeIntervalSince1970
            if let text = item.text { obj["text"] = text }
        }
        return obj
    }

    private static let appCSSGzip = Data(base64Encoded: WebAssets.appCSSGzip)
    private static let appJSGzip = Data(base64Encoded: WebAssets.appJSGzip)

    /// Serves gzip when the browser accepts it. Always revalidated ("no-cache"): a long-lived cache
    /// would keep a damaged copy around for good (v1.1.0 had that problem with truncated responses).
    private static func staticAsset(_ body: String, gzipped: Data? = nil, type: String, request: HTTPRequest) -> HTTPResponse {
        let acceptsGzip = (request.headers["accept-encoding"] ?? "").lowercased().contains("gzip")
        var response: HTTPResponse
        if let gzipped, acceptsGzip {
            response = HTTPResponse.data(gzipped, contentType: type)
            response.headers["Content-Encoding"] = "gzip"
        } else {
            response = HTTPResponse.data(Data(body.utf8), contentType: type)
        }
        if gzipped != nil { response.headers["Vary"] = "Accept-Encoding" }
        response.headers["Cache-Control"] = "no-cache"
        return response
    }

    // MARK: - Files

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// Moves a finished upload into Downloads under a safe, unique name, marks it as downloaded
    /// from the network (Gatekeeper checks it like any download) and puts it on the clipboard.
    private func finishUpload(_ req: HTTPRequest, device: PairedDevice) -> HTTPResponse {
        guard let temp = req.bodyFile else { return .json(["error": "no file"], status: 400) }
        let name = Self.safeFileName(req.headers["x-filename"].flatMap { $0.removingPercentEncoding } ?? "")
        let destination = Self.uniqueURL(for: name, in: Self.downloadsFolder)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return .json(["error": "could not save the file"], status: 500)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "ClipSync",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var marked = destination
        try? marked.setResourceValues(values)

        store.setFile(destination, source: device.name, sourceID: device.id)
        onFileReceived?(destination, device.name)
        if let item = store.current { onReceive?(item) }
        return .json(["ok": true, "name": destination.lastPathComponent, "version": store.version])
    }

    private func ticketDownload(_ path: String) -> HTTPResponse {
        // /dl/<ticket>/<name>; the name part is only there so the browser saves a sensible filename.
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, let entry = downloadTickets[String(parts[1])], entry.expires > Date(),
              let item = store.file(withID: entry.itemID) else {
            return .text("This download link has expired. Tap Download again.", status: 410)
        }
        return Self.download(item) ?? .text("File no longer available", status: 410)
    }

    /// Streams a file item from disk as an attachment.
    private static func download(_ item: ClipItem) -> HTTPResponse? {
        guard let url = item.fileURL else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        guard var response = HTTPResponse.file(url, contentType: mime) else { return nil }
        let name = url.lastPathComponent
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 0x20 ? Character($0) : "_" })
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        response.headers["Content-Disposition"] = "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
        return response
    }

    /// Strips paths, control characters and leading dots; keeps names short and non-empty.
    static func safeFileName(_ raw: String) -> String {
        var name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            name = String(base.prefix(200 - ext.count - 1)) + (ext.isEmpty ? "" : "." + ext)
        }
        return name.isEmpty ? "File from phone" : name
    }

    /// "name.ext", then "name 2.ext", "name 3.ext"… — never overwrites an existing file.
    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Token only from headers — never from the URL, where it would leak into history and logs.
    private static func authorizedDevice(headers: [String: String], devices: DeviceStore) -> PairedDevice? {
        var token = headers["x-token"] ?? ""
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            token = String(auth.dropFirst(7))
        }
        return devices.device(forToken: token)
    }

    // MARK: - Network

    /// LAN IPv4 addresses, Wi‑Fi/Ethernet (en*) first.
    static func localIPv4Addresses() -> [String] {
        localIPv4Interfaces().map(\.address)
    }

    /// (interface, IPv4 address) pairs, Wi‑Fi/Ethernet (en*) first.
    static func localIPv4Interfaces() -> [(interface: String, address: String)] {
        var results: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            // Skip VPN tunnels and virtual bridges.
            if name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("awdl") { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                results.append((name, String(cString: host)))
            }
        }
        return results
            .sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }
            .map { (interface: $0.name, address: $0.address) }
    }
}
