import { test, expect, type Page } from '@playwright/test';

const portrait = '<svg xmlns="http://www.w3.org/2000/svg" width="360" height="640"><rect width="360" height="640" fill="#c7d9ee"/><circle cx="250" cy="140" r="65" fill="#fff1ce"/><path d="M0 430L160 240L360 460V640H0Z" fill="#8aa5a0"/><path d="M0 540L240 390L360 490V640H0Z" fill="#526d70"/></svg>';
const person = { id: 991, nickname: '纯合子', role: 'user', exp: 5432, bio: '把普通日子记得认真一点。', total_likes_received: 142, following_count: 1, followers_count: 22, background: '/uploads/profile-portrait.svg' };

async function setup(page: Page, user: Record<string, unknown> | null = person) {
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/user/profile') return route.fulfill({ status: user ? 200 : 401, json: user || { message: '未登录' } });
    if (path === '/api/refresh') return route.fulfill({ status: 401, json: { message: '未登录' } });
    if (path === '/api/user/991/posts') return route.fulfill({ json: { posts: [{ id: 301, title: '把校园日常留在这里', content: '今天路过图书馆，顺手记录下校园里的好天气。', created_at: '2026-11-04T08:00:00+08:00', author: person, author_id: 991, like_count: 15, reply_count: 2 }] } });
    return route.fulfill({ json: { items: [] } });
  });
  await page.route('**/uploads/profile-portrait.svg', route => route.fulfill({ contentType: 'image/svg+xml', body: portrait }));
}
// 头部同时有模糊铺底图（aria-hidden，alt 为空），只按可访问名称取完整封面。

test('个人主页头部整图展示封面，资料与操作同行，工具与内容在下方居中排布', async ({ page }) => {
  await setup(page);
  for (const width of [1920, 1440, 1040, 800, 680, 601]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto('profile');
    await expect(page.getByRole('heading', { name: '纯合子', exact: true })).toBeVisible();
    await expect(page.getByRole('complementary', { name: '主导航', exact: true })).toHaveCount(0);
    await expect(page.locator('.topbar')).toBeVisible();
    await expect(page.getByLabel('等级 7', { exact: true })).toHaveText('Lv.7');
    await expect(page.locator('.profile-description')).toHaveText(person.bio);
    await expect(page.locator('.profile-social')).toContainText('142获赞');
    await expect(page.locator('.profile-content-region')).toContainText('把校园日常留在这里');
    const image = page.getByRole('img', { name: '个人封面', exact: true });
    await expect(image).toBeVisible();
    const bounds = await image.boundingBox();
    expect(bounds!.width / bounds!.height).toBeCloseTo(360 / 640, 2);
    expect(bounds!.height).toBeLessThanOrEqual(520);
    const card = await page.locator('.profile-card').boundingBox();
    const coverBox = await page.locator('.profile-cover-wrap').boundingBox();
    const body = await page.locator('.profile-card-body').boundingBox();
    const avatar = await page.locator('.profile-avatar').boundingBox();
    const layout = await page.locator('.profile-layout').boundingBox();
    const content = await page.locator('.profile-content').boundingBox();
    const tools = await page.locator('.profile-tools').boundingBox();
    // 封面整图居中显示在头部，不裁切；头像压住封面下沿
    expect(bounds!.y).toBeGreaterThanOrEqual(coverBox!.y - 1);
    expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(coverBox!.y + coverBox!.height + 1);
    expect(body!.y).toBeGreaterThanOrEqual(coverBox!.y + coverBox!.height - 1);
    expect(avatar!.y).toBeLessThan(coverBox!.y + coverBox!.height);
    expect(avatar!.y + avatar!.height).toBeGreaterThan(coverBox!.y + coverBox!.height);
    // 头部卡片在上，工具与内容在下方
    expect(tools!.y).toBeGreaterThan(card!.y + card!.height);
    expect(content!.y).toBeGreaterThan(card!.y + card!.height);
    expect(Math.abs(card!.x - layout!.x)).toBeLessThan(2);
    if (width > 940) {
      expect(content!.x).toBeGreaterThan(tools!.x + tools!.width);
      expect(Math.abs(content!.y - tools!.y)).toBeLessThan(2);
    } else expect(content!.y).toBeGreaterThan(tools!.y + tools!.height);
    expect(Math.abs(layout!.x - (width - layout!.x - layout!.width))).toBeLessThan(20);
    expect(await page.locator('.profile-content-tabs .tabs').evaluate(tabs => tabs.scrollWidth <= tabs.clientWidth)).toBe(true);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if ([1440, 601].includes(width)) await page.screenshot({ path: `.codex-captures/profile/refined-${width}.png`, fullPage: true });
  }
  await page.getByRole('button', { name: '查看完整封面', exact: true }).click();
  await expect(page.getByRole('dialog', { name: '个人封面', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: '打开原图' })).toHaveAttribute('href', person.background);
  await page.keyboard.press('Escape');
  await page.getByRole('button', { name: '编辑资料与图片' }).click();
  await expect(page.getByRole('dialog', { name: '编辑资料', exact: true })).toBeVisible();
  await expect(page.getByLabel('昵称', { exact: true })).toHaveValue('纯合子');
});

