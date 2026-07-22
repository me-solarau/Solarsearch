import type { CapacitorConfig } from "@capacitor/cli";

// Solarsearch for Installers — the installer portal app.
// Loads the hosted launcher (app-installer.html) for over-the-air updates; the
// Capacitor bridge is injected so push works against the remote content. No
// in-app purchases: seats + commissions are billed outside the app (Stripe),
// so Apple IAP obligations never trigger.
const config: CapacitorConfig = {
  appId: "net.solarme.solarsearch.installer",
  appName: "Solarsearch for Installers",
  webDir: "www",
  server: {
    url: "https://www.solarsearch.com.au/app-installer.html",
    cleartext: false,
  },
  ios: { contentInset: "always", limitsNavigationsToAppBoundDomains: false },
  android: { allowMixedContent: false },
  plugins: {
    PushNotifications: { presentationOptions: ["badge", "sound", "alert"] },
  },
};

export default config;
