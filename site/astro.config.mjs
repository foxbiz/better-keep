import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://betterkeep.app',
  output: 'static',
  trailingSlash: 'never',
  build: {
    format: 'file'
  }
});
