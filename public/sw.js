/* Solarsearch service worker — web push for the technician job pool (B1).
   Served from the site root so its scope covers /tech.html. Kept tiny and
   dependency-free; it only shows push notifications and routes taps. */

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) { data = { body: event.data && event.data.text() }; }
  const title = data.title || "New job near you";
  const options = {
    body: data.body || "A new assessment is available in your area.",
    icon: data.icon || "/icon-192.png",
    badge: data.badge || "/badge-72.png",
    tag: data.tag || "job-pool",           // collapse repeats into one
    renotify: true,
    requireInteraction: false,
    data: { url: data.url || "/tech.html#pool" },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "/tech.html#pool";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (c.url.includes("/tech.html") && "focus" in c) { c.postMessage({ type: "open-pool" }); return c.focus(); }
      }
      return self.clients.openWindow(target);
    }),
  );
});
