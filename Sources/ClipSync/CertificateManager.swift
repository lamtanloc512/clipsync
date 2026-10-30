import CryptoKit
import Foundation
import Security

enum CertificateError: LocalizedError {
    case openssl(String)
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .openssl(let message): return "openssl failed: \(message)"
        case .importFailed(let status): return "Could not load TLS identity (OSStatus \(status))"
        }
    }
}

/// Creates a private, name‑constrained CA for this Mac and uses it to issue the HTTPS server
/// certificate. Phones install/trust the CA once; the server certificate can then be reissued
/// (e.g. when the Wi‑Fi IP changes) without the phone noticing.
///
/// Uses the system `/usr/bin/openssl` (LibreSSL) so there are no third‑party dependencies.
final class CertificateManager {
    private let directory: URL
    private let openssl = "/usr/bin/openssl"
    private let p12Password = "clipsync"
    private var issuedThisLaunch = false

    private struct ServerMeta: Codable {
        let dns: [String]
        let ips: [String]
        let notAfter: Date
    }

    init() {
        directory = appSupportDirectory.appendingPathComponent("certs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - Public

    /// DER-encoded CA certificate (served to phones as /ca.crt and inside the iOS profile).
    var caCertificateDER: Data? { try? Data(contentsOf: file("ca.der")) }

    /// SHA-256 fingerprint of the CA, as shown by iOS/Android certificate details.
    var caFingerprint: String? {
        guard let der = caCertificateDER else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Returns a TLS identity whose certificate covers all given names/addresses,
    /// reissuing the server certificate if needed.
    func serverIdentity(dnsNames: [String], ips: [String]) throws -> SecIdentity {
        try ensureCA()
        if needsReissue(dnsNames: dnsNames, ips: ips) {
            try issueServerCertificate(dnsNames: dnsNames, ips: ips)
        }
        return try importIdentity()
    }

    func covers(dnsNames: [String], ips: [String]) -> Bool {
        guard let meta = loadMeta() else { return false }
        return Set(dnsNames).isSubset(of: meta.dns) && Set(ips).isSubset(of: meta.ips)
    }

    /// iOS configuration profile that installs the CA as a root certificate.
    /// `name` is the neutral hostname (e.g. "clipsync.local"): the profile is downloadable by anyone
    /// on the network, so it must not reveal the Mac's own (often personal) name.
    func mobileConfig(name: String) -> Data? {
        guard let der = caCertificateDER else { return nil }
        let idSuffix = String((caFingerprint ?? "x").replacingOccurrences(of: ":", with: "").prefix(16))
        let certPayload: [String: Any] = [
            "PayloadCertificateFileName": "ClipSync-CA.cer",
            "PayloadContent": der,
            "PayloadDescription": "Lets this device connect securely to ClipSync at \(name).",
            "PayloadDisplayName": "ClipSync CA (\(name))",
            "PayloadIdentifier": "com.lamtanloc.clipsync.ca.\(idSuffix)",
            "PayloadType": "com.apple.security.root",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
        ]
        let profile: [String: Any] = [
            "PayloadContent": [certPayload],
            "PayloadDescription": "Trust the private certificate of ClipSync at \(name). It is only valid for local network addresses.",
            "PayloadDisplayName": "ClipSync (\(name))",
            "PayloadIdentifier": "com.lamtanloc.clipsync.profile.\(idSuffix)",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    // MARK: - CA

    private func ensureCA() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file("ca.key").path),
           fm.fileExists(atPath: file("ca.crt").path),
           fm.fileExists(atPath: file("ca.der").path) {
            return
        }
        // X.509 limits CN to 64 characters; Mac names can be longer.
        // A random tag instead of the Mac's name: the CA is public (served as /ca.crt) and the
        // Mac's name is often its owner's name. The tag still tells several Macs apart.
        let name = randomString(length: 6).uppercased()
        let config = """
        [req]
        distinguished_name = dn
        prompt = no

        [dn]
        CN = ClipSync Local CA (\(name))
        O = ClipSync

        [v3_ca]
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, keyCertSign, cRLSign
        extendedKeyUsage = serverAuth
        subjectKeyIdentifier = hash
        nameConstraints = critical, \(Self.nameConstraints)
        """
        try config.write(to: file("ca.cnf"), atomically: true, encoding: .utf8)
        try run(["genrsa", "-out", "ca.key", "2048"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("ca.key").path)
        try run(["req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "3650",
                 "-config", "ca.cnf", "-extensions", "v3_ca", "-out", "ca.crt"])
        try run(["x509", "-in", "ca.crt", "-outform", "DER", "-out", "ca.der"])
        // A new CA invalidates any old server certificate.
        try? FileManager.default.removeItem(at: file("server.json"))
    }

    /// The CA can only vouch for private network addresses and *.local names,
    /// so a leaked CA key cannot be used to impersonate real websites.
    private static let nameConstraints = [
        "permitted;IP:10.0.0.0/255.0.0.0",
        "permitted;IP:172.16.0.0/255.240.0.0",
        "permitted;IP:192.168.0.0/255.255.0.0",
        "permitted;IP:169.254.0.0/255.255.0.0",
        "permitted;IP:100.64.0.0/255.192.0.0", // CGNAT / Tailscale
        "permitted;IP:127.0.0.0/255.0.0.0",
        "permitted;DNS:local",
        "permitted;DNS:localhost",
        // No email or URI names at all (".invalid" can never match a real address).
        "permitted;email:.invalid",
        "permitted;URI:.invalid",
    ].joined(separator: ", ")

    // MARK: - Server certificate

    private func needsReissue(dnsNames: [String], ips: [String]) -> Bool {
        // Before macOS 15 the identity has to go through the login keychain; a fresh key per
        // launch keeps it owned by the current build and avoids keychain access prompts.
        if !Self.supportsMemoryOnlyImport && !issuedThisLaunch { return true }
        guard let meta = loadMeta(),
              FileManager.default.fileExists(atPath: file("server.p12").path) else { return true }
        if meta.notAfter < Date().addingTimeInterval(30 * 24 * 3600) { return true }
        return !covers(dnsNames: dnsNames, ips: ips)
    }

    private func issueServerCertificate(dnsNames: [String], ips: [String]) throws {
        let dns = Array(Set(dnsNames + ["localhost"])).sorted()
        let addresses = Array(Set(ips + ["127.0.0.1"])).sorted()
        let commonName = dns.first { $0.hasSuffix(".local") && $0.count <= 64 } ?? "localhost"

        var alt: [String] = []
        for (i, name) in dns.enumerated() { alt.append("DNS.\(i + 1) = \(name)") }
        for (i, ip) in addresses.enumerated() { alt.append("IP.\(i + 1) = \(ip)") }

        // iOS rejects TLS server certificates valid for more than 825 days.
        let days = 397
        let config = """
        [req]
        distinguished_name = dn
        prompt = no

        [dn]
        CN = \(commonName)
        O = ClipSync

        [v3_server]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid, issuer
        subjectAltName = @alt

        [alt]
        \(alt.joined(separator: "\n"))
        """
        try config.write(to: file("server.cnf"), atomically: true, encoding: .utf8)
        let serial = String(UInt64.random(in: 1...UInt64(Int64.max)))

        try run(["genrsa", "-out", "server.key", "2048"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("server.key").path)
        try run(["req", "-new", "-key", "server.key", "-config", "server.cnf", "-out", "server.csr"])
        try run(["x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
                 "-set_serial", serial, "-days", String(days), "-sha256",
                 "-extfile", "server.cnf", "-extensions", "v3_server", "-out", "server.crt"])
        try run(["pkcs12", "-export", "-inkey", "server.key", "-in", "server.crt", "-certfile", "ca.crt",
                 "-name", "ClipSync", "-passout", "pass:\(p12Password)", "-out", "server.p12"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("server.p12").path)
        // The key now lives only inside the .p12; don't leave loose copies around.
        for leftover in ["server.key", "server.csr", "server.cnf"] {
            try? FileManager.default.removeItem(at: file(leftover))
        }

        let meta = ServerMeta(dns: dns, ips: addresses,
                              notAfter: Date().addingTimeInterval(TimeInterval(days) * 24 * 3600))
        try JSONEncoder().encode(meta).write(to: file("server.json"))
        issuedThisLaunch = true
    }

    private func loadMeta() -> ServerMeta? {
        guard let data = try? Data(contentsOf: file("server.json")) else { return nil }
        return try? JSONDecoder().decode(ServerMeta.self, from: data)
    }

    // MARK: - Identity

    private static var supportsMemoryOnlyImport: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private func importIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: file("server.p12"))
        var options: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let identityRef = array.first?[kSecImportItemIdentity as String] else {
            throw CertificateError.importFailed(status)
        }
        return identityRef as! SecIdentity
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CertificateError.openssl("\(arguments.first ?? ""): \(String(decoding: errors, as: UTF8.self))")
        }
        return output
    }
}
