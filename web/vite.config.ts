import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';

const origin = new URL(process.env.SYLULIVE_API_ORIGIN || 'http://127.0.0.1:8080');
if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash)
  throw new Error('SYLULIVE_API_ORIGIN 必须是不含账号、路径或查询参数的 HTTP(S) origin');
const target = origin.origin;

export default defineConfig({
  base: '/web/',
  plugins: [react()],
  server: {
    host: '127.0.0.1', port: 5173, strictPort: true,
    watch: {ignored: ['**/public/assistant/**']},
    proxy: {
      '/api': {target, changeOrigin: true, configure(proxy) {
        proxy.on('proxyReq', (proxyReq, req) => {
          // 只改写本地页面的 Origin，其他来源继续交由后端校验。
          const localOrigin = req.headers.origin, host = (req.headers.host || '').replace(/:\d+$/, '');
          try {
            if (localOrigin && new URL(localOrigin).protocol === 'http:' && new URL(localOrigin).hostname === host)
              proxyReq.setHeader('Origin', target);
          } catch { /* 非法 Origin 原样转发。 */ }
        });
      }},
      '/uploads': {target, changeOrigin: true},
      '/stickers': {target, changeOrigin: true},
      '/terms': {target, changeOrigin: true},
      '/privacy': {target, changeOrigin: true},
      '/extension/privacy': {target, changeOrigin: true},
    },
  },
  build: {sourcemap: false},
});
