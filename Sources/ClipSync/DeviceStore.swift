import CryptoKit
import Foundation

struct PairedDevice: Codable {
    let id: String
    var name: String
    /// SHA-256 of the device token; the token itself is only ever stored on the phone.
    let tokenHash: String
    let pairedAt: Date
}

/// Paired devices (persisted) and the one-time pairing secret (memory only).
final class DeviceStore {
    private(set) var devices: [PairedDevice] = []
    private(set) var lastSeen: [String: Date] = [:]
    private let fileURL = appSupportDirectory.appendingPathComponent("devices.json")

    static let pairingSecretLifetime: TimeInterval = 600

    /// One-time secret embedded in the QR code. Presenting it pairs the phone with no further
    /// confirmation: only someone who can see the Mac's screen has it.
    private var pairingSecret: String?
    private var pairingSecretTimer: Timer?
    /// The QR secret expired or was used; the QR window should show a fresh one.
    var onPairingSecretInvalidated: (() -> Void)?

    var onDevicePaired: ((PairedDevice) -> Void)?
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
        // 12 characters from a 31-letter alphabet (~59 bits): short enough to type into an iPhone
        // home-screen app, far too many to guess in the 10 minutes it lives.
        let secret = randomString(length: 12)
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

    /// Spends the secret on a new device and returns its token, or nil if the secret is wrong.
    func pair(name: String, secret: String) -> String? {
        guard let expected = pairingSecret, constantTimeEquals(secret, expected) else { return nil }
        revokePairingSecret()

        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let token = randomString(length: 32)
        let device = PairedDevice(id: UUID().uuidString, name: cleanName.isEmpty ? "Phone" : cleanName,
                                  tokenHash: Self.hash(token), pairedAt: Date())
        devices.append(device)
        save()
        onDevicesChanged?()
        onDevicePaired?(device)
        return token
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
