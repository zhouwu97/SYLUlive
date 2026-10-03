import {test,expect} from '@playwright/test';

const assistantPackage = {
  channel:'development',
  extensionVersion:'0.1.0',
  fileName:'sylulive-assistant.zip',
  bytes:346428,
  sha256:'a'.repeat(64),
  builtAt:'2026-09-29T07:34:55.346Z',
  sites:['https://sylulive.online/*','http://localhost:5173/*','http://127.0.0.1:5173/*'],
};

async function openConnectionDialog(page: import('@playwright/test').Page) {
  await page.route('**/api/user/profile', route => route.fulfill({json:{id:7,nickname:'测试用户',role:'user'}}));
  await page.goto('schedule');
  await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
  await page.getByRole('button',{name:'连接教务助手 / 刷新'}).click();
}

test('未安装助手且本站有安装包时给出下载与自助安装步骤', async ({page}) => {
  await page.route('**/assistant/assistant.json', route => route.fulfill({contentType:'application/json',body:JSON.stringify(assistantPackage)}));
  await openConnectionDialog(page);
  const guide = page.locator('.assistant-guide');
  await expect(guide).toBeVisible();
  const download = page.getByRole('link',{name:/下载教务助手/});
  await expect(download).toHaveAttribute('href',/\/web\/assistant\/sylulive-assistant\.zip$/);
  await expect(download).toHaveAttribute('download','sylulive-assistant-0.1.0.zip');
  await expect(page.locator('.assistant-guide .assistant-steps li')).toHaveCount(6);
  await expect(page.locator('.assistant-guide .mono')).toHaveText(/^a{8}…a{8}$/);
  await expect(page.getByRole('button',{name:'重新检测'})).toBeVisible();
  // 引导面板不能再引入第二个 role="status"，否则会破坏弹窗的状态播报与既有断言。
  await expect(page.locator('.dialog-form [role="status"]')).toHaveCount(0);
});

test('装好助手后不刷新页面自动复检，但不自动读取学校资料', async ({page}) => {
  let bindCalls = 0;
  await page.route('**/api/student-identity/bind', route => {bindCalls++;return route.fulfill({json:{ok:true}});});
  await page.route('**/assistant/assistant.json', route => route.fulfill({contentType:'application/json',body:JSON.stringify(assistantPackage)}));
  await page.addInitScript(() => {
    const state = window as unknown as {__bridgeOperations?:string[]};
    state.__bridgeOperations = [];
    // 模拟「页面已打开、四秒后才装上助手」：之前的握手全部超时，之后的握手立刻应答。
    const installedAt = Date.now() + 4000;
    window.addEventListener('message', event => {
      const request = event.data;
      if (request?.direction !== 'request') return;
      state.__bridgeOperations!.push(request.operation);
      if (request.operation !== 'hello' || Date.now() < installedAt) return;
      window.postMessage({...request,direction:'response',ok:true,result:{version:1,extensionVersion:'0.1.0',capabilities:['undergraduate','graduate','erke','physical']}}, location.origin);
    });
  });
  await openConnectionDialog(page);
  await expect(page.locator('.assistant-guide')).toBeVisible();
  await page.evaluate(() => {(window as unknown as {__noRefreshMarker:string}).__noRefreshMarker = 'same-document';});
  await expect(page.locator('.dialog-form [role="status"]')).toHaveText('教务助手已连接，可以继续。',{timeout:15000});
  expect(await page.evaluate(() => (window as unknown as {__noRefreshMarker?:string}).__noRefreshMarker)).toBe('same-document');
  const operations = await page.evaluate(() => (window as unknown as {__bridgeOperations:string[]}).__bridgeOperations);
  expect([...new Set(operations)]).toEqual(['hello']);
  expect(bindCalls).toBe(0);
});

test('安装包不可用时如实降级且不显示下载入口', async ({page}) => {
  // 生产 nginx 的 try_files 会把缺失的 assistant.json 变成 200 + index.html。
  await page.route('**/assistant/assistant.json', route => route.fulfill({status:200,contentType:'text/html',body:'<!doctype html><html><body>index</body></html>'}));
  await openConnectionDialog(page);
  await expect(page.locator('.assistant-guide .notice-line')).toContainText('本站暂无可用的教务助手安装包');
  await expect(page.getByRole('link',{name:/下载教务助手/})).toHaveCount(0);
});
