import AppKit
import CoreImage

/// Shows a QR code the phone can scan to open the web client. The URL carries a one-time
/// pairing secret, and the phone still has to be accepted on the Mac.
final class PairingWindowController: NSWindowController, NSWindowDelegate {
    private let imageView = NSImageView()
    private let urlField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString: "")
    private let fingerprintField = NSTextField(wrappingLabelWithString: "")
    private let codeField = NSTextField(labelWithString: "")
    private let switchButton = NSButton(title: "", target: nil, action: nil)
    private var urls: [String] = []
    private var urlIndex = 0

    /// The window closed: the pairing secret in the QR code should stop working.
    var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair a phone"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 280).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 280).isActive = true

        urlField.isSelectable = true
        urlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlField.alignment = .center
        urlField.lineBreakMode = .byCharWrapping
        urlField.maximumNumberOfLines = 3
        urlField.preferredMaxLayoutWidth = 340

        hintField.alignment = .center
        hintField.textColor = .secondaryLabelColor
        hintField.font = .systemFont(ofSize: 12)
        hintField.preferredMaxLayoutWidth = 340
        hintField.stringValue = """
        1. Scan with the phone camera (same Wi‑Fi).
        2. First time only: the browser warns about the certificate → “Show Details” → “visit this website”.
           Safest: do this first pairing on the phone’s own hotspot (connect the Mac to it).
        3. Tap Pair, then Accept here when the codes match.
        Installed ClipSync on an iPhone home screen? Type the code above in the app instead.
        The code works once and expires in 10 minutes or when this window closes.
        Tip: install the certificate from the page’s Settings to remove the warning for good.
        """
        hintField.alignment = .left

        fingerprintField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        fingerprintField.textColor = .secondaryLabelColor
        fingerprintField.alignment = .center
        fingerprintField.isSelectable = true
        fingerprintField.preferredMaxLayoutWidth = 340

        switchButton.target = self
        switchButton.action = #selector(switchHost)
        switchButton.bezelStyle = .inline
        switchButton.font = .systemFont(ofSize: 11)

        codeField.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        codeField.alignment = .center
        codeField.isSelectable = true

        let stack = NSStackView(views: [imageView, urlField, codeField, switchButton, hintField, fingerprintField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `urls[0]` is the .local name, `urls[1]` (if any) the IP fallback.
    /// `code` is the one-time pairing secret, shown for typing into apps that can't scan the QR.
    func show(urls: [String], code: String, caFingerprint: String?) {
        codeField.stringValue = "Code: " + stride(from: 0, to: code.count, by: 4).map { offset -> String in
            let start = code.index(code.startIndex, offsetBy: offset)
            return String(code[start..<(code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex)])
        }.joined(separator: "-")
        let wasVisible = isVisible
        self.urls = urls
        if urlIndex >= urls.count { urlIndex = 0 }
        fingerprintField.stringValue = caFingerprint.map(Self.fingerprintText) ?? ""
        render()
        if !wasVisible { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func render() {
        guard urls.indices.contains(urlIndex) else {
            urlField.stringValue = "No network connection found."
            imageView.image = nil
            switchButton.isHidden = true
            return
        }
        let url = urls[urlIndex]
        imageView.image = Self.qrImage(for: url)
        // Show the address without the secret; it is only in the QR code.
        urlField.stringValue = url.components(separatedBy: "#").first ?? url
        switchButton.isHidden = urls.count < 2
        switchButton.title = urlIndex == 0
            ? "Phone can’t open it? Use the IP address instead"
            : "Use the Mac’s name (.local) instead"
    }

    @objc private func switchHost() {
        urlIndex = (urlIndex + 1) % max(urls.count, 1)
        render()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// Comparing 64 hex digits by eye is unrealistic; the first and last 8 (64 bits) are enough
    /// to detect a swapped certificate, and are what the phone should be checked against.
    static func fingerprintText(_ fingerprint: String) -> String {
        let bytes = fingerprint.split(separator: ":")
        let first = bytes.prefix(4).joined(separator: ":")
        let last = bytes.suffix(4).joined(separator: ":")
        return """
        Certificate check (SHA-256) — on the phone it must start with
        \(first)   and end with   \(last)
        Full: \(fingerprint)
        """
    }

    static func qrImage(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
