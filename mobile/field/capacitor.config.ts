import type { CapacitorConfig } from "@capacitor/cli";

// Solarsearch Field — the Sales Technician + Consultant app.
// Loads the hosted launcher (app-field.html) so the app updates over-the-air
// without a store resubmission; the Capacitor native bridge is still injected,
// so push / camera / geolocation plugins work against the remote content.
// The local www/ splash covers the brief moment before the site loads (and any
// offline launch).
const config: CapacitorConfig = {
  appId: "net.solarme.solarsearch.tech",
  appName: "Solarsearch Field",
  webDir: "www",
  server: {
    url: "https://www.solarsearch.com.au/app-field.html",
    cleartext: false,
  },
  ios: { contentInset: "always", limitsNavigationsToAppBoundDomains: false },
  android: { allowMixedContent: false },
  plugins: {
    PushNotifications: { presentationOptions: ["badge", "sound", "alert"] },
  },
};

export default config;
