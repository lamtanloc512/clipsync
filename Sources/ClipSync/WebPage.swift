enum WebPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#111827">
<title>ClipSync</title>
<style>
  :root {
    --bg: #f3f4f6; --card: #ffffff; --text: #111827; --muted: #6b7280;
    --border: #e5e7eb; --accent: #2563eb; --ok: #16a34a; --bad: #dc2626;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #0b0f17; --card: #161b26; --text: #e5e7eb; --muted: #9ca3af; --border: #263041; --accent: #3b82f6; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; font: 16px/1.45 -apple-system, system-ui, sans-serif; background: var(--bg); color: var(--text);
         padding: max(16px, env(safe-area-inset-top)) 16px 32px; }
  header { display: flex; align-items: center; gap: 10px; margin: 4px 0 16px; }
  h1 { font-size: 22px; margin: 0; flex: 1; }
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 0 0 8px; }
  h3 { font-size: 15px; margin: 16px 0 6px; }
  p, li { color: var(--muted); font-size: 14px; }
  ol { padding-left: 20px; margin: 6px 0; }
  a { color: var(--accent); }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--muted); }
  .dot.ok { background: var(--ok); } .dot.bad { background: var(--bad); }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 14px; margin-bottom: 14px; }
  #incoming { white-space: pre-wrap; word-break: break-word; margin: 0 0 10px; max-height: 40vh; overflow: auto;
              font: 15px/1.4 ui-monospace, Menlo, monospace; min-height: 1.4em; }
  #incomingImg { max-width: 100%; border-radius: 8px; margin-bottom: 10px; }
  .meta { font-size: 12px; color: var(--muted); margin-bottom: 8px; }
  textarea, input[type=text] { width: 100%; border: 1px solid var(--border); border-radius: 10px;
             padding: 10px; font: inherit; background: transparent; color: inherit; }
  textarea { min-height: 120px; resize: vertical; }
  .row { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
  button, .file, .btn { appearance: none; border: 1px solid var(--border); background: transparent; color: inherit;
                  border-radius: 10px; padding: 10px 14px; font: inherit; font-weight: 600; cursor: pointer;
                  text-decoration: none; display: inline-block; text-align: center; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #fff; flex: 1; }
  button.danger { color: var(--bad); }
  button:disabled { opacity: .5; }
  .file input { display: none; }
  .code { font: 600 44px/1.1 ui-monospace, Menlo, monospace; letter-spacing: .15em; text-align: center; margin: 12px 0; }
  .token { font: 13px ui-monospace, Menlo, monospace; word-break: break-all; padding: 8px; border: 1px dashed var(--border); border-radius: 8px; }
  summary { font-weight: 600; cursor: pointer; }
  [hidden] { display: none !important; }
  #toast { position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%); background: #111827; color: #fff;
           padding: 10px 16px; border-radius: 999px; font-size: 14px; opacity: 0; transition: opacity .2s; pointer-events: none; }
  #toast.show { opacity: .92; }
</style>
</head>
<body>
<header>
  <h1>ClipSync</h1>
  <span id="status" class="dot" title="connection"></span>
</header>

<!-- Pairing -->
<section id="pairView" class="card" hidden>
  <h2>Pair with your Mac</h2>
  <p id="pairScan" hidden>Open <b>Pair a Phone</b> from the ClipSync menu on your Mac and scan the QR code with this phone’s camera.</p>
  <div id="pairForm">
    <p>Name this device, tap Pair, then accept the request on your Mac.</p>
    <input type="text" id="deviceName" maxlength="40" autocomplete="off">
    <div class="row"><button id="pairBtn" class="primary">Pair</button></div>
  </div>
  <div id="pairWait" hidden>
    <p>Check that your Mac shows the same code, then click <b>Accept</b> there.</p>
    <div class="code" id="pairCode"></div>
    <div class="row"><button id="pairCancel">Cancel</button></div>
  </div>
  <p id="pairMsg" class="meta"></p>
</section>

<!-- Main -->
<div id="mainView" hidden>
  <section class="card">
    <h2>Mac clipboard</h2>
    <div id="meta" class="meta">Connecting…</div>
    <pre id="incoming"></pre>
    <img id="incomingImg" alt="" hidden>
    <div class="row">
      <button id="copyBtn" class="primary">Copy to phone</button>
    </div>
  </section>

  <section class="card">
    <h2>Send to Mac</h2>
    <textarea id="out" placeholder="Type or paste here…"></textarea>
    <div class="row">
      <button id="pasteBtn" hidden>Paste</button>
      <label class="file">Photo<input type="file" id="file" accept="image/*"></label>
      <button id="sendBtn" class="primary">Send to Mac</button>
    </div>
    <div class="row">
      <button id="pasteSendBtn" class="primary" hidden>Paste &amp; send clipboard</button>
    </div>
  </section>

  <details class="card">
    <summary>Settings</summary>

    <h3>Paired as <span id="pairedName"></span></h3>
    <div class="row"><button id="unpairBtn" class="danger">Unpair this device</button></div>

    <h3>Trust the certificate (recommended)</h3>
    <p>Removes the browser warning and lets Shortcuts / HTTP Shortcuts connect. The certificate only works for local network addresses.</p>
    <p><b>Check it is really your Mac’s certificate:</b> its SHA‑256 fingerprint must start and end with the characters shown at the bottom of the QR window on your Mac. Safest of all: install it while the Mac is connected to this phone’s own hotspot, where nobody else can interfere.</p>
    <p><b>iPhone / iPad</b></p>
    <ol>
      <li>Best: on the Mac choose <b>Send Certificate via AirDrop</b>. Or <a href="/ca.mobileconfig">download the profile</a> → Allow.</li>
      <li>Settings → General → VPN &amp; Device Management → ClipSync → Install.</li>
      <li>Settings → General → About → Certificate Trust Settings → turn on ClipSync.</li>
    </ol>
    <p><b>Android</b></p>
    <ol>
      <li><a href="/ca.crt">Download the certificate</a>.</li>
      <li>Settings → Security → Encryption &amp; credentials → Install a certificate → CA certificate.</li>
      <li>Check: Encryption &amp; credentials → Trusted credentials → <b>User</b> → ClipSync → compare the SHA‑256 fingerprint with the Mac. If it does not match, remove it.</li>
    </ol>

    <h3>Token for Shortcuts</h3>
    <p>Use as header <code>X-Token</code> in iOS Shortcuts or HTTP Shortcuts. Keep it private.</p>
    <div class="row"><button id="tokenBtn">Show token</button><button id="tokenCopyBtn" hidden>Copy</button></div>
    <div id="tokenBox" class="token" hidden></div>
  </details>
</div>

<div id="toast"></div>

<script>
(() => {
  const $ = (id) => document.getElementById(id);
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
    del(k) { try { localStorage.removeItem(k); } catch (e) {} },
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const guessName = /iPhone/.test(navigator.userAgent) ? 'iPhone'
                  : /iPad/.test(navigator.userAgent) ? 'iPad'
                  : /Android/.test(navigator.userAgent) ? 'Android phone' : 'Phone';

  let token = store.get('clipsync.deviceToken');
  // One-time pairing secret from the QR code. It lives in the #fragment, which is never sent
  // to the server or in Referer headers; drop it from the address bar right away.
  let pairSecret = new URLSearchParams(location.hash.slice(1)).get('k');
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  let session = 0;           // bumps to stop the running poll loop
  let version = -1;
  let current = null;
  const canReadClipboard = window.isSecureContext && navigator.clipboard && navigator.clipboard.readText;

  let toastTimer;
  function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 1800);
  }
  const setStatus = (s) => { $('status').className = 'dot ' + s; };
  const authHeaders = (extra = {}) => Object.assign({ 'X-Token': token }, extra);

  // ---------- Pairing ----------

  function showPair(message = '') {
    session++;
    $('mainView').hidden = true;
    $('pairView').hidden = false;
    $('pairForm').hidden = !pairSecret;
    $('pairScan').hidden = !!pairSecret;
    $('pairWait').hidden = true;
    $('pairMsg').textContent = message;
    $('deviceName').value = store.get('clipsync.deviceName') || guessName;
    setStatus('');
  }

  let pairing = null;
  $('pairBtn').onclick = async () => {
    const name = $('deviceName').value.trim() || guessName;
    store.set('clipsync.deviceName', name);
    $('pairMsg').textContent = '';
    $('pairBtn').disabled = true;
    try {
      const r = await fetch('/api/pair', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name, secret: pairSecret }),
      });
      if (r.status === 403) {
        pairSecret = null;
        showPair('This QR code expired or was already used. Scan the new code on your Mac.');
        return;
      }
      if (r.status === 429) throw new Error('Too many pairing requests, try again in a minute.');
      if (!r.ok) throw new Error('Pairing failed (' + r.status + ')');
      const j = await r.json();
      pairing = j.id;
      $('pairCode').textContent = j.code;
      $('pairForm').hidden = true;
      $('pairWait').hidden = false;
      waitForPairing(j.id);
    } catch (e) {
      $('pairMsg').textContent = e.message || 'Mac not reachable.';
    } finally {
      $('pairBtn').disabled = false;
    }
  };

  $('pairCancel').onclick = () => { pairing = null; showPair(); };

  async function waitForPairing(id) {
    while (pairing === id) {
      try {
        const r = await fetch(`/api/pair/status?id=${encodeURIComponent(id)}&wait=25`, { cache: 'no-store' });
        const j = await r.json();
        if (pairing !== id) return;
        if (j.state === 'accepted' && j.token) {
          token = j.token;
          store.set('clipsync.deviceToken', token);
          pairing = null;
          pairSecret = null;
          showMain();
          toast('Paired ✓');
          return;
        }
        // The QR secret is single-use, so a new attempt needs a fresh scan.
        if (j.state === 'rejected') { pairing = null; pairSecret = null; showPair('The Mac rejected the request.'); return; }
        if (j.state === 'expired') { pairing = null; pairSecret = null; showPair('The request expired. Scan the QR code again.'); return; }
      } catch (e) {
        await sleep(2000);
      }
    }
  }

  // ---------- Main ----------

  function showMain() {
    $('pairView').hidden = true;
    $('mainView').hidden = false;
    $('pairedName').textContent = store.get('clipsync.deviceName') || guessName;
    $('pasteBtn').hidden = !canReadClipboard;
    $('pasteSendBtn').hidden = !canReadClipboard;
    $('tokenBox').hidden = true;
    $('tokenCopyBtn').hidden = true;
    $('tokenBtn').textContent = 'Show token';
    version = -1;
    loop(++session);
  }

  function unpaired(message) {
    token = null;
    store.del('clipsync.deviceToken');
    showPair(message);
  }

  // Images are fetched with the token in a header (never in the URL) and shown as blob: URLs.
  let imageBlobURL = null;
  function fetchImage() {
    return fetch('/api/clipboard/image', { headers: authHeaders(), cache: 'no-store' }).then((r) => {
      if (!r.ok) throw new Error(r.status);
      return r.blob();
    });
  }

  function render(j) {
    current = j;
    const when = j.date ? new Date(j.date * 1000).toLocaleTimeString() : '';
    $('meta').textContent = j.kind ? `From ${j.source || 'Mac'} · ${when}` : 'Clipboard is empty';
    if (j.kind === 'image') {
      $('incoming').textContent = '';
      fetchImage().then((blob) => {
        if (current !== j) return;
        if (imageBlobURL) URL.revokeObjectURL(imageBlobURL);
        imageBlobURL = URL.createObjectURL(blob);
        $('incomingImg').src = imageBlobURL;
        $('incomingImg').hidden = false;
      }, () => {});
      const canCopyImage = window.isSecureContext && window.ClipboardItem && navigator.clipboard && navigator.clipboard.write;
      $('copyBtn').textContent = canCopyImage ? 'Copy image to phone' : 'Long‑press image to save/copy';
      $('copyBtn').disabled = !canCopyImage;
    } else {
      $('incomingImg').hidden = true;
      $('incoming').textContent = j.text || '';
      $('copyBtn').textContent = 'Copy to phone';
      $('copyBtn').disabled = !j.text;
    }
  }

  async function loop(mySession) {
    while (mySession === session) {
      try {
        const r = await fetch(`/api/clipboard?since=${version}&wait=25`, { headers: authHeaders(), cache: 'no-store' });
        if (mySession !== session) return;
        if (r.status === 401) { unpaired('This device is no longer paired. Pair again.'); return; }
        const j = await r.json();
        setStatus('ok');
        if (j.version !== version) { version = j.version; render(j); }
      } catch (e) {
        if (mySession !== session) return;
        setStatus('bad');
        $('meta').textContent = 'Mac not reachable, retrying…';
        await sleep(2000);
      }
    }
  }

  function copyText(text) {
    if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    ta.setSelectionRange(0, text.length);
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return ok ? Promise.resolve() : Promise.reject(new Error('copy failed'));
  }

  $('copyBtn').onclick = async () => {
    if (!current) return;
    try {
      if (current.kind === 'image') {
        // Pass a promise so Safari keeps the user gesture while the image downloads.
        const blob = fetchImage();
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
      } else if (current.text) {
        await copyText(current.text);
      }
      toast('Copied ✓');
    } catch (e) {
      toast('Copy failed');
    }
  };

  $('pasteBtn').onclick = async () => {
    try { $('out').value = await navigator.clipboard.readText(); } catch (e) { toast('Paste not allowed'); }
  };

  async function post(body, type) {
    try {
      const r = await fetch('/api/clipboard', { method: 'POST', headers: authHeaders({ 'Content-Type': type }), body });
      if (r.status === 401) { unpaired('This device is no longer paired. Pair again.'); return false; }
      if (!r.ok) throw new Error(r.status);
      toast('Sent to Mac ✓');
      return true;
    } catch (e) {
      toast('Send failed');
      return false;
    }
  }

  $('sendBtn').onclick = async () => {
    const text = $('out').value;
    if (!text) { toast('Nothing to send'); return; }
    if (await post(text, 'text/plain; charset=utf-8')) $('out').value = '';
  };

  $('pasteSendBtn').onclick = async () => {
    try {
      const text = await navigator.clipboard.readText();
      if (!text) { toast('Clipboard is empty'); return; }
      await post(text, 'text/plain; charset=utf-8');
    } catch (e) {
      toast('Paste not allowed');
    }
  };

  $('file').onchange = async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    await post(f, f.type || 'application/octet-stream');
    e.target.value = '';
  };

  $('unpairBtn').onclick = async () => {
    if (!confirm('Unpair this device from the Mac?')) return;
    try { await fetch('/api/unpair', { method: 'POST', headers: authHeaders() }); } catch (e) {}
    unpaired('Unpaired.');
  };

  $('tokenBtn').onclick = () => {
    const box = $('tokenBox');
    box.hidden = !box.hidden;
    box.textContent = token || '';
    $('tokenCopyBtn').hidden = box.hidden;
    $('tokenBtn').textContent = box.hidden ? 'Show token' : 'Hide token';
  };
  $('tokenCopyBtn').onclick = () => copyText(token || '').then(() => toast('Token copied'), () => toast('Copy failed'));

  if (token) showMain(); else showPair();
})();
</script>
</body>
</html>
"""#
}
