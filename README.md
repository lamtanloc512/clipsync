# ClipSync

**English** · [Tiếng Việt](README.vi.md)

Share your clipboard between your Mac and your phone over your local Wi‑Fi, like KDE Connect's clipboard sync, with no app to install on the phone.

- **Mac → phone:** copy something on your Mac and it appears on your phone almost instantly.
- **Phone → Mac:** send text or photos from your phone and paste them on your Mac with ⌘V.
- **Works with Android and iPhone** in the browser, plus optional one-tap iOS Shortcuts / Android HTTP Shortcuts.
- **Private by design:** everything stays on your local network. No account, no cloud, no tracking.
- **Secure pairing:** scan a QR code, confirm a matching code on the Mac, and the connection is encrypted with HTTPS.
- **Lightweight:** a small menu‑bar app with no third‑party dependencies.

## Requirements

- A Mac running **macOS 13 Ventura or later** (Apple Silicon or Intel)
- An Android phone or iPhone with a modern browser
- Both devices on the **same Wi‑Fi network** (or the Mac connected to the phone's hotspot)

## Download and install

1. Download **`ClipSync-macOS.zip`** from the [latest release](https://github.com/lamtanloc512/clipsync/releases/latest).
2. Unzip it and drag **ClipSync.app** into your **Applications** folder.
3. Open it. ClipSync is not notarized by Apple yet, so macOS blocks the first launch:
   - Right‑click **ClipSync.app** → **Open** → **Open**, or
   - Run `xattr -dr com.apple.quarantine /Applications/ClipSync.app` in Terminal.
4. When macOS asks *"Allow incoming network connections?"*, choose **Allow**.

ClipSync appears as a clipboard icon in the menu bar. It has no Dock icon.

> **Optional: check your download.** Each release includes `SHA256SUMS.txt`. Run `shasum -a 256 ClipSync-macOS.zip` and compare the result with the value in that file.

## Pair your phone

1. Click the menu‑bar icon → **Pair a Phone**. A window with a QR code opens.
2. Scan the QR code with your phone's camera.
   - If the page does not open (some Android phones can't open `.local` addresses), click **"Use the IP address instead"** in the QR window and scan again.
3. The first time, the browser warns that the connection is not private. This is expected: your Mac uses its own certificate.
   - Android (Chrome): **Advanced** → **Proceed**
   - iPhone (Safari): **Show Details** → **visit this website** → **Visit Website**
4. Give your phone a name and tap **Pair**. A 4‑digit code appears.
5. Your Mac shows *"… wants to pair"* with a code. If both codes match, click **Accept**.
6. Add the page to your home screen so it opens like an app:
   - Chrome: menu → **Add to Home screen**
   - Safari: **Share** → **Add to Home Screen**

Each QR code works once and expires after 10 minutes. To pair another phone, open **Pair a Phone** again.

### Install the certificate (recommended)

Installing your Mac's certificate on the phone removes the browser warning and is required for Shortcuts / HTTP Shortcuts. On the web page, open **Settings** and follow the steps there.

**Android**
1. Tip: do this while the Mac is connected to your phone's own **hotspot**. Nobody else can interfere with the connection there.
2. Download `ca.crt` from the page's **Settings**.
3. Go to **Settings → Security → Encryption & credentials → Install a certificate → CA certificate**.
4. Check it: **Trusted credentials → User → ClipSync**. Its SHA‑256 fingerprint must **start and end** with the characters shown at the bottom of the QR window on your Mac.

**iPhone / iPad**
1. Easiest and safest: on the Mac, choose **Send Certificate via AirDrop…** from the menu and send it to your iPhone. Or download the profile from the page's **Settings**.
2. Go to **Settings → General → VPN & Device Management → ClipSync → Install**.
3. Go to **Settings → General → About → Certificate Trust Settings** and turn on **ClipSync**.

The certificate only works for local network addresses (`192.168.x.x`, `10.x.x.x`, `*.local`, …). It cannot be used to impersonate real websites.

## Using ClipSync

### On the phone (web page)

- **Mac clipboard:** shows whatever you last copied on the Mac. Tap **Copy to phone** to copy it (text or image).
- **Send to Mac:** type or paste text and tap **Send to Mac**. **Paste & send clipboard** sends your phone's clipboard in one tap, and **Photo** sends a picture.

### On the Mac (menu bar)

| Menu item | What it does |
|---|---|
| **Pair a Phone** | Shows the QR code for pairing |
| **Send Certificate via AirDrop** | Sends the certificate to an iPhone |
| **Paired Devices** | Lists paired phones; choose one → **Unpair** to remove it |
| **Recent** | The last 20 clipboard items; click one to copy it again |
| **Launch at Login** | Starts ClipSync automatically |

### One‑tap shortcuts (optional)

Install the certificate first. Then, on the web page, go to **Settings → Show token** and copy the token. Replace `YOUR-MAC.local` with the address shown in the menu bar.

**iOS Shortcuts: "Send clipboard to Mac"**
1. **Get Clipboard**
2. **Get Contents of URL**
   - URL: `https://YOUR-MAC.local:8765/api/clipboard`
   - Method: **POST**
   - Headers: `X-Token` = *your token*
   - Request Body: **File** → *Clipboard*

**iOS Shortcuts: "Get Mac clipboard"**
1. **Get Contents of URL**: `https://YOUR-MAC.local:8765/api/clipboard/raw`, header `X-Token` = *your token*
2. **Copy to Clipboard**

Tip: assign a shortcut to **Back Tap** (Settings → Accessibility → Touch → Back Tap).

**Android:** create the same requests in [HTTP Shortcuts](https://http-shortcuts.rmy.ch/) or Tasker.

## Troubleshooting

| Problem | Try this |
|---|---|
| The QR link doesn't open | Make sure both devices are on the same Wi‑Fi. Click **"Use the IP address instead"** in the QR window. |
| "Mac not reachable" on the phone | Check that ClipSync is running and the Mac isn't asleep. Some public or guest Wi‑Fi networks block devices from talking to each other; use your phone's hotspot instead. |
| "This QR code expired or was already used" | Open **Pair a Phone** on the Mac again and scan the new code. |
| "This device is no longer paired" | The phone was unpaired on the Mac. Pair it again. |
| The macOS firewall blocks connections | **System Settings → Network → Firewall → Options** → allow ClipSync. |
| Passwords don't show up on the phone | That's intentional. Copies made by password managers are never shared. |

## Security and privacy

- Data never leaves your local network. ClipSync has no servers, no accounts and no analytics.
- Connections use HTTPS with a certificate generated on your Mac. It is restricted to local addresses, so it can't be used to impersonate real websites.
- Pairing requires both the QR code (only visible on your Mac's screen) and a click on **Accept**.
- Each phone gets its own key, which you can revoke at any time from **Paired Devices**.
- **A paired phone can read everything you copy and change your Mac's clipboard.** Only pair your own devices, and unpair a phone if you lose it.

Read the full threat model in [SECURITY.md](SECURITY.md). Found a vulnerability? Please report it privately as described there.

## Build from source

You need Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/lamtanloc512/clipsync.git
cd clipsync
./build-app.sh --install
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture, API and development notes.

## Contributing

Bug reports, ideas and pull requests are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

ClipSync is free software, licensed under the [GNU General Public License v3.0](LICENSE).
