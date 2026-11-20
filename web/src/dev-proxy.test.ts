import {afterEach, describe, expect, it, vi} from 'vitest';
import {createServer as createHttpServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createLogger, createServer} from 'vite';

const root = resolve(import.meta.dirname, '..');
// 集成测试的优化配置不同于日常开发，必须隔离缓存，避免使正在运行的网页依赖返回 504。
const options = {root, cacheDir: resolve(root, '../artifacts/vite-proxy-test-cache'), configFile: resolve(root, 'vite.config.ts'), customLogger: createLogger('silent'), optimizeDeps: {noDiscovery: true, include: []}, server: {port: 0, strictPort: false, host: '127.0.0.1'}};
afterEach(() => vi.unstubAllEnvs());

describe('development proxy boundaries', () => {
  it.each([['http://127.0.0.1:8080', true], ['https://example.invalid', false]])('测试环境探针核对实际开发进程的上游：%s', async (upstream, localApi) => {
    vi.stubEnv('SYLULIVE_API_ORIGIN', upstream);
    const server = await createServer(options);
    try {
      await server.listen();
      const address = server.httpServer!.address() as {port: number};
      const response = await fetch(`http://127.0.0.1:${address.port}/web/__test-environment`);
      expect(response.headers.get('cache-control')).toBe('no-store');
      expect(await response.json()).toEqual({localApi});
    } finally {await server.close();}
  });
  it('defaults every backend route to local Go rather than production', async () => {
    vi.stubEnv('SYLULIVE_API_ORIGIN', undefined);
    const server = await createServer(options);
    try {
      for (const path of ['/api', '/uploads', '/stickers', '/terms', '/privacy'])
        expect((server.config.server.proxy![path] as {target: string}).target).toBe('http://127.0.0.1:8080');
    } finally { await server.close(); }
  });
  it('explicit online mode connects the live API while an explicit origin still wins', async () => {
    vi.stubEnv('SYLULIVE_API_ORIGIN', undefined);
    const online = await createServer({...options, mode: 'online'});
    try {
      for (const path of ['/api', '/uploads', '/stickers', '/terms', '/privacy'])
        expect((online.config.server.proxy![path] as {target: string}).target).toBe('https://sylulive.online');
    } finally {await online.close();}
    vi.stubEnv('SYLULIVE_API_ORIGIN', 'http://127.0.0.1:8080');
    const explicit = await createServer({...options, mode: 'online'});
    try {expect((explicit.config.server.proxy!['/api'] as {target: string}).target).toBe('http://127.0.0.1:8080');}
    finally {await explicit.close();}
  });
  it('serves legal documents through the selected local upstream and preserves foreign Origin checks', async () => {
    const origins: (string | undefined)[] = [];
    const backend = createHttpServer(async (request, response) => {
      if (request.url === '/terms' || request.url === '/privacy') {
        const name = request.url === '/terms' ? 'terms' : 'privacy';
        response.setHeader('Content-Type', 'text/html; charset=utf-8');
        response.end(await readFile(resolve(root, '../server/static/legal', `${name}.html`)));
      } else {
        origins.push(request.headers.origin);
        response.setHeader('Content-Type', 'application/json');
        response.end('{}');
      }
    });
    await new Promise<void>(done => backend.listen(0, '127.0.0.1', done));
    const port = (backend.address() as {port: number}).port, upstream = `http://127.0.0.1:${port}`;
    vi.stubEnv('SYLULIVE_API_ORIGIN', upstream);
    const server = await createServer(options);
    try {
      await server.listen();
      const address = server.httpServer!.address() as {port: number}, origin = `http://127.0.0.1:${address.port}`;
      for (const [path, title] of [['/terms', '沈理校园用户协议'], ['/privacy', '沈理校园隐私政策']]) {
        const response = await fetch(origin + path);
        expect(response.status).toBe(200);
        expect(await response.text()).toContain(`<h1>${title}</h1>`);
      }
      await fetch(origin + '/api/test', {method: 'POST', headers: {Origin: origin}, body: '{}'});
      await fetch(origin + '/api/test', {method: 'POST', headers: {Origin: 'https://untrusted.invalid'}, body: '{}'});
      expect(origins).toEqual([upstream, 'https://untrusted.invalid']);
    } finally {
      await server.close();
      await new Promise<void>((done, reject) => backend.close(error => error ? reject(error) : done()));
    }
  });
  it.each(['https://name:password@example.invalid', 'https://example.invalid/api', 'https://example.invalid/?token=test'])('rejects credentials or hidden URL components: %s', async target => {
    vi.stubEnv('SYLULIVE_API_ORIGIN', target);
    await expect(createServer(options)).rejects.toThrow('SYLULIVE_API_ORIGIN');
  });
});
