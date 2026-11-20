import type {FullConfig} from '@playwright/test';

export async function verifyLocalTestEnvironment(baseURL: string, fetcher: typeof fetch = fetch) {
  const base = new URL(baseURL);
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)) throw new Error('浏览器自动化只允许连接本机测试站点');
  const response = await fetcher(new URL('/web/__test-environment', base), {redirect: 'error', signal: AbortSignal.timeout(5000)});
  if (!response.ok || !response.headers.get('content-type')?.includes('application/json') || (await response.json()).localApi !== true)
    throw new Error('当前开发进程未确认使用本机 API。请使用本地 Go/测试夹具启动开发服务，不能复用连接生产的联调进程。');
}
export default async function preflight(config: FullConfig) {
  await verifyLocalTestEnvironment(String(config.projects[0].use.baseURL));
}