test('封面加载和损坏有明确状态，点击重试后恢复原比例图片', async ({ page }) => {
  await setup(page);
  let release = () => {}, broken = true;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/uploads/profile-portrait.svg', async route => {
    if (broken) { await pending; return route.fulfill({ status: 404, body: '' }); }
    return route.fulfill({ contentType: 'image/svg+xml', body: portrait });
  });
  try {
    await page.goto('profile');
    await expect(page.getByText('正在加载封面…', { exact: true })).toBeVisible();
    release();
    await expect(page.getByRole('button', { name: '完整封面加载失败，点击重试', exact: true })).toBeVisible();
    broken = false;
    await page.getByRole('button', { name: '完整封面加载失败，点击重试', exact: true }).click();
    await expect(page.getByRole('button', { name: '查看完整封面', exact: true })).toBeVisible();
    await expect(page.getByText('正在加载封面…', { exact: true })).toHaveCount(0);
  } finally { release(); }
});

test('没有封面和统计时不编造数据，长名字深色下不溢出，空内容与错误可恢复', async ({ page }) => {
  await setup(page, { id: 991, nickname: '很长的校园昵称'.repeat(8), role: 'user', exp: 50 });
  await page.addInitScript(() => localStorage.setItem('sylulive-theme', 'dark'));
  await page.setViewportSize({ width: 800, height: 1000 });
  let fail = true;
  await page.route('**/api/user/991/posts', route => fail ? route.fulfill({ status: 503, json: { message: '内容暂时不可用' } }) : route.fulfill({ json: { posts: [] } }));
  await page.goto('profile');
  await expect(page.getByRole('button', { name: '添加主页封面' })).toBeVisible();
  await expect(page.locator('.profile-social')).toHaveCount(0);
  await expect(page.getByLabel('等级 2', { exact: true })).toBeVisible();
  const identity = await page.locator('.profile-identity').boundingBox();
  // 窄桌面下操作按钮换到第二行；长名字最多两行，头部不随名字无限变高
  expect(identity!.height).toBeLessThan(220);
  await expect(page.locator('.profile-name h2')).toHaveAttribute('title', '很长的校园昵称'.repeat(8));
  await expect(page.getByText('内容暂时不可用', { exact: true })).toBeVisible();
  fail = false;
  await page.getByRole('button', { name: '重试', exact: true }).click();
  await expect(page.getByRole('heading', { name: '还没有发布帖子', exact: true })).toBeVisible();
  await page.getByRole('tab', { name: '我的收藏', exact: true }).focus();
  await page.keyboard.press('End');
  await expect(page.getByRole('tab', { name: '粉丝', exact: true })).toBeFocused();
  await expect(page.getByRole('heading', { name: '还没有粉丝', exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: '.codex-captures/profile/refined-dark-empty.png', fullPage: true });
});

test('长列表标签保持可用，点击个人统计滚回对应内容并转移键盘焦点', async ({ page }) => {
  await setup(page);
  await page.route('**/api/user/991/posts', route => route.fulfill({ json: { posts: Array.from({ length: 12 }, (_, index) => ({ id: 400 + index, title: `校园记录 ${index + 1}`, content: '记录今天的校园日常。'.repeat(5), author: person, author_id: 991, created_at: '2026-11-04T08:00:00+08:00' })) } }));
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto('profile');
  await expect(page.locator('.profile-feed > .feed-card')).toHaveCount(12);
  await expect(page.getByRole('img', { name: '个人封面', exact: true })).toBeVisible();
  await expect.poll(() => page.getByRole('img', { name: '个人封面', exact: true }).evaluate(image => (image as HTMLImageElement).complete)).toBe(true);
  const edit = await page.getByRole('button', { name: '编辑资料与图片' }).boundingBox();
  expect(edit!.y + edit!.height).toBeLessThan(900);
  await page.evaluate(() => scrollTo(0, 650));
  const tabs = await page.locator('.profile-content-tabs').boundingBox();
  const header = await page.locator('.topbar').boundingBox();
  expect(tabs!.y).toBeGreaterThanOrEqual(header!.y + header!.height);
  expect(tabs!.y).toBeLessThan(header!.y + header!.height + 16);
  await page.locator('.profile-social').getByRole('button', { name: /22.*粉丝/ }).click();
  await expect(page.getByRole('tab', { name: '粉丝', exact: true })).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByRole('tabpanel', { name: '粉丝', exact: true })).toBeFocused();
  await expect(page.getByRole('heading', { name: '还没有粉丝', exact: true })).toBeVisible();
  const panel = await page.getByRole('tabpanel', { name: '粉丝', exact: true }).boundingBox();
  expect(panel!.y).toBeGreaterThan(header!.height);
  expect(panel!.y).toBeLessThan(220);
});

