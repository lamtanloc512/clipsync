import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let service = SyncService()
    private var statusItem: NSStatusItem!
    private var pairingWindow: PairingWindowController?
    private lazy var pairRequestWindow = PairRequestWindowController()
    private var serverState = "starting…"
    private var flashTask: Task<Void, Never>?

    private static let idleSymbol = "doc.on.clipboard"
    private static let receivedSymbol = "checkmark.circle.fill"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(Self.idleSymbol)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        service.onServerState = { [weak self] state in
            NSLog("ClipSync server: %@", state)
            self?.serverState = state
        }
        service.onFileReceived = { [weak self] url, device in
            self?.notifyFileReceived(url, from: device)
        }
        if Self.canNotify { UNUserNotificationCenter.current().delegate = self }
        service.onReceive = { [weak self] _ in
            self?.flashReceived()
        }
        service.devices.onPairRequest = { [weak self] request in
            self?.pairRequestWindow.enqueue(request)
        }
        service.devices.onPairRequestClosed = { [weak self] id in
            self?.pairRequestWindow.close(requestID: id)
        }
        pairRequestWindow.onDecision = { [weak self] id, accepted in
            self?.service.devices.resolve(id: id, accept: accepted)
        }
        service.hostnamePublisher.onHostnameChange = { [weak self] _ in
            // New name after an mDNS conflict: reissue the certificate and refresh an open QR code.
            guard let self else { return }
            self.service.checkAddresses()
            if self.pairingWindow?.isVisible == true { self.showPairing() }
        }
        service.devices.onPairingSecretInvalidated = { [weak self] in
            // Keep an open QR window usable with a fresh code.
            guard let self, self.pairingWindow?.isVisible == true else { return }
            self.showPairing()
        }

        do {
            try service.start()
        } catch {
            serverState = "failed: \(error.localizedDescription)"
            NSLog("ClipSync failed to start: %@", String(describing: error))
        }

        // First launch: show the QR code right away.
        if !UserDefaults.standard.bool(forKey: "didShowPairing") {
            UserDefaults.standard.set(true, forKey: "didShowPairing")
            showPairing()
        }
    }

    // MARK: - Menu (rebuilt every time it opens so addresses/history are fresh)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "ClipSync — \(serverState == "ready" ? "running" : serverState)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Only the neutral name; the IP stays out of sight (it is just the QR window's fallback).
        let addressTitle = SyncService.localIPv4Addresses().isEmpty
            ? "No network"
            : "\(service.hostname) — port \(service.port)"
        let addressItem = NSMenuItem(title: addressTitle, action: nil, keyEquivalent: "")
        addressItem.isEnabled = false
        menu.addItem(addressItem)

        menu.addItem(.separator())
        menu.addItem(item("Pair a Phone (QR code)…", #selector(showPairing), key: "p"))
        menu.addItem(item("Send File to Phones…", #selector(sendFileToPhones), key: "o"))
        menu.addItem(item("Send Certificate via AirDrop…", #selector(airDropCertificate)))

        let devicesItem = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
        let devicesMenu = NSMenu()
        if service.devices.devices.isEmpty {
            let empty = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            devicesMenu.addItem(empty)
        } else {
            let formatter = RelativeDateTimeFormatter()
            for device in service.devices.devices {
                let seen = service.devices.lastSeen[device.id]
                    .map { "active " + formatter.localizedString(for: $0, relativeTo: Date()) } ?? "not seen since launch"
                let entry = NSMenuItem(title: "📱  \(device.name) — \(seen)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let unpair = item("Unpair", #selector(unpairDevice(_:)))
                unpair.representedObject = device.id
                sub.addItem(unpair)
                entry.submenu = sub
                devicesMenu.addItem(entry)
            }
        }
        devicesItem.submenu = devicesMenu
        menu.addItem(devicesItem)

        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        if service.store.history.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for (index, clip) in service.store.history.enumerated() {
                let entry = item("\(clip.source == "Mac" ? "💻" : "📱")  \(clip.preview)", #selector(restoreHistory(_:)))
                entry.tag = index
                entry.toolTip = clip.text.map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 }
                historyMenu.addItem(entry)
            }
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit ClipSync", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func showPairing() {
        if pairingWindow == nil {
            let controller = PairingWindowController()
            controller.onClose = { [weak self] in self?.service.devices.revokePairingSecret() }
            pairingWindow = controller
        }
        let secret = service.devices.issuePairingSecret()
        pairingWindow?.show(urls: service.pairingURLs(secret: secret), code: secret,
                            caFingerprint: service.certificates.caFingerprint)
    }

    /// AirDrop is an out-of-band channel: unlike downloading over Wi‑Fi, an attacker on the
    /// network cannot swap in their own certificate on the way to the phone.
    /// Puts the chosen file on the clipboard; phones show it with a Download button.
    /// (Copying a file in Finder with ⌘C does the same.)
    @objc private func sendFileToPhones() {
        let panel = NSOpenPanel()
        panel.title = "Send a File to Your Phones"
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !service.store.setFile(url, source: "Mac") {
            let alert = NSAlert()
            alert.messageText = "Could not send “\(url.lastPathComponent)”"
            alert.informativeText = "Only regular files can be sent."
            alert.runModal()
        }
    }

    // MARK: - Notifications

    /// UNUserNotificationCenter needs a real app bundle (it crashes under `swift run`).
    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func notifyFileReceived(_ url: URL, from device: String) {
        flashReceived()
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "File from \(device)"
            content.body = "\(url.lastPathComponent) is in Downloads and on the clipboard."
            content.userInfo = ["path": url.path]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Clicking the notification shows the file in Finder.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    /// Show notifications even while ClipSync is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func airDropCertificate() {
        guard let profile = service.certificates.mobileConfig(name: service.hostname) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipSync.mobileconfig")
        do {
            try profile.write(to: url, options: .atomic)
        } catch {
            NSLog("ClipSync: could not write profile: %@", String(describing: error))
            return
        }
        guard let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [url]) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        airDrop.perform(withItems: [url])
    }

    @objc private func unpairDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        service.devices.unpair(id: id)
    }

    @objc private func restoreHistory(_ sender: NSMenuItem) {
        let history = service.store.history
        guard history.indices.contains(sender.tag) else { return }
        service.store.restore(history[sender.tag])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure ClipSync.app is in /Applications (built with build-app.sh)."
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Icon

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClipSync")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func flashReceived() {
        setIcon(Self.receivedSymbol)
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.setIcon(Self.idleSymbol)
        }
    }
}
