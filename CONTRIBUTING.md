# Contributing to ClipSync

Thanks for your interest in ClipSync! Bug reports, ideas, documentation fixes and code are all welcome.

By taking part in this project you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug:** open an issue with your macOS version, phone model and browser, the steps to reproduce, and what you expected to happen.
- **Suggest a feature:** open an issue describing the problem you want solved, not only the solution.
- **Security issues:** please **do not** open a public issue. Follow [SECURITY.md](SECURITY.md).
- **Translations and docs:** improvements to [README.md](README.md) and [README.vi.md](README.vi.md) are very welcome. Please keep both languages in sync.

## Development setup

Requirements: macOS 13+, Xcode 15+ or the Command Line Tools.

```bash
swift build                  # debug build
swift run                    # run from the terminal (logs go to stderr)
./build-app.sh               # release .app bundle (universal), ad-hoc signed
./build-app.sh --install     # ... and copy to /Applications and launch it
```

`swift run` works for most development. Features that need a real app bundle, such as **Launch at Login**, only work with `build-app.sh`.

App data lives in `~/Library/Application Support/ClipSync/`:

| Path | Contents |
|---|---|
| `certs/` | Private CA (`ca.key`, `ca.crt`, `ca.der`) and the server identity (`server.p12`, `server.json`) |
| `devices.json` | Paired devices (names and SHA-256 hashes of their tokens) |

To start from scratch, quit the app and delete that folder. Phones will need to pair again and reinstall the certificate.

Settings (restart the app after changing):

```bash
defaults write com.lamtanloc.clipsync port -int 9000   # default: 8765
```

## Architecture

ClipSync is a single macOS menu-bar app. Phones are plain HTTPS clients: a web page served by the Mac, or Shortcuts/HTTP Shortcuts calling the API. The Mac never connects to the phone.

```
┌──────────────────── Mac (ClipSync.app) ────────────────────┐
│ AppDelegate ─ menu bar, PairingWindow (QR), PairRequestWindow│
│      │                                                     │
│ SyncService ─ routing, admission (Host/Origin/auth), pairing│
│   │     │                                                  │
│   │   HTTPServer ─ HTTPS on Network.framework (NWListener)  │
│   │   CertificateManager ─ private CA + server cert         │
│   │   DeviceStore ─ paired devices, pairing requests        │
│ ClipboardStore ─ watches NSPasteboard, long-poll waiters    │
└─────────────────────────────▲──────────────────────────────┘
                              │ HTTPS on the LAN
        Web client (WebPage.swift) · iOS Shortcuts · HTTP Shortcuts
```

| File | Responsibility |
|---|---|
| `ClipSyncApp.swift` | Entry point; runs as an accessory app (menu bar only) |
| `AppDelegate.swift` | Menu bar UI, history, paired devices, AirDrop, Launch at Login |
| `ClipboardStore.swift` | Polls `NSPasteboard.changeCount` every 0.5 s, keeps history, wakes long-polls |
| `SyncService.swift` | Request admission and routing, pairing endpoints, reissuing the cert when the IP changes |
| `HTTPServer.swift` | Minimal HTTP/1.1 over TLS: one request per connection, peer filtering, limits |
| `CertificateManager.swift` | Name-constrained CA and server certificate via `/usr/bin/openssl`, TLS identity |
| `DeviceStore.swift` | Paired devices (persisted), pairing requests, one-time QR secret |
| `PairingWindow.swift` | QR code window (`.local` URL with IP fallback, CA fingerprint) |
| `PairRequestWindow.swift` | Non-modal Accept/Reject panel |
| `WebPage.swift` | The phone web client (HTML/CSS/JS in one string) |
| `Util.swift` | Common-mode timers, secure random strings, constant-time comparison |

Design notes:

- **Everything runs on the main queue:** the listener, connections, timers and pasteboard access. There are no locks, and clipboard traffic is tiny. Never block the main thread. In particular, use non-modal windows instead of `NSAlert.runModal()` while the server is running.
- **Timers are added in `.common` run-loop mode** (`scheduleTimer`), so they keep firing while menus are open.
- **No third-party dependencies.** Please discuss in an issue before adding one.
- **Mac → phone sync uses long polling:** `GET /api/clipboard?since=<version>&wait=25` returns as soon as the clipboard version changes.

