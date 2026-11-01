# Security Policy

ClipSync handles your clipboard, which often contains private information. Security reports are taken seriously.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report vulnerabilities privately through GitHub: go to the repository's **Security** tab → **Report a vulnerability** ([direct link](https://github.com/lamtanloc512/clipsync/security/advisories/new)). Please include:

- the affected version (the release tag, or Finder → Get Info on ClipSync.app)
- what an attacker needs, such as being on the same Wi‑Fi, a paired device, or local access to the Mac
- steps to reproduce or a proof of concept
- the impact you observed

You should get an acknowledgement within a week. Please give a reasonable amount of time to fix the issue before disclosing it publicly. Reporters are credited in the release notes unless they prefer otherwise.

## Supported versions

Only the [latest release](https://github.com/lamtanloc512/clipsync/releases/latest) receives security fixes.

## Threat model

ClipSync runs an HTTPS server on your Mac that phones on the same local network connect to.

| Threat | Mitigation |
|---|---|
| Eavesdropping on the Wi‑Fi | TLS 1.2+ with a server certificate signed by a per-Mac private CA |
| Someone on the network spamming pairing prompts | Pairing requires a one-time secret that is only shown in the QR code on the Mac's screen |
| A malicious website pairing itself or reading the clipboard (CSRF/CORS) | No CORS headers. A strict Content-Security-Policy (`script-src 'self'`, no inline scripts). Requests with a foreign `Origin` are refused. Pairing needs the QR secret, which websites cannot know |
| Revealing the Mac's identity | Phones use the neutral mDNS name `clipsync.local`. The server certificate, the public CA (`/ca.crt`) and the iOS profile carry no Mac or owner name |
| DNS rebinding | The `Host` header must be one of the Mac's own names or addresses. TLS also checks the name |
| Access from the internet (global IPv6, VPN peers) | Connections are only accepted from private, link-local, ULA, CGNAT and loopback addresses |
| Accidentally approving a stranger | The same 4-digit code is shown on both screens. **Accept** requires a click and has no keyboard shortcut |
| Leaked CA key | The CA has name constraints (private IPs, `*.local`, `localhost` only), an EKU limited to `serverAuth`, and no email/URI names. It cannot impersonate public websites |
| Leaked token | Each device has its own 32-character token. Only its SHA-256 is stored, tokens are accepted in headers only (not URLs), and devices can be unpaired individually |
| Denial of service | At most 64 connections, a 20 s request deadline, and no request body before authentication (4 KB limit) |
| Service worker (installed app) | Caches only the CSS, JS and icons; pages, `/api/*` and downloads always go to the Mac, so the browser's certificate check and warning always apply. Shared items wait in a local cache only until the app sends them |
| Notifications (Web Push, optional) | The Mac sends them itself (no ClipSync server), encrypted end-to-end per RFC 8291 and signed with its own VAPID key. By default they contain no clipboard content — only the kind of item; the phone fetches the item from the Mac over the local network. Push endpoints are restricted to Google, Apple and Mozilla push services (https), so a paired device can't make the Mac send requests elsewhere |
| Files sent by a paired device | Streamed to disk (never into memory) up to a size cap and only with enough free space; names are stripped of paths, control characters and leading dots and never overwrite existing files; files get the `com.apple.quarantine` attribute so Gatekeeper treats them as downloads |
| File downloads | Only files that are currently on the clipboard/history can be downloaded, by item id; download links carry a random, 10-minute ticket instead of the device token |
| Malicious images from a paired device | Only PNG/JPEG/HEIC are accepted. The pixel count (≤ 50 MP) is checked before decoding. Text is limited to 2 MB |
| Passwords leaking to the phone | Pasteboard items marked as concealed or transient (nspasteboard.org markers, 1Password, …) are never shared |
| Tampered builds | CI is read-only except the tag-triggered release job. Releases include `SHA256SUMS.txt` |

## Known limitations

These are inherent to the current design. Please keep them in mind:

- **First connection before the certificate is installed (trust on first use).** Until the phone trusts the Mac's CA, the browser cannot verify the server. An attacker who is *actively* intercepting traffic on the same network (for example by ARP spoofing) at that moment could serve a fake page, steal the pairing secret or offer a fake certificate. A web page cannot verify the certificate itself, because the attacker would also control its JavaScript. Mitigations:
  - Do the first pairing on a network nobody else can interfere with, such as the phone's own hotspot or your home Wi‑Fi.
  - On iPhone, install the certificate via AirDrop.
  - Compare the certificate fingerprint on the phone with the one shown in the Mac's QR window. Checking the first and last 8 hex digits (64 bits) is enough.
- **Automatic sending from the phone.** With auto-send on, whatever is copied on the phone while ClipSync is open — including passwords from a password manager — is sent to the Mac. Browsers don't expose "sensitive" clipboard flags, so ClipSync can't filter these on the phone side.
- **mDNS name.** Anyone on the network can also announce `clipsync.local`. If another device takes the name first, ClipSync switches to `clipsync-xxxx.local`. A device that answers for the name can't impersonate the Mac, because it has no certificate signed by your Mac's CA — but on a first connection without the CA installed (see above) the phone can't tell the difference.
- **Files on the clipboard are shared.** A file you copy in Finder can be downloaded by any paired phone while it is in ClipSync's clipboard history (last 20 items). Download links work for 10 minutes for anyone who has the link.
- **Notifications leave the local network.** With notifications on, the push service (Google or Apple) learns that something was copied and when, and both devices need Internet. With "Show what was copied" on, a short preview travels end-to-end encrypted. Leave notifications off to keep everything local.
- **Paired devices are fully trusted.** A paired device can read everything you copy and can overwrite the Mac's clipboard. Only pair your own devices and unpair lost ones.
- **Key material on disk.** The CA key and TLS identity are stored in `~/Library/Application Support/ClipSync/certs` with mode `0600`. Malware running as your user could read them, but the name constraints limit their use to local-network names.
- **macOS 11–14.** The TLS identity has to go through the login keychain, so a new server key is created at every launch and older entries stay in the keychain. On macOS 15+ the identity stays in memory only.
- **Distribution.** Releases are signed with Developer ID and notarized by Apple when the maintainer's signing secrets are configured; otherwise they are ad-hoc signed. Either way, verify `SHA256SUMS.txt` or build from source.
