const CACHE = "smc-shell-v3";
const SHELL = [
  "/",
  "/static/style.css",
  "/static/app.js",
  "/manifest.webmanifest",
  "/static/icons/icon-192.png",
  "/static/icons/icon-512.png",
  "/static/icons/icon-maskable-512.png"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const req = event.request;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (req.method !== "GET") return;
  if (url.pathname.startsWith("/api/") || url.pathname === "/health") {
    event.respondWith(fetch(req));
    return;
  }
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req).then(res => {
        const clone = res.clone();
        caches.open(CACHE).then(cache => cache.put("/", clone));
        return res;
      }).catch(() => caches.match("/").then(r => r || Response.error()))
    );
    return;
  }
  event.respondWith(
    caches.match(req).then(cached => cached || fetch(req).then(res => {
      if (res.ok && url.pathname.startsWith("/static/")) {
        const clone = res.clone();
        caches.open(CACHE).then(cache => cache.put(req, clone));
      }
      return res;
    }))
  );
});