### Pairing flow

1. **Pair a Phone** generates a one-time secret and shows `https://<name>.local:8765/#k=<secret>` as a QR code. The secret is in the URL fragment, so browsers never send it in requests or `Referer` headers.
2. The web client posts `{name, secret}` to `/api/pair`. If the secret is wrong or missing the request is refused (403), and the Mac shows nothing.
3. The Mac shows an Accept/Reject panel with a 4-digit code that the phone also displays.
4. On Accept, the phone receives a 32-character device token via `/api/pair/status` (handed out once). The Mac stores only its SHA-256.
5. The secret is revoked after every decision, after 10 minutes, or when the QR window closes.

## HTTP API

All endpoints are HTTPS on port 8765. Authenticated endpoints need `X-Token: <token>` or `Authorization: Bearer <token>`. Tokens in the URL are not accepted, and there is no CORS.

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/` | – | Web client |
| GET | `/ca.crt`, `/ca.mobileconfig` | – | CA certificate (DER) and iOS configuration profile |
| POST | `/api/pair` | QR secret | `{"name", "secret"}` → `{id, code}` |
| GET | `/api/pair/status?id=&wait=25` | – | `{state: pending/accepted/rejected/expired, token?}` |
| GET | `/api/clipboard?since=N&wait=25` | ✓ | `{version, kind, text, source, date}` (long poll) |
| GET | `/api/clipboard/raw` | ✓ | Current item as `text/plain` or `image/png` |
| GET | `/api/clipboard/image` | ✓ | Current image as PNG |
| POST | `/api/clipboard` | ✓ | Body: text, `{"text": "..."}`, or an image (PNG/JPEG/HEIC) |
| POST | `/api/unpair` | ✓ | Unpairs the calling device |
| GET | `/api/ping` | ✓ | Connectivity check |

Limits: text up to 2 MB, images up to 30 MB and 50 megapixels. Unauthenticated requests may send at most 4 KB of body.

## Testing

There is no unit-test target yet. Contributions are welcome! CI (`.github/workflows/build.yml`) builds a universal binary on macOS and runs a **smoke test** that launches the app and checks:

- HTTPS, the certificate chain and the CA's name constraints
- `401` without a token, and a token in the URL being ignored
- unauthenticated uploads being refused before the body is read
- pairing without the QR secret being refused
- foreign `Origin` and `Host` headers being refused, and no CORS headers
- the iOS profile being a valid plist

Before opening a pull request, please:

1. Build with `swift build` and check there are no new warnings.
2. Run the app and test the flow you changed on a real phone (Android and/or iPhone).
3. If you touch the web client, test it in both Chrome (Android) and Safari (iOS).
4. If you touch networking, pairing or certificates, read [SECURITY.md](SECURITY.md). Extend the smoke test if a new protection can be checked from the command line.

## Coding style

- Follow the existing Swift style: 4-space indentation, `final class` by default, small focused types.
- Comment *why*, not *what*. Security-relevant decisions should say what they protect against.
- Keep user-facing strings short and in English. The web client must keep using `textContent` (never `innerHTML`) for anything that comes from the clipboard or a device.
- Update both README files when you change something users see.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused on one change, and describe what and why.
3. Make sure CI is green.
4. By submitting a pull request you agree that your contribution is licensed under the [GPL-3.0](LICENSE), like the rest of the project.

## Releasing (maintainers)

Either run the workflow from GitHub: **Actions → Build → Run workflow**, choose `main`, and enter the version (e.g. `1.2.0`). The tag `v1.2.0` is created for you.

Or push a tag that starts with `v`:

```bash
git tag v1.2.0
git push origin v1.2.0
```

The workflow builds the app with `CFBundleShortVersionString` set from the tag, runs the smoke test, and a separate job publishes a GitHub Release with `ClipSync-macOS.zip` and `SHA256SUMS.txt`. Only that tag-triggered job has write access to the repository.

Do not create the release manually in the GitHub UI first: the workflow creates it.
