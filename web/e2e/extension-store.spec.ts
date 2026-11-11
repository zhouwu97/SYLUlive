import {test, expect, chromium, type Page} from '@playwright/test';
import {mkdtemp, rm, readFile} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {tmpdir} from 'node:os';

async function bridge(page: Page, operation = 'hello', payload: Record<string, unknown> = {}) {
  return page.evaluate(({operation, payload}) => new Promise<any>(done => {
    const id = crypto.randomUUID();
    const receive = (event: MessageEvent) => {
      if (event.source === window && event.origin === location.origin && event.data?.channel === 'sylulive-academic-v1' && event.data?.direction === 'response' && event.data.id === id) {
        clearTimeout(timer); window.removeEventListener('message', receive); done(event.data);
      }
    };
    const timer = setTimeout(() => { window.removeEventListener('message', receive); done(null); }, 1500);
    window.addEventListener('message', receive);
    window.postMessage({channel:'sylulive-academic-v1', direction:'request', version:1, id, operation, payload}, location.origin);
  }), {operation, payload});
}

test('商店包真实加载：HTTPS 权限、可信页握手、禁用体测、无学校预读', async () => {
  const extension = resolve('browser-extension/dist-store');
  const manifest = JSON.parse(await readFile(join(extension, 'manifest.json'), 'utf8'));
  expect(manifest.optional_permissions).not.toContain('cookies');
  expect([...manifest.host_permissions, ...manifest.optional_host_permissions].every((value:string)=>value.startsWith('https://'))).toBe(true);
  const root = await mkdtemp(join(tmpdir(), 'sylulive-store-'));
  const context = await chromium.launchPersistentContext(join(root, 'profile'), {channel:'chromium', headless:true,
    args:[`--disable-extensions-except=${extension}`, `--load-extension=${extension}`]});
  let schoolRequests = 0;
  try {
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
    const id = new URL(worker.url()).hostname;
    await worker.evaluate(() => chrome.storage.local.set({physicalProviderEnabled:true}));
    await worker.evaluate(() => chrome.storage.session.set({'connection:https://sylulive.online:physical': {studentId:'2099000001', epoch:'test', state:'connected'}}));
    await context.route('https://sylulive.online/**', route => route.fulfill({contentType:'text/html', body:'<!doctype html><title>Store verification</title><main>沈理校园测试页</main>'}));
    await context.route(/https?:\/\/(?:(?:jxw|yjsgl|webvpn)\.sylu\.edu\.cn|47\.92\.231\.221)\//, route => {schoolRequests++; return route.abort();});
    const page = await context.newPage();
    await page.goto('https://sylulive.online/web/');
    await expect.poll(async () => (await bridge(page))?.ok).toBe(true);
    const hello = await bridge(page);
    expect(hello.result.extensionVersion).toBe(manifest.version);
    expect(hello.result.capabilities.some((value:any)=>value.provider === 'physical')).toBe(false);
    expect(hello.result.connections).toEqual([]);
    expect(hello.result.authorized).not.toHaveProperty('physical');
    const denied = await bridge(page, 'connect', {provider:'physical'});
    expect(denied.ok).toBe(false);
    expect(denied.error.code).toBe('unsupported_query');
    const popup = await context.newPage();
    await popup.goto(`chrome-extension://${id}/assistant.html?provider=physical`);
    await expect(popup.locator('main')).toContainText('商店版');
    await expect(popup.locator('input,form')).toHaveCount(0);
    await popup.goto(`chrome-extension://${id}/assistant.html`);
    await expect(popup.locator('h1')).toContainText('教务助手');
    await expect(popup.getByRole('link',{name:'教务助手隐私说明'})).toHaveAttribute('href','privacy.html');
    await popup.goto(`chrome-extension://${id}/privacy.html`);
    await expect(popup.getByRole('heading',{level:1})).toHaveText('沈理校园教务助手隐私说明');
    await expect(popup.locator('.body')).toContainText('1517088507@qq.com');
    expect(schoolRequests).toBe(0);
  } finally {
    await context.close();
    if (!resolve(root).startsWith(resolve(tmpdir(), 'sylulive-store-'))) throw new Error('unexpected temporary profile');
    await rm(root, {recursive:true, force:true});
  }
});
