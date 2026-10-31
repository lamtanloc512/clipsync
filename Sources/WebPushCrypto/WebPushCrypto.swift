import CryptoKit
import Security
import Foundation

/// Web Push message encryption (RFC 8291, "aes128gcm" content coding from RFC 8188) and VAPID
/// authentication (RFC 8292), using only CryptoKit. The push service (Google, Apple, Mozilla)
/// only ever sees the encrypted record.
public enum WebPushCrypto {
    public enum Failure: Error, Equatable {
        case invalidSubscriptionKey
        case invalidAuthSecret
        case payloadTooLarge
    }

    /// A phone's subscription keys, as `PushSubscription.toJSON().keys` gives them.
    public struct Subscriber {
        public let publicKey: P256.KeyAgreement.PublicKey   // "p256dh"
        public let authSecret: Data                          // "auth"

        public init(p256dh: String, auth: String) throws {
            guard let key = Data(base64URL: p256dh),
                  let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: key) else {
                throw Failure.invalidSubscriptionKey
            }
            guard let secret = Data(base64URL: auth), secret.count == 16 else { throw Failure.invalidAuthSecret }
            self.publicKey = publicKey
            self.authSecret = secret
        }
    }

    /// Largest plaintext that fits one 4096-byte record (the limit push services accept).
    public static let maxPayload = 3993

    /// Encrypts `payload` for `subscriber` into an aes128gcm body (single record).
    /// `senderKey` and `salt` are random per message; they are parameters only so tests can use
    /// the RFC 8291 test vector.
    public static func encrypt(
        _ payload: Data,
        for subscriber: Subscriber,
        senderKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        salt: Data = randomBytes(16)
    ) throws -> Data {
        guard payload.count <= maxPayload else { throw Failure.payloadTooLarge }
        let uaPublic = subscriber.publicKey.x963Representation
        let asPublic = senderKey.publicKey.x963Representation
        let shared = try senderKey.sharedSecretFromKeyAgreement(with: subscriber.publicKey)

        // IKM = HKDF(salt: auth_secret, ikm: ECDH, info: "WebPush: info" 0x00 ua_public as_public, 32)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(uaPublic)
        keyInfo.append(asPublic)
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: subscriber.authSecret,
                                                 sharedInfo: keyInfo, outputByteCount: 32)

        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                           info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)

        var plaintext = payload
        plaintext.append(0x02)   // padding delimiter of the last (only) record
        let sealed = try AES.GCM.seal(plaintext, using: cek,
                                      nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))

        // Header: salt(16) | record size(4) | key id length(1) | key id (sender public key)
        var body = salt
        body.append(contentsOf: [0x00, 0x00, 0x10, 0x00])   // 4096
        body.append(UInt8(asPublic.count))
        body.append(asPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    /// The `Authorization` header value for a request to `endpoint` (VAPID, RFC 8292).
    public static func vapidAuthorization(endpoint: URL, key: P256.Signing.PrivateKey, subject: String,
                                          expiry: Date = Date().addingTimeInterval(12 * 3600)) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw Failure.invalidSubscriptionKey }
        let audience = endpoint.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        let header = #"{"typ":"JWT","alg":"ES256"}"#
        let claims = #"{"aud":"\#(audience)","exp":\#(Int(expiry.timeIntervalSince1970)),"sub":"\#(subject)"}"#
        let signingInput = Data(header.utf8).base64URLEncoded() + "." + Data(claims.utf8).base64URLEncoded()
        let signature = try key.signature(for: Data(signingInput.utf8))
        let token = signingInput + "." + signature.rawRepresentation.base64URLEncoded()
        return "vapid t=\(token), k=\(key.publicKey.x963Representation.base64URLEncoded())"
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

public extension Data {
    init?(base64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
