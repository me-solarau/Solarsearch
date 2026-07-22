import type { CapacitorConfig } from '@capacitor/cli';

// Native shell for the Solarsearch field apps. Two ways to point it at the web app:
//  A) server.url (below) — loads the hosted tech app; always latest, needs network to boot.
//  B) webDir bundle — copy the built tech app into mobile/www and ship it inside the binary.
// Start with (B) for App Store review predictability; (A) is handy for fast iteration.
const config: CapacitorConfig = {
  appId: 'net.solarme.solarsearch.tech',
  appName: 'Solarsearch Tech',
  webDir: 'www',
  server: {
    androidScheme: 'https',
    // url: 'https://<your-tech-app-host>/tech.html',   // uncomment for option (A)
    // cleartext: false,
  },
  ios: {
    contentInset: 'always',
  },
  plugins: {
    PushNotifications: { presentationOptions: ['badge', 'sound', 'alert'] },
    Geolocation: {},
    Camera: {},
  },
};

export default config;
