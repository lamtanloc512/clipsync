// ClipSync service worker: makes the phone client installable, starts it instantly from cache,
// and receives Android "Share → ClipSync" (Web Share Target). Clipboard data and files are never
// cached; only the app shell is. Versions are filled in by build.mjs.
const VERSION = '__SW_VERSION__';
const SHELL_CACHE = `clipsync-shell-${VERSION}`;
const SHARE_CACHE = 'clipsync-share';
const SHELL = [
  '/',
  '/app.css?v=__CSS_VERSION__',
  '/app.js?v=__JS_VERSION__',
  '/manifest.webmanifest',
  '/icon.svg',
  '/icon-180.png',
  '/icon-192.png',
  '/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys
        .filter((key) => key.startsWith('clipsync-shell-') && key !== SHELL_CACHE)
        .map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.method === 'POST' && url.pathname === '/share-target') {
    event.respondWith(receiveShare(request));
    return;
  }
  // Live data (clipboard, pairing, uploads, downloads) always goes to the Mac.
  if (request.method !== 'GET' || url.pathname.startsWith('/api/') || url.pathname.startsWith('/dl/')) return;

  if (request.mode === 'navigate') {
    // Network first, so a ClipSync update on the Mac shows up immediately; cached shell offline.
    event.respondWith(fetch(request).catch(() => caches.match('/')));
    return;
  }
  event.respondWith(caches.match(request).then((cached) => cached || fetch(request)));
});

// Android share sheet → ClipSync. The service worker has no access to the device token, so it
// parks the shared items in a cache and hands over to the page (/?shared=1), which sends them.
async function receiveShare(request) {
  const form = await request.formData();
  const cache = await caches.open(SHARE_CACHE);
  for (const key of await cache.keys()) await cache.delete(key);

  let index = 0;
  for (const file of form.getAll('files')) {
    if (!(file instanceof File) || file.size === 0) continue;
    await cache.put(`/shared/file/${index++}`, new Response(file, {
      headers: {
        'Content-Type': file.type || 'application/octet-stream',
        'X-Filename': encodeURIComponent(file.name || 'Shared file'),
      },
    }));
  }
  // Shared links usually arrive as text and/or url; the page title only if there is nothing else.
  const values = ['text', 'url'].map((field) => form.get(field))
    .filter((value) => typeof value === 'string' && value.trim());
  const unique = [...new Set(values.map((value) => value.trim()))];
  const title = form.get('title');
  const text = unique.length ? unique.join('\n') : (typeof title === 'string' ? title.trim() : '');
  if (text) await cache.put('/shared/text', new Response(text));

  return Response.redirect('/?shared=1', 303);
}
