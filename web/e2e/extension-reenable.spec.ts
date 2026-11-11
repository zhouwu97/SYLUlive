import {test, expect, chromium, type Page} from '@playwright/test';
import {mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {tmpdir} from 'node:os';

async function hello(page: Page) {
  return page.evaluate(() => new Promise<boolean>(done => {
    const id = crypto.randomUUID();
    const finish = (ok: boolean) => { clearTimeout(timer); window.removeEventListener('message', receive); done(ok); };
    const receive = (event: MessageEvent) => {
      if (event.source === window && event.origin === location.origin && event.data?.channel === 'sylulive-academic-v1' && event.data?.direction === 'response' && event.data?.id === id) finish(event.data.ok === true);
    };
    const timer = setTimeout(() => finish(false), 400);
    window.addEventListener('message', receive);
    window.postMessage({channel: 'sylulive-academic-v1', direction: 'request', version: 1, id, operation: 'hello', payload: {}}, location.origin);
  }));
}

test('真实扩展停用后重新启用，在原标签页免刷新恢复握手且不读取学校资料', async () => {
  const root = await mkdtemp(join(tmpdir(), 'sylulive-reenable-'));
  const controllerPath = join(root, 'controller');
  await mkdir(controllerPath);
  // management 只授予临时测试控制器，产品扩展的权限不变。
  await writeFile(join(controllerPath, 'manifest.json'), JSON.stringify({manifest_version: 3, name: 'SYLU test controller', version: '1.0', permissions: ['management'], background: {service_worker: 'background.js'}}));
  await writeFile(join(controllerPath, 'background.js'), 'chrome.runtime.onInstalled.addListener(() => {});');
  const extension = resolve('browser-extension/dist-dev');
  const paths = `${extension},${controllerPath}`;
  const context = await chromium.launchPersistentContext(join(root, 'profile'), {channel: 'chromium', headless: true, args: [`--disable-extensions-except=${paths}`, `--load-extension=${paths}`]});
  const schoolRequests: string[] = [];
  try {
    await expect.poll(() => context.serviceWorkers().length).toBeGreaterThanOrEqual(2);
    const workers = await Promise.all(context.serviceWorkers().map(async worker => ({worker, name: await worker.evaluate(() => chrome.runtime.getManifest().name)})));
    const controller = workers.find(value => value.name === 'SYLU test controller')!.worker;
    const product = workers.find(value => value.name === '沈理校园教务助手')!.worker;
    const id = new URL(product.url()).hostname;
    await context.route('**/api/**', route => route.fulfill({json: {items: []}}));
    await context.route(/https?:\/\/(?:(?:jxw|yjsgl|webvpn)\.sylu\.edu\.cn|47\.92\.231\.221)\//, route => { schoolRequests.push(route.request().url()); return route.abort(); });
    const page = await context.newPage();
    await page.goto('http://127.0.0.1:5173/web/schedule');
    await expect.poll(() => hello(page)).toBe(true);
    let navigations = 0;
    page.on('framenavigated', frame => { if (frame === page.mainFrame()) navigations++; });
    await controller.evaluate(extensionId => chrome.management.setEnabled(extensionId, false), id);
    await expect.poll(() => hello(page)).toBe(false);
    await controller.evaluate(extensionId => chrome.management.setEnabled(extensionId, true), id);
    await expect.poll(() => hello(page), {timeout: 10000}).toBe(true);
    expect(navigations).toBe(0);
    expect(schoolRequests).toEqual([]);
  } finally {
    await context.close();
    if (!resolve(root).startsWith(resolve(tmpdir(), 'sylulive-reenable-'))) throw new Error('test profile outside expected temporary directory');
    await rm(root, {recursive: true, force: true});
  }
});
