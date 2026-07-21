// Web Push enrolment helper (B1). Registers the service worker, subscribes with
// the site's VAPID public key, and stores the subscription in push_subscriptions
// so notify-pool can reach this device. Safe to call repeatedly (idempotent
// upsert on endpoint). iOS only delivers web push when the PWA is installed to
// the home screen (iOS 16.4+); on unsupported setups this resolves to a status
// the UI can explain rather than throwing.

const VAPID_PUBLIC = import.meta.env.VITE_VAPID_PUBLIC_KEY;

function urlB64ToUint8Array(base64) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const b64 = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b64);
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

export function pushSupported() {
  return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
}

// Returns 'on' | 'off' | 'blocked' | 'unsupported'
export async function pushState() {
  if (!pushSupported()) return "unsupported";
  if (Notification.permission === "denied") return "blocked";
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = reg && (await reg.pushManager.getSubscription());
    return sub ? "on" : "off";
  } catch (_) { return "off"; }
}

export async function enableJobAlerts(db) {
  if (!pushSupported()) return { ok: false, state: "unsupported" };
  if (!VAPID_PUBLIC) return { ok: false, state: "unconfigured" };

  const perm = await Notification.requestPermission();
  if (perm !== "granted") return { ok: false, state: perm === "denied" ? "blocked" : "off" };

  const reg = await navigator.serviceWorker.register("/sw.js");
  await navigator.serviceWorker.ready;

  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlB64ToUint8Array(VAPID_PUBLIC),
    });
  }
  const json = sub.toJSON();
  const { data: { session } } = await db.auth.getSession();
  if (!session) return { ok: false, state: "no-session" };

  const { error } = await db.from("push_subscriptions").upsert({
    user_id: session.user.id,
    endpoint: json.endpoint,
    p256dh: json.keys?.p256dh,
    auth: json.keys?.auth,
    platform: "web",
    user_agent: navigator.userAgent,
    last_seen_at: new Date().toISOString(),
  }, { onConflict: "endpoint" });
  if (error) return { ok: false, state: "save-failed", error: error.message };
  return { ok: true, state: "on" };
}

export async function disableJobAlerts(db) {
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = reg && (await reg.pushManager.getSubscription());
    if (sub) {
      await db.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
      await sub.unsubscribe();
    }
  } catch (_) { /* best effort */ }
  return { ok: true, state: "off" };
}
