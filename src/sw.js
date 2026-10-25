// The phone wall's service worker: keeps the app shell (the page and its
// files) so the Home Screen app opens without the network. The fleet itself,
// /fleet.json and /events, is never cached or answered from here: a stale
// wall must never pass for a live one.
const SHELL = "klepsydra-shell-v1";
const LIVE = new Set(["/fleet.json", "/events"]);

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.add("/")).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// The shell from the network first, so an update shows at once; the cached
// copy only when the network fails.
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin || LIVE.has(url.pathname)) return;
  e.respondWith(
    fetch(e.request)
      .then((res) => {
        if (res.ok && res.type === "basic") {
          const copy = res.clone();
          caches.open(SHELL).then((c) => c.put(e.request, copy));
        }
        return res;
      })
      .catch(() => caches.match(e.request).then((hit) => hit ?? Response.error())),
  );
});
