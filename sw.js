/* Service worker: offline shell + notification clicks.
 *
 * Scope is the folder this file is served from, so the app works both at a
 * domain root and under a GitHub Pages project path (/<repo>/).
 *
 * Bump CACHE whenever the precached files change; the old cache is deleted on
 * activate and every client gets the new shell on its next load.
 */
const CACHE = "pos-shell-v8";

// Relative to the service worker scope.
const SHELL = [
  "./",
  "index.html",
  "adminlogin.html",
  "pending.html",
  "dashboard.html",
  "managebills.html",
  "menu.html",
  "ingredients.html",
  "usage.html",
  "staff.html",
  "settings.html",
  "audit.html",
  "account.html",
  "kitchen.html",
  "sales.html",
  "offline.html",
  "css/style.css",
  "js/config.js",
  "js/common.js",
  "js/notify.js",
  "js/shell.js",
  "manifest.webmanifest",
  "icons/icon-192.png",
  "icons/icon-512.png",
  "icons/maskable-512.png",
  "icons/apple-touch-icon.png",
  "icons/badge-96.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) =>
      // One bad URL must not fail the whole install.
      Promise.all(SHELL.map((u) => c.add(new Request(u, { cache: "reload" })).catch(() => {})))
    )
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)));
      await self.clients.claim();
    })()
  );
});

self.addEventListener("message", (e) => {
  if (e.data === "SKIP_WAITING") self.skipWaiting();
});

// Supabase (REST, Realtime, Storage) must always hit the network.
const isApi = (url) => url.hostname.endsWith(".supabase.co") || url.hostname.endsWith(".supabase.in");

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  if (isApi(url)) return;
  if (url.protocol !== "http:" && url.protocol !== "https:") return;

  // Pages: network first so a signed-in admin never sees a stale screen.
  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
          return res;
        })
        .catch(async () => (await caches.match(req)) || (await caches.match("offline.html")) || Response.error())
    );
    return;
  }

  // Styles, scripts, icons, fonts, CDN libraries: serve fast, refresh in the background.
  e.respondWith(
    caches.match(req).then((hit) => {
      const net = fetch(req)
        .then((res) => {
          if (res && (res.ok || res.type === "opaque")) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
          }
          return res;
        })
        .catch(() => hit);
      return hit || net;
    })
  );
});

// Notifications are shown through the registration (the Notification
// constructor is unavailable on Android Chrome), so the click lands here.
// A sign-in alert carries Approve / Deny buttons; answering one is relayed to
// an open page, which has the super admin's token. With no page open, the
// dashboard is opened with the answer in the URL and acts on it there.
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const data = e.notification.data || {};
  const action = e.action;

  e.waitUntil(
    (async () => {
      const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });

      if ((action === "approve" || action === "deny") && data.sessionId) {
        if (clients.length) {
          clients.forEach((c) => c.postMessage({ type: "approval", action, sessionId: data.sessionId }));
          return clients[0].focus();
        }
        if (self.clients.openWindow) {
          return self.clients.openWindow(`dashboard.html?${action}=${data.sessionId}`);
        }
        return;
      }

      const target = data.url;
      for (const c of clients) {
        if ("focus" in c) {
          if (target && "navigate" in c) await c.navigate(target).catch(() => {});
          return c.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(target || "./dashboard.html");
    })()
  );
});
