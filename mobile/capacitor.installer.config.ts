import type { CapacitorConfig } from '@capacitor/cli';

// Installer app — second Capacitor project (build separately from the tech app).
// Copy install.html -> www/index.html for this build (see README).
const config: CapacitorConfig = {
  appId: 'net.solarme.solarsearch.installer',
  appName: 'Solarsearch Installer',
  webDir: 'www',
  server: { androidScheme: 'https' },
  ios: { contentInset: 'always' },
  plugins: {
    PushNotifications: { presentationOptions: ['badge', 'sound', 'alert'] },
    Geolocation: {},
    Camera: {},
  },
};

export default config;
