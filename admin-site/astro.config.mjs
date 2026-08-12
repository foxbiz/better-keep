import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://admin.betterkeep.app',
  output: 'static',
  trailingSlash: 'never',
  build: {
    format: 'file',
    inlineStylesheets: 'never'
  },
  vite: {
    build: {
      assetsInlineLimit: 0
    }
  }
});
