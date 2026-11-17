import {expect, it, vi} from 'vitest';
import {verifyLocalTestEnvironment} from '../../scripts/playwright-preflight';

it('拒绝复用指向远程 API 的开发进程及缺失探针的静态站点', async () => {
  for (const response of [new Response('{"localApi":false}', {headers: {'content-type': 'application/json'}}), new Response('<html>fallback</html>', {headers: {'content-type': 'text/html'}})]) {
    const fetcher = vi.fn().mockResolvedValue(response);
    await expect(verifyLocalTestEnvironment('http://127.0.0.1:5173/web/', fetcher)).rejects.toThrow('不能复用连接生产');
  }
});
it('拒绝远程测试地址，确认本机后才继续', async () => {
  const fetcher = vi.fn().mockResolvedValue(new Response('{"localApi":true}', {headers: {'content-type': 'application/json'}}));
  await expect(verifyLocalTestEnvironment('https://example.invalid/web/', fetcher)).rejects.toThrow('只允许连接本机');
  expect(fetcher).not.toHaveBeenCalled();
  await expect(verifyLocalTestEnvironment('http://127.0.0.1:5173/web/', fetcher)).resolves.toBeUndefined();
  expect(fetcher).toHaveBeenCalledTimes(1);
});
