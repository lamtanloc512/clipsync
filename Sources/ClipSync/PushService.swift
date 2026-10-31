import CryptoKit
import Foundation
import WebPushCrypto

/// Web Push: tells phones about a new clipboard item while ClipSync is closed on them.
///
/// No server of our own: the Mac signs (VAPID) and encrypts (RFC 8291) each message itself and
/// hands it to the phone's push service (Google FCM, Apple, Mozilla), which delivers it even when
/// the browser is closed. By default the message carries no clipboard content at all — the phone
/// fetches it from the Mac over the local network when the notification is tapped.
final class PushService {
    struct Subscription: Codable {
        var endpoint: String
        var p256dh: String
        var auth: String
        /// Show a preview of the content in the notification (still end-to-end encrypted).
        var preview: Bool
    }

    private(set) var subscriptions: [String: Subscription] = [:]   // paired-device id → subscription
    private let fileURL = appSupportDirectory.appendingPathComponent("push.json")
    private let keyURL = appSupportDirectory.appendingPathComponent("vapid.key")
    private lazy var key: P256.Signing.PrivateKey = loadOrCreateKey()
    private let session = URLSession(configuration: .ephemeral)
    private var pendingTimer: Timer?

    /// Contact for push services, required by Apple (RFC 8292 "sub").
    static let subject = "https://github.com/lamtanloc512/clipsync"
    /// Only real push services: a paired device must not make the Mac send requests elsewhere.
    static let allowedHosts: Set<String> = ["fcm.googleapis.com", "web.push.apple.com",
                                            "updates.push.services.mozilla.com"]
    static let allowedHostSuffixes = [".push.apple.com", ".notify.windows.com"]
    /// Copies within this window are collapsed into one notification.
    static let debounce: TimeInterval = 1.5

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Subscription].self, from: data) {
            subscriptions = saved
        }
    }

    /// The VAPID public key phones subscribe with (base64url, uncompressed P-256 point).
    var publicKey: String { key.publicKey.x963Representation.base64URLEncoded() }

    // MARK: - Subscriptions

    enum SubscribeError: Error { case badEndpoint, badKeys }

    func subscribe(deviceID: String, endpoint: String, p256dh: String, auth: String, preview: Bool) throws {
        guard let url = URL(string: endpoint), Self.isAllowed(url) else { throw SubscribeError.badEndpoint }
        guard (try? WebPushCrypto.Subscriber(p256dh: p256dh, auth: auth)) != nil else { throw SubscribeError.badKeys }
        subscriptions[deviceID] = Subscription(endpoint: endpoint, p256dh: p256dh, auth: auth, preview: preview)
        save()
    }

    func unsubscribe(deviceID: String) {
        guard subscriptions.removeValue(forKey: deviceID) != nil else { return }
        save()
    }

    /// Drops subscriptions of devices that are no longer paired.
    func prune(keeping deviceIDs: Set<String>) {
        let before = subscriptions.count
        subscriptions = subscriptions.filter { deviceIDs.contains($0.key) }
        if subscriptions.count != before { save() }
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil else { return false }
        return allowedHosts.contains(host) || allowedHostSuffixes.contains { host.hasSuffix($0) }
    }

    // MARK: - Sending

    /// Schedules a notification about `item` for every subscribed device except those `skip` says
    /// don't need one (the sender, or phones that have ClipSync open and sync by themselves).
    func notify(about item: ClipItem, version: Int, epoch: String, skip: @escaping (String) -> Bool) {
        guard !subscriptions.isEmpty else { return }
        pendingTimer?.invalidate()
        pendingTimer = scheduleTimer(after: Self.debounce) { [weak self] _ in
            guard let self else { return }
            for (deviceID, subscription) in self.subscriptions where !skip(deviceID) && item.sourceID != deviceID {
                self.send(Self.payload(for: item, version: version, epoch: epoch, preview: subscription.preview),
                          to: subscription, deviceID: deviceID)
            }
        }
    }

    static func payload(for item: ClipItem, version: Int, epoch: String, preview: Bool) -> Data {
        var message: [String: Any] = ["v": version, "e": epoch, "k": item.kind.rawValue, "s": item.source]
        if preview {
            switch item.kind {
            case .text: message["t"] = String((item.text ?? "").prefix(140))
            case .file: message["n"] = String((item.text ?? "").prefix(80))
            case .image: break
            }
        }
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
    }

    private func send(_ payload: Data, to subscription: Subscription, deviceID: String) {
        guard let url = URL(string: subscription.endpoint), Self.isAllowed(url),
              let subscriber = try? WebPushCrypto.Subscriber(p256dh: subscription.p256dh, auth: subscription.auth),
              let body = try? WebPushCrypto.encrypt(payload, for: subscriber),
              let authorization = try? WebPushCrypto.vapidAuthorization(endpoint: url, key: key, subject: Self.subject)
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("120", forHTTPHeaderField: "TTL")            // stale clipboard news is useless
        request.setValue("high", forHTTPHeaderField: "Urgency")
        request.setValue("clipboard", forHTTPHeaderField: "Topic")     // replaces an undelivered older one
        request.timeoutInterval = 20

        session.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if status == 404 || status == 410 {
                    // The phone unsubscribed or the subscription expired.
                    self?.unsubscribe(deviceID: deviceID)
                } else if error != nil || !(200..<300).contains(status) {
                    NSLog("ClipSync: push to %@ failed (%d) %@", url.host ?? "?", status,
                          error.map { String(describing: $0) } ?? "")
                }
            }
        }.resume()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func loadOrCreateKey() -> P256.Signing.PrivateKey {
        if let raw = try? Data(contentsOf: keyURL), let saved = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return saved
        }
        let fresh = P256.Signing.PrivateKey()
        try? fresh.rawRepresentation.write(to: keyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return fresh
    }
}