test('游客主页保留独立布局与登录入口，返回社区恢复全站导航', async ({ page }) => {
  await setup(page, null);
  await page.goto('profile');
  await expect(page.getByRole('heading', { name: '登录后查看个人主页' })).toBeVisible();
  await expect(page.locator('.sidebar')).toHaveCount(0);
  await page.locator('.empty-state').getByRole('button', { name: '登录', exact: true }).click();
  await expect(page.getByRole('dialog', { name: '登录沈理校园', exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  await page.locator('.desktop-top-nav').getByRole('link', { name: '校园圈', exact: true }).click();
  await expect(page.getByRole('complementary', { name: '主导航', exact: true })).toBeVisible();
});

test('账号切换时旧内容不能覆盖新账号的资料与等级', async ({ page }) => {
  await setup(page);
  let account = 991, release = () => {}, pendingRead = false;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/api/user/profile', route => route.fulfill({ json: account === 991 ? person : { id: 992, nickname: '新的同学', exp: 50, role: 'user' } }));
  await page.route('**/api/user/991/posts', async route => {
    pendingRead = true;
    await pending;
    return route.fulfill({ json: { posts: [{ id: 1, title: '旧账号迟到内容', author: person }] } });
  });
  try {
    await page.goto('profile');
    await expect.poll(() => pendingRead).toBe(true);
    await expect(page.locator('.profile-content-region').getByRole('status')).toBeVisible();
    account = 992;
    await page.evaluate(() => { const channel = new BroadcastChannel('sylulive-auth'); channel.postMessage('changed'); channel.close(); });
    await expect(page.getByRole('heading', { name: '新的同学', exact: true })).toBeVisible();
    release();
    await expect(page.getByLabel('等级 2', { exact: true })).toBeVisible();
    await expect(page.locator('.profile-content-region')).not.toContainText('旧账号迟到内容');
    await expect(page.getByRole('heading', { name: '还没有发布帖子', exact: true })).toBeVisible();
  } finally { release(); }
});
