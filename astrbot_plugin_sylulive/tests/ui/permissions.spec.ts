import { test, expect, Page } from '@playwright/test';
import { resolve } from 'node:path';

const policyRoute = '**/api/plug/astrbot_plugin_sylulive/permissions/policy';
const previewRoute = '**/api/plug/astrbot_plugin_sylulive/permissions/preview';
const output = process.env.SYLULIVE_PERMISSION_EVIDENCE_DIR || resolve('test-results/permissions-evidence');

test.beforeEach(async ({ request }) => { await request.post('/lab/reset'); });

async function open(page: Page) {
  await page.goto('/');
  await expect(page.locator('#save-state')).toHaveText('已保存');
}

test('部署者可找到网站接入教程且不把配置权限当账号授权', async ({ page }) => {
  await open(page);
  const guide = page.getByRole('link', { name: '接入 AstrBot 教程', exact: true });
  await expect(guide).toBeVisible();
  await expect(guide).toHaveAttribute('href', 'https://sylulive.online/web/connected-apps?guide=astrbot');
  await expect(guide).toHaveAttribute('rel', 'noopener noreferrer');
  await expect(page.getByText('网站连接和机器人启用与本页规则分别管理。', { exact: true })).toBeVisible();
});

test('教程入口拒绝异常目标且保留正常配置读取', async ({ page }) => {
  await page.route(policyRoute, async route => {
    const response = await route.fetch();
    const data = await response.json();
    await route.fulfill({ response, json: { ...data, guide_url: 'javascript:alert(1)' } });
  });
  await open(page);
  await expect(page.getByRole('link', { name: '接入 AstrBot 教程', exact: true })).toHaveCount(0);
  await expect(page.locator('#policy-editor')).toBeEnabled();
});

async function newRule(page: Page, name = '限制指定用户公开查询') {
  await page.getByRole('button', { name: '新增规则', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: '新增规则', exact: true });
  await dialog.getByLabel('规则名称', { exact: true }).fill(name);
  await dialog.getByLabel('规则效果').selectOption('deny');
  await dialog.getByLabel('适用对象', { exact: true }).selectOption('specified_users');
  await dialog.getByLabel('限定用户 QQ').fill('900000003');
  await dialog.getByLabel('限定群号').fill('700000001');
  await dialog.getByLabel('公开校园查询', { exact: true }).check();
  return dialog;
}

async function target(page: Page, sender = '900000002') {
  await page.getByRole('button', { name: '权限检查', exact: true }).click();
  await page.getByLabel('机器人 QQ', { exact: true }).fill('800000001');
  await page.getByLabel('发起人 QQ', { exact: true }).fill(sender);
  await page.locator('#group').fill('700000001');
}

test('规则新增编辑启停删除确实保存并可重新加载', async ({ page }) => {
  await open(page);
  const dialog = await newRule(page);
  await dialog.getByRole('button', { name: '应用到待保存修改' }).click();
  await expect(page.locator('#save-state')).toHaveText('有未保存修改');
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.reload();
  await expect(page.getByText('限制指定用户公开查询', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: '编辑规则：限制指定用户公开查询', exact: true }).click();
  await page.getByLabel('规则名称', { exact: true }).fill('更新后的禁止规则');
  await page.getByRole('button', { name: '应用到待保存修改' }).click();
  await page.getByLabel('启用规则：更新后的禁止规则', { exact: true }).uncheck();
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.reload();
  await expect(page.getByLabel('启用规则：更新后的禁止规则', { exact: true })).not.toBeChecked();
  await page.getByRole('button', { name: '删除规则：更新后的禁止规则', exact: true }).click();
  await page.getByRole('dialog', { name: '删除规则', exact: true }).getByRole('button', { name: '确认', exact: true }).click();
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.reload();
  await expect(page.getByText('更新后的禁止规则', { exact: true })).toHaveCount(0);
});

