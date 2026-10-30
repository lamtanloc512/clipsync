// ClipSync phone client: keeps the phone and Mac clipboards in sync while this page is open.
//
// Browser rules shape what "automatic" can mean:
// - Mac → phone: Chrome/Android may write to the clipboard whenever the page has focus, so new
//   items are copied right away. Safari/iOS only allows it during a tap, so the item waits for
//   the next tap anywhere on the page.
// - Phone → Mac: reading the clipboard needs the "clipboard-read" permission (Chrome/Android:
//   asked once, then checked on open and every couple of seconds while visible). Safari/iOS
//   shows a Paste bubble on every read, so iOS gets a one-tap "Send clipboard" button instead.
// - No web page can run in the background; syncing resumes as soon as the page is opened.
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
    del(k) { try { localStorage.removeItem(k); } catch { /* private mode */ } },
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ---------- Theme (Basecoat's dark variant keys off html.dark) ----------
  const darkQuery = matchMedia('(prefers-color-scheme: dark)');
  const applyTheme = () => document.documentElement.classList.toggle('dark', darkQuery.matches);
  applyTheme();
  darkQuery.addEventListener('change', applyTheme);

  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const guessName = /iPhone/.test(navigator.userAgent) ? 'iPhone'
    : /iPad/.test(navigator.userAgent) ? 'iPad'
    : /Android/.test(navigator.userAgent) ? 'Android phone' : 'Phone';
  const clip = navigator.clipboard;
  const canWrite = !!(window.isSecureContext && clip && clip.writeText);
  const canRead = !!(window.isSecureContext && clip && clip.readText);

  // ---------- State ----------
  let token = store.get('clipsync.deviceToken');
  // One-time pairing secret from the QR code. It is in the #fragment, which is never sent to the
  // server or in Referer headers; remove it from the address bar right away.
  let pairSecret = new URLSearchParams(location.hash.slice(1)).get('k');
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);

  const prefs = {
    autoReceive: store.get('clipsync.autoReceive') !== '0',
    autoSend: store.get('clipsync.autoSend') !== '0',
  };

  let session = 0;          // bumps to stop the running poll loop
  let pollAbort = null;
  let version = -1;         // last server version seen by this page
  let current = null;       // last item received from the server
  let pendingCopy = null;   // Mac item waiting for focus or a tap before it can be copied
  let readPermission = 'unknown';
  let sendTimer = null;
  let sending = false;

  // What both clipboards last agreed on, as a hash so clipboard text is never stored in plain text.
  let lastSyncedHash = store.get('clipsync.lastHash') || '';
  const normalize = (text) => text.replace(/\r\n/g, '\n');
  async function hashText(text) {
    const data = new TextEncoder().encode(normalize(text));
    const digest = await crypto.subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
  }
  function markSynced(hash) {
    lastSyncedHash = hash;
    store.set('clipsync.lastHash', hash);
  }

  // ---------- UI helpers ----------
  function toast(title, category = 'success') {
    const toaster = $('toaster');
    if (toaster && toaster.toast) toaster.toast({ category, title });
  }

  function setStatus(text, variant) {
    const el = $('status');
    el.textContent = text;
    if (variant) el.dataset.variant = variant; else delete el.dataset.variant;
  }

  const authHeaders = (extra = {}) => Object.assign({ 'X-Token': token }, extra);

  // ---------- Pairing ----------
  function showPair(message = '') {
    session++;
    if (pollAbort) pollAbort.abort();
    stopAutoSend();
    $('mainView').hidden = true;
    $('settingsBtn').hidden = true;
    $('pairView').hidden = false;
    $('pairForm').hidden = !pairSecret;
    $('pairScan').hidden = !!pairSecret;
    $('pairWait').hidden = true;
    $('pairMsg').textContent = message;
    $('deviceName').value = store.get('clipsync.deviceName') || guessName;
    setStatus('Not paired', 'outline');
  }

  let pairing = null;
  $('pairForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const name = $('deviceName').value.trim() || guessName;
    store.set('clipsync.deviceName', name);
    $('pairMsg').textContent = '';
    $('pairBtn').disabled = true;
    try {
      const r = await fetch('/api/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, secret: pairSecret }),
      });
      if (r.status === 403) {
        pairSecret = null;
        showPair('This QR code expired or was already used. Scan the new code on your Mac.');
        return;
      }
      if (r.status === 429) throw new Error('Too many pairing requests. Try again in a minute.');
      if (!r.ok) throw new Error(`Pairing failed (${r.status}).`);
      const j = await r.json();
      pairing = j.id;
      $('pairCode').textContent = j.code;
      $('pairForm').hidden = true;
      $('pairWait').hidden = false;
      waitForPairing(j.id);
    } catch (e) {
      $('pairMsg').textContent = e.message || 'Your Mac is not reachable.';
    } finally {
      $('pairBtn').disabled = false;
    }
  });

  $('pairCancel').addEventListener('click', () => { pairing = null; showPair(); });

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
          toast('Paired with your Mac');
          return;
        }
        // The QR secret is single-use, so a new attempt needs a fresh scan.
        if (j.state === 'rejected' || j.state === 'expired') {
          pairing = null;
          pairSecret = null;
          showPair(j.state === 'rejected'
            ? 'Your Mac rejected the request.'
            : 'The request expired. Scan the QR code again.');
          return;
        }
      } catch {
        await sleep(2000);
      }
    }
  }

  // ---------- Main view ----------
  function showMain() {
    $('pairView').hidden = true;
    $('mainView').hidden = false;
    $('settingsBtn').hidden = false;
    $('pairedName').textContent = store.get('clipsync.deviceName') || guessName;
    $('autoReceive').checked = prefs.autoReceive;
    $('autoSend').checked = prefs.autoSend;
    version = -1;
    const mySession = ++session;
    refreshSendMode().then(() => {
      // Phone first: if something new was copied here while ClipSync was closed, send it
      // before applying whatever the Mac has.
      autoSendTick().finally(() => poll(mySession));
    });
  }

  function unpaired(message) {
    token = null;
    store.del('clipsync.deviceToken');
    showPair(message);
  }

  function describe(j) {
    if (!j.kind) return 'Your Mac’s clipboard is empty';
    const when = j.date ? new Date(j.date * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
    const from = j.mine ? 'this phone' : (j.source || 'your Mac');
    return `From ${from}${when ? ` · ${when}` : ''}`;
  }

  let imageURL = null;
  function fetchImage() {
    return fetch('/api/clipboard/image', { headers: authHeaders(), cache: 'no-store' }).then((r) => {
      if (!r.ok) throw new Error(String(r.status));
      return r.blob();
    });
  }

  function render(j) {
    $('latestMeta').textContent = describe(j);
    if (j.kind === 'image') {
      $('latestText').textContent = '';
      fetchImage().then((blob) => {
        if (current !== j) return;
        if (imageURL) URL.revokeObjectURL(imageURL);
        imageURL = URL.createObjectURL(blob);
        $('latestImg').src = imageURL;
        $('latestImg').hidden = false;
      }, () => {});
    } else {
      $('latestImg').hidden = true;
      $('latestText').textContent = j.text || '';
    }
    $('copyBtn').disabled = !j.kind || !canWrite;
  }

  // ---------- Mac → phone ----------
  async function handleRemote(j) {
    current = j;
    render(j);
    if (!j.kind) return;
    const hash = j.kind === 'text' ? await hashText(j.text || '') : `image:${j.epoch}:${j.version}`;
    if (j.mine || hash === lastSyncedHash) {
      markSynced(hash);
      return;
    }
    // Only items that are new since this phone last synced (survives reloads and Mac restarts).
    const stamp = `${j.epoch}:${j.version}`;
    if (store.get('clipsync.lastStamp') === stamp) return;
    store.set('clipsync.lastStamp', stamp);
    if (!prefs.autoReceive) return;
    pendingCopy = { item: j, hash };
    await tryCopyPending();
  }

  async function copyItem(j) {
    if (j.kind === 'image') {
      // Pass a promise so Safari keeps the user gesture while the image downloads.
      await clip.write([new ClipboardItem({ 'image/png': fetchImage() })]);
    } else {
      await clip.writeText(j.text || '');
    }
  }

  async function tryCopyPending() {
    if (!pendingCopy || !canWrite) return;
    if (!document.hasFocus()) {
      showTapToCopy();
      return;
    }
    const { item, hash } = pendingCopy;
    try {
      await copyItem(item);
      pendingCopy = null;
      markSynced(hash);
      $('tapToCopy').hidden = true;
      toast(item.kind === 'image' ? 'Image copied from your Mac' : 'Copied from your Mac');
    } catch {
      showTapToCopy();   // Safari needs a tap; Chrome needs focus
    }
  }

  function showTapToCopy() {
    if (pendingCopy) $('tapToCopy').hidden = false;
  }

  // Any tap counts as the user gesture Safari needs.
  // (This also covers the "tap to copy" button.)
  document.addEventListener('click', () => { if (pendingCopy) tryCopyPending(); }, true);

  $('copyBtn').addEventListener('click', async () => {
    if (!current || !current.kind) return;
    try {
      await copyItem(current);
      if (current.kind === 'text') markSynced(await hashText(current.text || ''));
      toast('Copied');
    } catch {
      toast('Copy failed', 'error');
    }
  });

  async function poll(mySession) {
    while (mySession === session) {
      pollAbort = new AbortController();
      try {
        const r = await fetch(`/api/clipboard?since=${version}&wait=25`, {
          headers: authHeaders(), cache: 'no-store', signal: pollAbort.signal,
        });
        if (mySession !== session) return;
        if (r.status === 401) { unpaired('This phone is no longer paired. Pair it again.'); return; }
        const j = await r.json();
        setStatus('Connected', 'secondary');
        if (j.version !== version) {
          version = j.version;
          await handleRemote(j);
        }
      } catch (e) {
        if (mySession !== session) return;
        if (e.name === 'AbortError') continue;   // page came back to the foreground
        setStatus('Offline', 'destructive');
        await sleep(2000);
      }
    }
  }

  // ---------- Phone → Mac ----------
  async function queryReadPermission() {
    if (!canRead) return 'unsupported';
    try {
      const p = await navigator.permissions.query({ name: 'clipboard-read' });
      p.onchange = () => { readPermission = p.state; refreshSendMode(); };
      return p.state;
    } catch {
      return 'unsupported';   // Safari, Firefox: every read needs a tap
    }
  }

  async function refreshSendMode() {
    readPermission = await queryReadPermission();
    const auto = prefs.autoSend && readPermission === 'granted';
    $('permissionAlert').hidden = !(prefs.autoSend && (readPermission === 'prompt' || readPermission === 'denied'));
    $('permissionText').textContent = readPermission === 'denied'
      ? 'Clipboard access is blocked for this page. Allow it in the browser’s site settings to send automatically.'
      : 'To send automatically, allow ClipSync to see what you copy on this phone.';
    $('grantBtn').hidden = readPermission === 'denied';
    $('sendNowBtn').hidden = !(canRead && (readPermission === 'unsupported' || !prefs.autoSend));
    $('syncHint').textContent = isIOS
      ? 'iPhone only allows clipboard access when you tap: new items from your Mac are copied on your next tap, and “Send clipboard” sends yours.'
      : 'Keep ClipSync open (add it to your home screen): your clipboards stay in sync both ways.';
    if (auto) startAutoSend(); else stopAutoSend();
  }

  function startAutoSend() {
    if (sendTimer) return;
    sendTimer = setInterval(() => { if (document.visibilityState === 'visible') autoSendTick(); }, 2000);
  }

  function stopAutoSend() {
    clearInterval(sendTimer);
    sendTimer = null;
  }

  async function autoSendTick() {
    if (!token || !prefs.autoSend || readPermission !== 'granted' || !document.hasFocus()) return;
    await sendClipboard(false);
  }

  // Reads the phone clipboard and sends it if it differs from what was last synced.
  async function sendClipboard(manual) {
    if (sending) return;
    sending = true;
    try {
      const text = await clip.readText();
      if (!text) { if (manual) toast('Your clipboard is empty', 'info'); return; }
      const hash = await hashText(text);
      if (hash === lastSyncedHash) { if (manual) toast('Already on your Mac', 'info'); return; }
      if (await postClip(text, 'text/plain; charset=utf-8')) {
        markSynced(hash);
        toast('Sent to your Mac');
      }
    } catch {
      if (manual) toast('Could not read the clipboard', 'error');
    } finally {
      sending = false;
    }
  }

  async function postClip(body, type) {
    try {
      const r = await fetch('/api/clipboard', { method: 'POST', headers: authHeaders({ 'Content-Type': type }), body });
      if (r.status === 401) { unpaired('This phone is no longer paired. Pair it again.'); return false; }
      if (r.status === 413) { toast('Too large to send', 'error'); return false; }
      if (!r.ok) throw new Error(String(r.status));
      return true;
    } catch {
      toast('Could not reach your Mac', 'error');
      return false;
    }
  }

  $('sendNowBtn').addEventListener('click', () => sendClipboard(true));
  $('grantBtn').addEventListener('click', async () => {
    try { await clip.readText(); } catch { /* the prompt result arrives via onchange */ }
    await refreshSendMode();
    if (readPermission === 'granted') autoSendTick();
  });

  $('autoReceive').addEventListener('change', (e) => {
    prefs.autoReceive = e.target.checked;
    store.set('clipsync.autoReceive', prefs.autoReceive ? '1' : '0');
    if (!prefs.autoReceive) { pendingCopy = null; $('tapToCopy').hidden = true; }
  });
  $('autoSend').addEventListener('change', (e) => {
    prefs.autoSend = e.target.checked;
    store.set('clipsync.autoSend', prefs.autoSend ? '1' : '0');
    refreshSendMode();
  });

  // Coming back to the page: restart the long poll (it may have been frozen in the background),
  // send anything copied meanwhile, then copy anything new from the Mac.
  function resume() {
    if (!token || $('mainView').hidden) return;
    autoSendTick().finally(() => {
      if (pollAbort) pollAbort.abort();
      tryCopyPending();
    });
  }
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') resume(); });
  window.addEventListener('focus', resume);
  window.addEventListener('pageshow', (e) => { if (e.persisted) resume(); });

  // ---------- Settings ----------
  const settings = $('settings');
  $('settingsBtn').addEventListener('click', () => settings.showModal());
  $('settingsClose').addEventListener('click', () => settings.close());
  settings.addEventListener('click', (e) => { if (e.target === settings) settings.close(); });

  $('manualSend').addEventListener('click', async () => {
    const text = $('manualText').value;
    if (!text) return;
    if (await postClip(text, 'text/plain; charset=utf-8')) {
      markSynced(await hashText(text));
      $('manualText').value = '';
      toast('Sent to your Mac');
    }
  });

  $('photoInput').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    if (await postClip(file, file.type || 'application/octet-stream')) toast('Photo sent to your Mac');
    e.target.value = '';
  });

  $('tokenShow').addEventListener('click', () => {
    const box = $('tokenBox');
    box.hidden = !box.hidden;
    box.textContent = box.hidden ? '' : (token || '');
    $('tokenCopy').hidden = box.hidden;
    $('tokenShow').textContent = box.hidden ? 'Show' : 'Hide';
  });
  $('tokenCopy').addEventListener('click', async () => {
    try { await clip.writeText(token || ''); toast('Token copied'); } catch { toast('Copy failed', 'error'); }
  });

  $('unpairBtn').addEventListener('click', async () => {
    if (!confirm('Unpair this phone from your Mac?')) return;
    try { await fetch('/api/unpair', { method: 'POST', headers: authHeaders() }); } catch { /* offline */ }
    settings.close();
    unpaired('Unpaired. Scan the QR code on your Mac to pair again.');
  });

  if (token) showMain(); else showPair();
})();
