import AppKit

/// Floating "Accept / Reject" prompt for incoming pairing requests, shown one at a time.
/// Non-modal on purpose: a modal alert would stall the server running on the main queue.
final class PairRequestWindowController: NSWindowController {
    private var queue: [PairRequest] = []
    private var current: PairRequest?

    private let titleField = NSTextField(labelWithString: "")
    private let codeField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString:
        "Only accept if the same code is shown on your phone.")

    /// (request id, accepted)
    var onDecision: ((String, Bool) -> Void)?

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 250),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Pairing Request"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)

        titleField.font = .boldSystemFont(ofSize: 14)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail

        codeField.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        codeField.alignment = .center

        hintField.font = .systemFont(ofSize: 12)
        hintField.textColor = .secondaryLabelColor
        hintField.alignment = .center
        hintField.preferredMaxLayoutWidth = 300

        let reject = NSButton(title: "Reject", target: self, action: #selector(rejectTapped))
        reject.keyEquivalent = "\u{1b}"
        // Deliberately no Return shortcut: a stray keypress must never approve a device.
        let accept = NSButton(title: "Accept", target: self, action: #selector(acceptTapped))
        let buttons = NSStackView(views: [reject, accept])
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, titleField, codeField, hintField, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        window.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func enqueue(_ request: PairRequest) {
        queue.append(request)
        if current == nil { showNext() }
    }

    /// The request was resolved elsewhere or expired.
    func close(requestID: String) {
        queue.removeAll { $0.id == requestID }
        if current?.id == requestID {
            current = nil
            showNext()
        }
    }

    private func showNext() {
        guard !queue.isEmpty else {
            window?.orderOut(nil)
            return
        }
        let request = queue.removeFirst()
        current = request
        titleField.stringValue = "“\(request.name)” wants to pair"
        codeField.stringValue = request.code
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        NSSound.beep()
    }

    @objc private func acceptTapped() { decide(true) }
    @objc private func rejectTapped() { decide(false) }

    private func decide(_ accepted: Bool) {
        guard let request = current else { return }
        current = nil
        onDecision?(request.id, accepted)  // triggers close(requestID:) via the store, which is a no-op now
        showNext()
    }
}
