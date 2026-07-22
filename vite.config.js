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
        join: resolve(__dirname, 'join.html'),
        apply: resolve(__dirname, 'apply.html'),
        install: resolve(__dirname, 'install.html'),
        stripereturn: resolve(__dirname, 'stripe-return.html')
      }
    }
  }
})
