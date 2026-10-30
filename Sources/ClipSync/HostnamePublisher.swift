import Foundation
import dnssd

/// Publishes a neutral multicast-DNS name ("clipsync.local") for this Mac's LAN addresses.
/// Phones reach ClipSync by that name, so the QR code and address bar show neither the IP
/// address nor the Mac's own name (which is often the owner's name).
final class HostnamePublisher {
    private static let defaultsKey = "hostnameLabel"
    private var connection: DNSServiceRef?
    private var published: [(interface: String, address: String)] = []

    /// e.g. "clipsync.local"; becomes "clipsync-xxxx.local" if another device already uses the name.
    private(set) var hostname: String
    /// The name changed after a conflict; the certificate and QR code need the new one.
    var onHostnameChange: ((String) -> Void)?

    init() {
        let label = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "clipsync"
        hostname = label + ".local"
    }

    /// Publishes `hostname` for the given interfaces/addresses, replacing any earlier records.
    func update(addresses: [(interface: String, address: String)]) {
        guard !Self.same(addresses, published) || connection == nil else { return }
        stop()
        published = addresses
        guard !addresses.isEmpty else { return }

        var ref: DNSServiceRef?
        guard DNSServiceCreateConnection(&ref) == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            NSLog("ClipSync: could not connect to mDNSResponder")
            return
        }
        connection = ref
        DNSServiceSetDispatchQueue(ref, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let fullName = hostname + "."

        for (interface, address) in addresses {
            var ipv4 = in_addr()
            guard inet_pton(AF_INET, address, &ipv4) == 1 else { continue }
            let interfaceIndex = if_nametoindex(interface)
            var record: DNSRecordRef?
            let error = withUnsafeBytes(of: &ipv4) { rdata in
                DNSServiceRegisterRecord(
                    ref, &record,
                    DNSServiceFlags(kDNSServiceFlagsUnique),
                    interfaceIndex, fullName,
                    UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                    UInt16(rdata.count), rdata.baseAddress, 120,
                    { _, _, _, error, context in
                        guard let context else { return }
                        Unmanaged<HostnamePublisher>.fromOpaque(context).takeUnretainedValue().handle(error)
                    },
                    context
                )
            }
            if error != DNSServiceErrorType(kDNSServiceErr_NoError) {
                NSLog("ClipSync: registering %@ on %@ failed (%d)", fullName, interface, error)
            }
        }
    }

    func stop() {
        // Deallocating the connection withdraws every record registered on it.
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
        published = []
    }

    private func handle(_ error: DNSServiceErrorType) {
        guard error == DNSServiceErrorType(kDNSServiceErr_NameConflict) else { return }
        // Another device already answers for this name: switch to a stable, unique alternative.
        let label = "clipsync-" + randomString(length: 4)
        UserDefaults.standard.set(label, forKey: Self.defaultsKey)
        hostname = label + ".local"
        NSLog("ClipSync: name conflict, now publishing %@", hostname)
        let addresses = published
        // Don't tear down the connection from inside its own callback.
        scheduleTimer(after: 0) { [weak self] _ in
            guard let self else { return }
            self.stop()
            self.update(addresses: addresses)
            self.onHostnameChange?(self.hostname)
        }
    }

    private static func same(_ a: [(interface: String, address: String)], _ b: [(interface: String, address: String)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.interface == $1.interface && $0.address == $1.address }
    }
}
