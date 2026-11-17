import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({mode}) => {
// 线上联调必须显式选择；默认开发和测试继续连接本机后端。
const origin = new URL(process.env.SYLULIVE_API_ORIGIN || (mode === 'online' ? 'https://sylulive.online' : 'http://127.0.0.1:8080'));
if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash)
  throw new Error('SYLULIVE_API_ORIGIN 必须是不含账号、路径或查询参数的 HTTP(S) origin');
const target = origin.origin;

return {
  base: '/web/',
  plugins: [react(), {
    name: 'local-test-environment',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const parsed = new URL(req.url || '/', 'http://localhost');
        if (/^\/theme\/[a-fA-F0-9-]{36}$/.test(parsed.pathname)) {
          res.statusCode = 302;
          res.setHeader('Location', `/web${parsed.pathname}${parsed.search}`);
          res.end();
          return;
        }
        if (parsed.pathname !== '/web/__test-environment') return next();
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Cache-Control', 'no-store');
        // 仅报告能否进行本机测试，不向浏览器暴露上游配置或任何凭据。
        res.end(JSON.stringify({localApi: ['127.0.0.1', 'localhost', '[::1]'].includes(origin.hostname)}));
      });
    },
  }],
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
};
});
