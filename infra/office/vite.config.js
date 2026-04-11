import { defineConfig } from 'vite';

export default defineConfig({
  root: '.',
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:7780',
    },
  },
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
  },
});
