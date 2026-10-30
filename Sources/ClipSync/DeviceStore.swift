import CryptoKit
import Foundation

struct PairedDevice: Codable {
    let id: String
    var name: String
    /// SHA-256 of the device token; the token itself is only ever stored on the phone.
    let tokenHash: String
    let pairedAt: Date
}

struct PairRequest {
    enum State: String { case pending, accepted, rejected, expired }

    let id: String
    let name: String
    /// Short code shown on both screens so the user can check they are pairing the right phone.
    let code: String
    var state: State = .pending
    /// Set once accepted; handed to the phone exactly once.
    var token: String?
}

enum PairError: Error {
    /// The QR secret is missing, wrong or expired: the phone did not scan the current QR code.
    case invalidSecret
    case tooManyRequests
}

/// Paired devices (persisted) and in-flight pairing requests (memory only).
final class DeviceStore {
    private(set) var devices: [PairedDevice] = []
    private(set) var lastSeen: [String: Date] = [:]
    private var requests: [String: PairRequest] = [:]
    private var waiters: [String: [UUID: () -> Void]] = [:]
    private let fileURL = appSupportDirectory.appendingPathComponent("devices.json")

    static let maxPendingRequests = 3
    static let requestLifetime: TimeInterval = 120
    static let pairingSecretLifetime: TimeInterval = 600

    /// One-time secret embedded in the QR code. Only a phone that has seen the Mac's
    /// screen can start pairing, so nobody else on the network can spam pairing prompts.
    private var pairingSecret: String?
    private var pairingSecretTimer: Timer?
    /// The QR secret expired or was used; the QR window should show a fresh one.
    var onPairingSecretInvalidated: (() -> Void)?

    var onPairRequest: ((PairRequest) -> Void)?
    /// A request stopped being pending (accepted, rejected or expired).
    var onPairRequestClosed: ((String) -> Void)?
    var onDevicesChanged: (() -> Void)?

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = saved
        }
    }

    // MARK: - Auth

    func device(forToken token: String) -> PairedDevice? {
        guard !token.isEmpty else { return nil }
        let hash = Self.hash(token)
        guard let device = devices.first(where: { constantTimeEquals($0.tokenHash, hash) }) else { return nil }
        lastSeen[device.id] = Date()
        return device
    }

    func unpair(id: String) {
        devices.removeAll { $0.id == id }
        lastSeen[id] = nil
        save()
        onDevicesChanged?()
    }

    // MARK: - Pairing secret

    func issuePairingSecret() -> String {
        let secret = randomString(length: 24)
        pairingSecret = secret
        pairingSecretTimer?.invalidate()
        pairingSecretTimer = scheduleTimer(after: Self.pairingSecretLifetime) { [weak self] _ in
            self?.revokePairingSecret()
            self?.onPairingSecretInvalidated?()
        }
        return secret
    }

    func revokePairingSecret() {
        pairingSecret = nil
        pairingSecretTimer?.invalidate()
        pairingSecretTimer = nil
    }

    // MARK: - Pairing

    func createRequest(name: String, secret: String) -> Result<PairRequest, PairError> {
        guard let expected = pairingSecret, constantTimeEquals(secret, expected) else {
            return .failure(.invalidSecret)
        }
        let pending = requests.values.filter { $0.state == .pending }.count
        guard pending < Self.maxPendingRequests else { return .failure(.tooManyRequests) }

        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let request = PairRequest(
            id: UUID().uuidString,
            name: cleanName.isEmpty ? "Phone" : cleanName,
            code: String(format: "%04d", Int.random(in: 0...9999))
        )
        requests[request.id] = request

        scheduleTimer(after: Self.requestLifetime) { [weak self] _ in
            guard let self, var req = self.requests[request.id] else { return }
            if req.state == .pending {
                req.state = .expired
                self.requests[request.id] = req
                self.notify(request.id)
                self.onPairRequestClosed?(request.id)
            }
            // Drop the request (and any token nobody collected) shortly after.
            scheduleTimer(after: 60) { [weak self] _ in self?.requests[request.id] = nil }
        }

        onPairRequest?(request)
        return .success(request)
    }

    func resolve(id: String, accept: Bool) {
        guard var request = requests[id], request.state == .pending else { return }
        if accept {
            let token = randomString(length: 32)
            devices.append(PairedDevice(id: UUID().uuidString, name: request.name,
                                        tokenHash: Self.hash(token), pairedAt: Date()))
            save()
            request.state = .accepted
            request.token = token
            onDevicesChanged?()
        } else {
            request.state = .rejected
        }
        requests[id] = request
        notify(id)
        onPairRequestClosed?(id)
        // Each QR code is good for one decision; show a fresh one for the next phone.
        if pairingSecret != nil {
            revokePairingSecret()
            onPairingSecretInvalidated?()
        }
    }

    /// Current state of a request. Returns the token once for accepted requests.
    func takeStatus(id: String) -> PairRequest? {
        guard let request = requests[id] else { return nil }
        if request.state != .pending { requests[id] = nil }
        return request
    }

    func waitForResolution(id: String, timeout: TimeInterval, completion: @escaping () -> Void) {
        guard let request = requests[id], request.state == .pending else {
            completion()
            return
        }
        let waiterID = UUID()
        waiters[id, default: [:]][waiterID] = completion
        scheduleTimer(after: timeout) { [weak self] _ in
            guard let self, let waiter = self.waiters[id]?.removeValue(forKey: waiterID) else { return }
            waiter()
        }
    }

    private func notify(_ id: String) {
        let pending = waiters.removeValue(forKey: id) ?? [:]
        pending.values.forEach { $0() }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
