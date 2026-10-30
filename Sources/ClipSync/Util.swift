import Foundation
import Security

/// Timers added in `.common` mode keep firing while menus or windows track events.
@discardableResult
func scheduleTimer(after interval: TimeInterval, repeats: Bool = false, _ block: @escaping (Timer) -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

func randomString(length: Int, alphabet: String = "abcdefghjkmnpqrstuvwxyz23456789") -> String {
    let chars = Array(alphabet)
    var bytes = [UInt8](repeating: 0, count: length)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    // Never fall back to predictable tokens.
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return String(bytes.map { chars[Int($0) % chars.count] })
}

func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

var appSupportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("ClipSync", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return dir
}
