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
        solarsafe: resolve(__dirname, 'solarsafe.html'),
        privacy: resolve(__dirname, 'privacy.html'),
        collection: resolve(__dirname, 'collection-notice.html'),
        login: resolve(__dirname, 'login.html')
      }
    }
  }
})