test('功能投递设置持久化，取消和放弃修改不写入', async ({ page }) => {
  await open(page);
  await newRule(page, '取消的规则');
  await page.getByRole('dialog').getByRole('button', { name: '取消', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.getByRole('button', { name: '功能与范围', exact: true }).click();
  await page.locator('[data-setting=allow_checkin]').check();
  await page.getByLabel('群内个人查询结果', { exact: true }).selectOption('private');
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.reload();
  await page.getByRole('button', { name: '功能与范围', exact: true }).click();
  await expect(page.locator('[data-setting=allow_checkin]')).toBeChecked();
  await expect(page.getByLabel('群内个人查询结果', { exact: true })).toHaveValue('private');
  await page.locator('[data-setting=allow_checkin]').uncheck();
  await page.getByRole('button', { name: '放弃修改', exact: true }).click();
  await expect(page.locator('[data-setting=allow_checkin]')).toBeChecked();
  await expect(page.getByRole('button', { name: '保存更改', exact: true })).toBeDisabled();
});

test('删除最后一条规则有空态，取消删除不丢规则', async ({ page }) => {
  await open(page);
  const remove = page.getByRole('button', { name: '删除规则：合成本人查询', exact: true });
  await remove.click();
  await page.getByRole('dialog').getByRole('button', { name: '取消', exact: true }).click();
  await expect(remove).toBeVisible();
  await remove.click();
  await page.getByRole('dialog').getByRole('button', { name: '确认', exact: true }).click();
  await expect(page.locator('#rules-empty')).toContainText('尚无权限规则');
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.reload();
  await expect(page.locator('#rules-empty')).toContainText('尚无权限规则');
  await expect(page.getByRole('button', { name: '新增规则', exact: true })).toBeEnabled();
});

test('未保存规则可检查但不生效；指定用户不可省略', async ({ page }) => {
  await open(page);
  const dialog = await newRule(page);
  await dialog.getByLabel('限定用户 QQ').fill('');
  await dialog.getByRole('button', { name: '应用到待保存修改' }).click();
  await expect(dialog.locator('#rule-error')).toBeVisible();
  await dialog.getByLabel('限定用户 QQ').fill('900000003');
  await dialog.getByRole('button', { name: '应用到待保存修改' }).click();
  await target(page, '900000003');
  await page.getByRole('button', { name: '检查权限', exact: true }).click();
  await expect(page.locator('.result-row').first().getByText('规则拒绝', { exact: true })).toBeVisible();
  expect(await page.evaluate(async () => {
    const data = await (await fetch('/api/plug/astrbot_plugin_sylulive/permissions/policy')).json();
    return data.policy.access_rules.length;
  })).toBe(1);
});

test('其他窗口已保存时拒绝覆盖并保留草稿', async ({ page, context }) => {
  await open(page);
  const other = await context.newPage();
  await open(other);
  for (const p of [page, other]) await p.getByRole('button', { name: '功能与范围', exact: true }).click();
  await page.locator('[data-setting=allow_checkin]').check();
  await other.locator('[data-setting=allow_personal_queries]').uncheck();
  await other.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(other.locator('#save-state')).toHaveText('已保存');
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#global-error')).toContainText('配置已在其他位置修改');
  await expect(page.locator('[data-setting=allow_checkin]')).toBeChecked();
  await expect(page.getByRole('button', { name: '保存更改', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: '重新读取', exact: true }).click();
  await page.getByRole('dialog').getByRole('button', { name: '确认', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await expect(page.locator('[data-setting=allow_checkin]')).not.toBeChecked();
  await expect(page.locator('[data-setting=allow_personal_queries]')).not.toBeChecked();
});

test('保存回包丢失后读回核对，不重复提交；未写入时保留草稿', async ({ page }) => {
  let count = 0, commit = true;
  await page.route(policyRoute, async r => {
    if (r.request().method() !== 'POST') return r.continue();
    count++;
    if (commit) await r.fetch();
    await r.abort();
  });
  await open(page);
  await page.getByRole('button', { name: '功能与范围', exact: true }).click();
  await page.locator('[data-setting=allow_checkin]').check();
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  expect(count).toBe(1);
  commit = false;
  await page.locator('[data-setting=allow_checkin]').uncheck();
  await page.getByRole('button', { name: '保存更改', exact: true }).click();
  await expect(page.locator('#global-error')).toContainText('保存结果未确认');
  await expect(page.getByRole('button', { name: '保存更改', exact: true })).toBeDisabled();
  await expect(page.locator('[data-setting=allow_checkin]')).not.toBeChecked();
  expect(count).toBe(2);
});

test('读取失败可重试，筛选空态可恢复，错误正文不展示', async ({ page }) => {
  let first = true;
  await page.route(policyRoute, async r => {
    if (first) { first = false; return r.fulfill({ status: 500, body: 'SYNTHETIC-SECRET-MUST-NOT-SHOW' }); }
    await r.continue();
  });
  await page.goto('/');
  await expect(page.locator('#global-error')).toContainText('权限配置读取失败');
  await expect(page.getByRole('button', { name: '新增规则', exact: true })).toBeDisabled();
  await expect(page.getByText('SYNTHETIC-SECRET-MUST-NOT-SHOW')).toHaveCount(0);
  await page.getByRole('button', { name: '重新读取', exact: true }).click();
  await expect(page.locator('#save-state')).toHaveText('已保存');
  await page.getByLabel('搜索规则', { exact: false }).fill('不存在的规则');
  await expect(page.locator('#rules-empty')).toContainText('没有匹配的规则');
  await page.getByLabel('搜索规则', { exact: false }).fill('');
  await expect(page.getByText('合成本人查询', { exact: true })).toBeVisible();
});

test('旧账号迟到响应不能覆盖新账号结果，规则名称只显示文本', async ({ page }) => {
  let release!: () => void, entered!: () => void;
  const held = new Promise<void>(r => { release = r; });
  const waiting = new Promise<void>(r => { entered = r; });
  await page.route(previewRoute, async r => {
    if (r.request().postDataJSON().sender_id === '900000002') { entered(); await held; }
    const response = await r.fetch();
    const result = await response.json();
    result.items[0].rule.name = '<img src=x onerror="window.unwanted=true">';
    await r.fulfill({ response, json: result });
  });
  await open(page);
  await target(page);
  await page.getByRole('button', { name: '检查权限', exact: true }).click();
  await waiting;
  await page.getByLabel('发起人 QQ', { exact: true }).fill('900000003');
  await page.getByRole('button', { name: '检查权限', exact: true }).click();
  const grades = page.locator('.result-row').filter({ has: page.getByRole('heading', { name: '查询本人成绩', exact: true }) });
  await expect(grades.getByText('缺少本人授权', { exact: true })).toBeVisible();
  const late = page.waitForResponse(r => r.url().endsWith('/permissions/preview') && r.request().postDataJSON().sender_id === '900000002');
  release(); await late;
  await expect(grades.getByText('缺少本人授权', { exact: true })).toBeVisible();
  await expect(page.locator('.result-row img')).toHaveCount(0);
  await expect(page.getByText('<img src=x onerror="window.unwanted=true">', { exact: false })).toBeVisible();
});

for (const [width, dark] of [[1440, false], [390, true]] as const) {
  test(`权限管理真实渲染 ${width}px ${dark ? 'dark' : 'light'}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 980 });
    await open(page);
    if (dark) await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
    await expect(page.getByRole('heading', { name: '权限管理', exact: true })).toBeVisible();
    expect(await page.locator('body').innerText()).not.toMatch(/大肥鱼|人格|运行状态|记忆状态/);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBeTruthy();
    await page.screenshot({ path: `${output}/permissions-${width}-${dark ? 'dark' : 'light'}.png`, fullPage: true });
    await page.getByRole('button', { name: '新增规则', exact: true }).focus();
    await page.keyboard.press('Enter');
    await expect(page.getByLabel('规则名称', { exact: true })).toBeFocused();
    await page.screenshot({ path: `${output}/rule-editor-${width}.png`, fullPage: true });
    await page.keyboard.press('Escape');
    await expect(page.getByRole('dialog')).not.toBeVisible();
    await page.getByRole('button', { name: '功能与范围', exact: true }).click();
    if (width === 390) await page.evaluate(() => { document.body.style.zoom = '1.3'; });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBeTruthy();
    await page.screenshot({ path: `${output}/settings-${width}.png`, fullPage: true });
  });
}
