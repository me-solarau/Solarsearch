// Native push (Capacitor, B2). No-ops on plain web — only runs inside the
// wrapped iOS/Android app, where window.Capacitor is injected. Captures the
// APNs/FCM device token and stores it in the same push_subscriptions table
// (platform 'ios'|'android') so the dispatch layer reaches native devices.
//
// The @capacitor/push-notifications import is computed + @vite-ignore'd so the
// web Vite build never tries to resolve it (the plugin only exists in the
// mobile/ Capacitor project).

export function isNative() {
  return !!(typeof window !== "undefined" && window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
}

export async function registerNativePush(db, { onOpenPool } = {}) {
  if (!isNative()) return { ok: false, state: "not-native" };
  let Push;
  try {
    const spec = "@capacitor/push-notifications";
    Push = (await import(/* @vite-ignore */ spec)).PushNotifications;
  } catch (_) { return { ok: false, state: "plugin-missing" }; }

  const platform = window.Capacitor.getPlatform ? window.Capacitor.getPlatform() : "ios";

  const perm = await Push.requestPermissions();
  if (perm.receive !== "granted") return { ok: false, state: "denied" };

  return await new Promise((resolve) => {
    Push.addListener("registration", async (token) => {
      const { data: { session } } = await db.auth.getSession();
      if (!session) { resolve({ ok: false, state: "no-session" }); return; }
      const { error } = await db.from("push_subscriptions").upsert({
        user_id: session.user.id,
        endpoint: `${platform}:${token.value}`,   // token URI; unique per device
        platform,
        user_agent: navigator.userAgent,
        last_seen_at: new Date().toISOString(),
      }, { onConflict: "endpoint" });
      resolve({ ok: !error, state: error ? "save-failed" : "on", error: error?.message });
    });
    Push.addListener("registrationError", (e) => resolve({ ok: false, state: "reg-error", error: String(e?.error || e) }));
    Push.addListener("pushNotificationActionPerformed", () => { if (onOpenPool) onOpenPool(); });
    Push.register();
  });
}
