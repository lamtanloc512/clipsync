import CryptoKit
import XCTest
@testable import WebPushCrypto

final class WebPushCryptoTests: XCTestCase {
    /// RFC 8291 Appendix A: the exact encrypted body for fixed keys and salt.
    func testRFC8291TestVector() throws {
        let senderKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64URL: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")))
        XCTAssertEqual(senderKey.publicKey.x963Representation.base64URLEncoded(),
                       "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
        let subscriber = try WebPushCrypto.Subscriber(
            p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
            auth: "BTBZMqHH6r4Tts7J_aSIgg")
        let body = try WebPushCrypto.encrypt(
            Data("When I grow up, I want to be a watermelon".utf8), for: subscriber,
            senderKey: senderKey, salt: XCTUnwrap(Data(base64URL: "DGv6ra1nlYgDCS1FRnbzlw")))
        XCTAssertEqual(body.base64URLEncoded(),
                       "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
    }

    /// The subscriber (phone) can decrypt what we send, with fresh random keys and salt.
    func testRoundTripWithRandomKeys() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let auth = WebPushCrypto.randomBytes(16)
        let subscriber = try WebPushCrypto.Subscriber(p256dh: phone.publicKey.x963Representation.base64URLEncoded(),
                                                      auth: auth.base64URLEncoded())
        let message = Data(#"{"kind":"text","v":7}"#.utf8)
        let body = try WebPushCrypto.encrypt(message, for: subscriber)

        // Decrypt as a browser would.
        let salt = body.prefix(16)
        XCTAssertEqual(Array(body[16..<20]), [0, 0, 0x10, 0])
        let idLength = Int(body[20])
        let senderPublic = try P256.KeyAgreement.PublicKey(x963Representation: body[21..<(21 + idLength)])
        let ciphertext = body.suffix(from: 21 + idLength)
        let shared = try phone.sharedSecretFromKeyAgreement(with: senderPublic)
        var info = Data("WebPush: info".utf8)
        info.append(0)
        info.append(phone.publicKey.x963Representation)
        info.append(senderPublic.x963Representation)
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: info, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                           info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }),
                                        ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try AES.GCM.open(box, using: cek)
        XCTAssertEqual(plaintext, message + Data([0x02]))
    }

    func testVAPIDHeaderIsAValidES256Token() throws {
        let key = P256.Signing.PrivateKey()
        let header = try WebPushCrypto.vapidAuthorization(
            endpoint: XCTUnwrap(URL(string: "https://fcm.googleapis.com/fcm/send/abc")), key: key,
            subject: "https://github.com/lamtanloc512/clipsync", expiry: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertTrue(header.hasPrefix("vapid t="))
        let parts = header.components(separatedBy: ", k=")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1], key.publicKey.x963Representation.base64URLEncoded())

        let token = String(parts[0].dropFirst("vapid t=".count))
        let segments = token.split(separator: ".").map(String.init)
        XCTAssertEqual(segments.count, 3)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64URL: segments[1]))) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://fcm.googleapis.com")
        XCTAssertEqual(claims["exp"] as? Int, 2_000_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64URL: segments[2])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((segments[0] + "." + segments[1]).utf8)))
    }

    func testRejectsBadSubscriptionsAndOversizedPayloads() throws {
        XCTAssertThrowsError(try WebPushCrypto.Subscriber(p256dh: "not-a-key", auth: "BTBZMqHH6r4Tts7J_aSIgg"))
        let phone = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64URLEncoded()
        XCTAssertThrowsError(try WebPushCrypto.Subscriber(p256dh: phone, auth: "short"))
        let subscriber = try WebPushCrypto.Subscriber(p256dh: phone, auth: WebPushCrypto.randomBytes(16).base64URLEncoded())
        XCTAssertThrowsError(try WebPushCrypto.encrypt(Data(count: WebPushCrypto.maxPayload + 1), for: subscriber))
    }
}
