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
  // Opened from a notification: the normal start-up copies the newest Mac item.
  if (new URLSearchParams(location.search).get('from') === 'notification') history.replaceState(null, '', '/');

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
    $('codeForm').hidden = !!pairSecret;
    $('pairWait').hidden = true;
    $('pairMsg').textContent = message;
    $('deviceName').value = store.get('clipsync.deviceName') || guessName;
    setStatus('Not paired', 'outline');
  }

  function unreachableMessage() {
    const base = 'Can’t reach your Mac. Check that ClipSync is running on it and that both are on the same Wi‑Fi.';
    return isIOS
      ? `${base} If they are, this device doesn’t trust your Mac’s certificate yet: in the ClipSync menu on the Mac, choose Send Certificate via AirDrop…, install it in Settings → General → VPN & Device Management, then turn on ClipSync in Settings → General → About → Certificate Trust Settings.`
      : base;
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
      // fetch() rejects with a bare TypeError ("Load failed" on iOS) for both network and
      // certificate failures, and a request from the page gets no warning to click through.
      $('pairMsg').textContent = e instanceof TypeError ? unreachableMessage() : e.message;
    } finally {
      $('pairBtn').disabled = false;
    }
  });

  $('pairCancel').addEventListener('click', () => { pairing = null; showPair(); });

  // Typing the code instead of scanning: needed for an iPhone home-screen app, which can't
  // receive the QR link (it opens Safari, whose storage is separate).
  $('codeForm').addEventListener('submit', (event) => {
    event.preventDefault();
    const code = $('codeInput').value.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (!code) return;
    pairSecret = code;
    $('codeInput').value = '';
    showPair();
  });

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
    takeShared();
    reportPresence(document.visibilityState === 'visible');
    refreshPushState();
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

  function formatSize(bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let n = bytes, i = 0;
    while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
    return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${units[i]}`;
  }

  function render(j) {
    $('latestMeta').textContent = describe(j);
    const isFile = j.kind === 'file';
    $('latestFile').hidden = !isFile;
    $('downloadBtn').hidden = !isFile;
    $('copyBtn').hidden = isFile;
    if (isFile) {
      $('latestText').textContent = '';
      $('latestImg').hidden = true;
      $('fileName').textContent = j.text || 'File';
      $('fileSize').textContent = formatSize(j.size || 0);
    } else if (j.kind === 'image') {
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
    if (j.kind === 'file') {
      // Files can't go on a phone clipboard from a web page; offer the download instead.
      const stamp = `${j.epoch}:${j.version}`;
      if (!j.mine && store.get('clipsync.lastStamp') !== stamp) toast('File from your Mac — tap Download', 'info');
      store.set('clipsync.lastStamp', stamp);
      return;
    }
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
      // In the background the browser freezes the page anyway; stop polling so the Mac knows to
      // send a notification instead, and pick up again when the page is visible.
      while (document.visibilityState === 'hidden' && mySession === session) await sleep(1000);
      if (mySession !== session) return;
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
  document.addEventListener('visibilitychange', () => {
    const visible = document.visibilityState === 'visible';
    reportPresence(visible);
    if (visible) resume(); else if (pollAbort) pollAbort.abort();
  });

  // Tells the Mac whether this page is on screen: while it is, the long poll keeps it in sync;
  // once it isn't, the Mac sends a push notification instead (if enabled). keepalive lets the
  // request finish while the page is being hidden.
  function reportPresence(visible) {
    if (!token) return;
    fetch('/api/presence', {
      method: 'POST', keepalive: true,
      headers: authHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ visible }),
    }).catch(() => {});
  }

  // ---------- Notifications while ClipSync is closed (Web Push) ----------
  // The Mac encrypts and sends them itself through the browser's push service (Google/Apple);
  // by default they carry no clipboard content — tapping one opens ClipSync, which fetches the
  // item from the Mac over the local network.
  const pushSupported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

  function setPushHint(text) { $('pushHint').textContent = text; }

  function urlBase64ToUint8Array(value) {
    const base64 = (value + '='.repeat((4 - (value.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/');
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  }

  async function pushRegistration() {
    // Service workers only run once the Mac's certificate is trusted.
    return Promise.race([navigator.serviceWorker.ready, sleep(3000).then(() => null)]);
  }

  async function refreshPushState() {
    $('pushToggle').checked = store.get('clipsync.push') === '1';
    $('pushPreview').checked = store.get('clipsync.pushPreview') === '1';
    $('pushPreviewRow').hidden = !$('pushToggle').checked;
    if (!pushSupported) {
      $('pushToggle').disabled = true;
      setPushHint(isIOS && !standalone
        ? 'On iPhone, add ClipSync to your Home Screen to get notifications.'
        : 'This browser can’t show notifications for ClipSync.');
      return;
    }
    setPushHint(Notification.permission === 'denied'
      ? 'Notifications are blocked for ClipSync. Allow them in the browser’s site settings.'
      : 'Copies on your Mac show up as a notification; tap it to copy. Needs Internet on both devices.');
    // Keep the Mac's copy of the subscription current (browsers rotate them occasionally).
    if ($('pushToggle').checked && Notification.permission === 'granted') await enablePush(false);
  }

  async function enablePush(ask) {
    if (ask && Notification.permission !== 'granted') {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        setPushHint('Notifications were not allowed.');
        return false;
      }
    }
    const registration = await pushRegistration();
    if (!registration) {
      setPushHint('Trust your Mac’s certificate first (⚙ Settings), then reload — the browser only allows notifications from trusted sites.');
      return false;
    }
    try {
      const keyResponse = await fetch('/api/push/key', { headers: authHeaders(), cache: 'no-store' });
      if (!keyResponse.ok) throw new Error(String(keyResponse.status));
      const { key } = await keyResponse.json();
      let subscription = await registration.pushManager.getSubscription();
      // A subscription made for another Mac key can't be reused.
      const current = subscription && subscription.options && subscription.options.applicationServerKey;
      if (subscription && current && btoa(String.fromCharCode(...new Uint8Array(current))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') !== key) {
        await subscription.unsubscribe();
        subscription = null;
      }
      if (!subscription) {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(key),
        });
      }
      const body = Object.assign(subscription.toJSON(), { preview: $('pushPreview').checked });
      const r = await fetch('/api/push/subscribe', {
        method: 'POST', headers: authHeaders({ 'Content-Type': 'application/json' }), body: JSON.stringify(body),
      });
      if (!r.ok) throw new Error(String(r.status));
      return true;
    } catch {
      setPushHint('Could not turn on notifications. Check that both devices are online and try again.');
      return false;
    }
  }

  async function disablePush() {
    try {
      const registration = await pushRegistration();
      const subscription = registration && await registration.pushManager.getSubscription();
      if (subscription) await subscription.unsubscribe();
    } catch { /* already gone */ }
    try { await fetch('/api/push/unsubscribe', { method: 'POST', headers: authHeaders() }); } catch { /* offline */ }
  }

  $('pushToggle').addEventListener('change', async (e) => {
    if (e.target.checked) {
      const ok = await enablePush(true);
      e.target.checked = ok;
      store.set('clipsync.push', ok ? '1' : '0');
      if (ok) toast('Notifications on');
    } else {
      store.set('clipsync.push', '0');
      await disablePush();
    }
    $('pushPreviewRow').hidden = !e.target.checked;
  });

  $('pushPreview').addEventListener('change', async (e) => {
    store.set('clipsync.pushPreview', e.target.checked ? '1' : '0');
    if ($('pushToggle').checked) await enablePush(false);
  });
  window.addEventListener('focus', resume);
  window.addEventListener('pageshow', (e) => { if (e.persisted) resume(); });

  // ---------- Files ----------
  // Uploads go one at a time with XMLHttpRequest (fetch can't report upload progress). The Mac
  // writes them straight to disk, so size is limited by the Mac's free space, not its memory.
  const uploadQueue = [];
  let uploading = false;

  $('fileInput').addEventListener('change', (e) => {
    for (const file of e.target.files) uploadQueue.push({ file, row: addUploadRow(file) });
    e.target.value = '';
    nextUpload();
  });

  function addUploadRow(file) {
    const row = document.createElement('article');
    row.className = 'item';
    row.dataset.variant = 'outline';
    row.dataset.size = 'sm';
    const section = document.createElement('section');
    section.className = 'min-w-0 flex-1';
    const name = document.createElement('h3');
    name.className = 'truncate';
    name.textContent = file.name;
    const status = document.createElement('p');
    status.textContent = `${formatSize(file.size)} · waiting`;
    const bar = document.createElement('div');
    bar.className = 'progress mt-2';
    bar.setAttribute('role', 'progressbar');
    bar.setAttribute('aria-label', `Uploading ${file.name}`);
    bar.setAttribute('aria-valuemin', '0');
    bar.setAttribute('aria-valuemax', '100');
    const fill = document.createElement('span');
    fill.style.width = '0%';
    bar.append(fill);
    section.append(name, status, bar);
    row.append(section);
    $('uploads').prepend(row);
    return {
      progress(pct) {
        fill.style.width = `${pct}%`;
        bar.setAttribute('aria-valuenow', String(Math.round(pct)));
        status.textContent = `${formatSize(file.size)} · ${Math.round(pct)}%`;
      },
      finish(text, ok) {
        bar.remove();
        status.textContent = text;
        if (!ok) status.className = 'text-destructive';
      },
    };
  }

  function nextUpload() {
    if (uploading || uploadQueue.length === 0) return;
    uploading = true;
    const { file, row } = uploadQueue.shift();
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/files');
    xhr.setRequestHeader('X-Token', token);
    xhr.setRequestHeader('X-Filename', encodeURIComponent(file.name));
    xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
    xhr.upload.onprogress = (e) => { if (e.lengthComputable) row.progress((e.loaded / e.total) * 100); };
    xhr.onload = () => {
      let reply = {};
      try { reply = JSON.parse(xhr.responseText); } catch { /* not JSON */ }
      if (xhr.status === 200) {
        row.finish(`${formatSize(file.size)} · saved to Downloads as “${reply.name || file.name}”`, true);
        toast('Sent to your Mac');
      } else if (xhr.status === 401) {
        row.finish('Not paired any more', false);
        unpaired('This phone is no longer paired. Pair it again.');
      } else if (xhr.status === 413) {
        row.finish(`Too large (max ${formatSize(reply.max || 0)})`, false);
      } else if (xhr.status === 507) {
        row.finish('Not enough space on your Mac', false);
      } else {
        row.finish(`Failed (${xhr.status})`, false);
      }
      done();
    };
    xhr.onerror = () => { row.finish('Could not reach your Mac', false); done(); };
    xhr.onabort = () => { row.finish('Cancelled', false); done(); };
    function done() { uploading = false; nextUpload(); }
    xhr.send(file);
  }

  // Downloads use a short-lived link from the Mac. When the Mac's certificate is trusted (the
  // service worker only runs then), the browser's download manager fetches it — best for big
  // files. Otherwise that separate request can be refused over the untrusted certificate (Chrome
  // on Android), so the page downloads it itself over its already-accepted connection.
  const IN_PAGE_DOWNLOAD_LIMIT = 1024 * 1024 * 1024;

  $('downloadBtn').addEventListener('click', async () => {
    if (!current || current.kind !== 'file') return;
    const item = current;
    const name = item.text || 'file';
    try {
      const r = await fetch(`/api/files/ticket?id=${encodeURIComponent(item.id)}`, {
        method: 'POST', headers: authHeaders(),
      });
      if (r.status === 401) { unpaired('This phone is no longer paired. Pair it again.'); return; }
      if (!r.ok) { toast('This file is no longer available', 'error'); return; }
      const { url } = await r.json();

      if (navigator.serviceWorker && navigator.serviceWorker.controller) {
        saveLink(url, name);
        toast('Downloading…', 'info');
        return;
      }
      if ((item.size || 0) > IN_PAGE_DOWNLOAD_LIMIT) {
        toast('Large file: trust your Mac’s certificate (⚙ Settings) to download it', 'error');
        return;
      }
      await downloadInPage(url, name, item.size || 0);
    } catch {
      toast('Could not reach your Mac', 'error');
    }
  });

  function saveLink(url, name) {
    const link = document.createElement('a');
    link.href = url;
    link.download = name;
    document.body.append(link);
    link.click();
    link.remove();
  }

  async function downloadInPage(url, name, size) {
    const row = addUploadRow({ name, size });
    row.progress(0);
    const r = await fetch(url, { cache: 'no-store' });
    if (!r.ok || !r.body) {
      row.finish(r.status === 403 ? 'Your Mac can’t read this file (macOS privacy settings)' : `Failed (${r.status})`, false);
      return;
    }
    const total = Number(r.headers.get('Content-Length')) || size;
    const reader = r.body.getReader();
    const chunks = [];
    let received = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      if (total) row.progress((received / total) * 100);
    }
    if (total && received !== total) {
      row.finish('Download interrupted, try again', false);
      return;
    }
    const blobURL = URL.createObjectURL(new Blob(chunks, { type: r.headers.get('Content-Type') || 'application/octet-stream' }));
    saveLink(blobURL, name);
    setTimeout(() => URL.revokeObjectURL(blobURL), 60000);
    row.finish(`${formatSize(received)} · downloaded`, true);
  }

  // ---------- Android share sheet (Web Share Target) ----------
  // sw.js parks shared items in a cache and opens /?shared=1; send them now that we have the token.
  async function takeShared() {
    if (!new URLSearchParams(location.search).has('shared')) return;
    history.replaceState(null, '', '/');
    if (!('caches' in window)) return;
    const cache = await caches.open('clipsync-share');
    for (const request of await cache.keys()) {
      const response = await cache.match(request);
      await cache.delete(request);
      if (!response) continue;
      if (new URL(request.url).pathname === '/shared/text') {
        const text = await response.text();
        if (await postClip(text, 'text/plain; charset=utf-8')) {
          markSynced(await hashText(text));
          toast('Shared to your Mac’s clipboard');
        }
      } else {
        const blob = await response.blob();
        const name = decodeURIComponent(response.headers.get('X-Filename') || 'Shared%20file');
        const file = new File([blob], name, { type: blob.type });
        uploadQueue.push({ file, row: addUploadRow(file) });
      }
    }
    nextUpload();
  }

  // ---------- Install as an app (PWA) ----------
  const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  let installPrompt = null;
  let workerFailed = false;

  if ('serviceWorker' in navigator) {
    // Browsers refuse service workers (and so installation) until the Mac's certificate is trusted.
    navigator.serviceWorker.register('/sw.js').catch(() => { workerFailed = true; updateInstall(); });
  }
  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    installPrompt = event;
    updateInstall();
  });
  window.addEventListener('appinstalled', () => {
    installPrompt = null;
    updateInstall();
    toast('ClipSync installed');
  });

  function updateInstall() {
    const card = $('installCard');
    let text = '';
    if (!standalone && store.get('clipsync.installDismissed') !== '1') {
      if (installPrompt) {
        text = 'Open ClipSync like an app, and send photos, videos and links straight from Android’s Share menu.';
      } else if (isIOS) {
        text = 'Tap Share, then “Add to Home Screen”. Open ClipSync from the Home Screen and pair it there with the code shown under the QR code on your Mac.';
      } else if (workerFailed) {
        text = 'To install ClipSync as an app, first trust your Mac’s certificate (⚙ Settings), then reload this page.';
      }
    }
    $('installText').textContent = text;
    $('installBtn').hidden = !installPrompt;
    card.hidden = !text;
  }

  $('installBtn').addEventListener('click', async () => {
    if (!installPrompt) return;
    installPrompt.prompt();
    await installPrompt.userChoice.catch(() => null);
    installPrompt = null;
    updateInstall();
  });
  $('installDismiss').addEventListener('click', () => {
    store.set('clipsync.installDismissed', '1');
    updateInstall();
  });
  updateInstall();

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
