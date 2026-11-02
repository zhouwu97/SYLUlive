import { test, expect } from '@playwright/test';
import { resolve } from 'node:path';

const route = '**/api/plug/astrbot_plugin_sylulive/permissions/preview';
const statusRoute = '**/api/plug/astrbot_plugin_sylulive/permissions/status';
const output = process.env.SYLULIVE_PERMISSION_EVIDENCE_DIR || resolve('test-results/permissions-evidence');

async function fill(page: any, sender = '900000002') {
  await page.getByLabel('机器人 QQ', { exact: true }).fill('800000001');
  await page.getByLabel('发起人 QQ', { exact: true }).fill(sender);
  await page.getByLabel('群号', { exact: false }).fill('700000001');
}

for (const [width, dark] of [[1440, false], [390, true]] as const) {
  test(`只读权限真实渲染 ${width}px ${dark ? 'dark' : 'light'}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto('/');
    await expect(page.getByText('包内文件摘要一致', { exact: false })).toBeVisible();
    if (dark) await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
    await fill(page);
    await page.getByRole('button', { name: '预览权限', exact: true }).focus();
    await page.keyboard.press('Enter');
    const grades = page.locator('.result-row').filter({ has: page.getByRole('heading', { name: '查询本人成绩', exact: true }) });
    const erke = page.locator('.result-row').filter({ has: page.getByRole('heading', { name: '查询本人二课', exact: true }) });
    await expect(grades.getByText('本机条件通过', { exact: true })).toBeVisible();
    await expect(erke.getByText('缺少本人授权', { exact: true })).toBeVisible();
    await expect(page.getByText('本机访问凭据已到期', { exact: false })).toBeVisible();
    await expect(page.getByRole('button', { name: /保存|确认授权|发布/ })).toHaveCount(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBeTruthy();
    await page.screenshot({ path: `${output}/permissions-${width}-${dark ? 'dark' : 'light'}.png`, fullPage: true });
    if (width === 390) {
      await page.evaluate(() => { document.body.style.zoom = '1.3'; });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBeTruthy();
      await page.screenshot({ path: `${output}/permissions-large-text.png`, fullPage: true });
    }
  });
}

test('状态加载失败可重试，编辑表单不阻断状态返回', async ({ page }) => {
  let first = true;
  await page.route(statusRoute, async r => {
    if (first) { first = false; await r.abort(); } else await r.continue();
  });
  await page.goto('/');
  await expect(page.getByRole('alert')).toContainText('暂时无法读取插件状态');
  await page.getByRole('button', { name: '刷新状态', exact: true }).click();
  await page.getByLabel('发起人 QQ', { exact: true }).fill('900000003');
  await expect(page.getByText('包内文件摘要一致', { exact: false })).toBeVisible();
  await expect(page.getByRole('alert')).toBeHidden();
});

test('旧账号的迟到响应不能覆盖新输入与新结果', async ({ page }) => {
  let release!: () => void;
  const held = new Promise<void>(resolve => { release = resolve; });
  let waiting!: () => void;
  const entered = new Promise<void>(resolve => { waiting = resolve; });
  await page.route(route, async r => {
    if (r.request().postDataJSON().sender_id === '900000002') { waiting(); await held; }
    await r.continue();
  });
  await page.goto('/');
  await expect(page.getByText('包内文件摘要一致', { exact: false })).toBeVisible();
  await fill(page);
  await page.getByRole('button', { name: '预览权限', exact: true }).click();
  await entered;
  await page.getByLabel('发起人 QQ', { exact: true }).fill('900000003');
  await page.getByRole('button', { name: '预览权限', exact: true }).click();
  const grades = page.locator('.result-row').filter({ has: page.getByRole('heading', { name: '查询本人成绩', exact: true }) });
  await expect(grades.getByText('缺少本人授权', { exact: true })).toBeVisible();
  const late = page.waitForResponse(r => r.url().endsWith('/permissions/preview') && r.request().postDataJSON().sender_id === '900000002');
  release(); await late;
  await expect(grades.getByText('缺少本人授权', { exact: true })).toBeVisible();
  await expect(page.getByLabel('发起人 QQ', { exact: true })).toHaveValue('900000003');
});

test('失败响应不回显正文，重试后按文本展示规则名称', async ({ page }) => {
  let first = true;
  await page.route(route, async r => {
    if (first) { first = false; await r.fulfill({ status: 500, body: 'SYNTHETIC-SECRET-MUST-NOT-SHOW' }); return; }
    const response = await r.fetch();
    const result = await response.json();
    result.items[0].rule.name = '<img src=x onerror="window.unwanted=true">';
    await r.fulfill({ response, json: result });
  });
  await page.goto('/');
  await expect(page.getByText('包内文件摘要一致', { exact: false })).toBeVisible();
  await fill(page);
  await page.getByRole('button', { name: '预览权限', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('未能取得判断');
  await expect(page.getByText('SYNTHETIC-SECRET-MUST-NOT-SHOW')).toHaveCount(0);
  await page.getByRole('button', { name: '预览权限', exact: true }).click();
  await expect(page.getByText('<img src=x onerror="window.unwanted=true">', { exact: false })).toBeVisible();
  await expect(page.locator('.result-row img')).toHaveCount(0);
});
