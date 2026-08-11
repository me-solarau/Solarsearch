import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        quote: resolve(__dirname, 'quote.html'),
        hq: resolve(__dirname, 'hq.html'),
        field: resolve(__dirname, 'field.html'),
        installer: resolve(__dirname, 'installer.html'),
        retailer: resolve(__dirname, 'retailer.html'),
        choose: resolve(__dirname, 'choose.html'),
        sign: resolve(__dirname, 'sign.html'),
        tech: resolve(__dirname, 'tech.html'),
        techbadge: resolve(__dirname, 'tech-badge.html'),
        appfield: resolve(__dirname, 'app-field.html'),
        appinstaller: resolve(__dirname, 'app-installer.html'),
        pack: resolve(__dirname, 'pack.html'),
        solarsafe: resolve(__dirname, 'solarsafe.html'),
        privacy: resolve(__dirname, 'privacy.html'),
        appprivacy: resolve(__dirname, 'app-privacy.html'),
        collection: resolve(__dirname, 'collection-notice.html'),
        login: resolve(__dirname, 'login.html'),
        resetpassword: resolve(__dirname, 'reset-password.html'),
        join: resolve(__dirname, 'join.html'),
        apply: resolve(__dirname, 'apply.html'),
        install: resolve(__dirname, 'install.html'),
        // manifest.webmanifest, icon-192.png and icon-512.png live in public/ so
        // they ship at the site root, which the manifest's paths assume.
        stripereturn: resolve(__dirname, 'stripe-return.html'),
        // Cornerstone SEO / trust pages — the organic lead channel
        accreditedinstaller: resolve(__dirname, 'accredited-installer.html'),
        solarcostnsw: resolve(__dirname, 'solar-cost-nsw.html'),
        addbattery: resolve(__dirname, 'add-battery-to-solar.html'),
        compliantinstall: resolve(__dirname, 'compliant-solar-install.html'),
        coldcalls: resolve(__dirname, 'solar-quotes-without-cold-calls.html')
      }
    }
  }
})
