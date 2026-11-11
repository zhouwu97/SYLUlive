import {afterEach, describe, expect, it, vi} from 'vitest';
import {createServer as createHttpServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createLogger, createServer} from 'vite';

const root = resolve(import.meta.dirname, '..');
const options = {root, configFile: resolve(root, 'vite.config.ts'), customLogger: createLogger('silent'), optimizeDeps: {noDiscovery: true, include: []}, server: {port: 0, strictPort: false, host: '127.0.0.1'}};
afterEach(() => vi.unstubAllEnvs());

describe('development proxy boundaries', () => {
  it('defaults every backend route to local Go rather than production', async () => {
    vi.stubEnv('SYLULIVE_API_ORIGIN', undefined);
    const server = await createServer(options);
    try {
      for (const path of ['/api', '/uploads', '/stickers', '/terms', '/privacy'])
        expect((server.config.server.proxy![path] as {target: string}).target).toBe('http://127.0.0.1:8080');
    } finally { await server.close(); }
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
