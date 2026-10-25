import {test, expect, type Page} from '@playwright/test';

const image = '/uploads/ui-polish-photo.svg';
const broken = '/uploads/ui-polish-missing.svg';
const author = {id: 78, nickname: '布局验证用户', avatar: image, followers_count: 2, following_count: 3, total_likes_received: 4};
const photo = {id: 1, medium_url: image, viewer_url: image, file: {path: image, width: 900, height: 600}};
const post = {id: 123, author_id: author.id, author, board_id: 1, content: '只有这一段正文，不应重复生成标题。', images: [photo], like_count: 2, reply_count: 0};

async function setup(page: Page) {
  await page.route('**/uploads/ui-polish-*.svg', route => route.request().url().includes('missing')
    ? route.fulfill({status: 404, body: ''})
    : route.fulfill({contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="600"><rect width="900" height="600" fill="#d5ede8"/></svg>'}));
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (['/api/user/profile', '/api/refresh'].includes(path)) return route.fulfill({status: 401, json: {error: '请登录'}});
    if (path === '/api/posts/123') return route.fulfill({json: post});
    if (path === '/api/user/78') return route.fulfill({json: author});
    if (path.endsWith('/replies')) return route.fulfill({json: {replies: []}});
    if (path === '/api/posts' || path.endsWith('/posts')) return route.fulfill({json: {posts: [post], has_more: false}});
    return route.fulfill({json: {items: []}});
  });
}

test.beforeEach(async ({page}) => setup(page));

test('手机首屏保留阅读空间，服务器头像和单图完整显示', async ({page}) => {
  await page.setViewportSize({width: 390, height: 844});
  await page.goto('community');
  const card = page.locator('.feed-card').first();
  await expect(card.locator('.author-avatar img')).toHaveAttribute('src', image);
  await expect(card.locator('.post-title')).toHaveCount(0);
  await expect(card.locator('.post-body')).toHaveText(post.content);
  const box = await card.boundingBox();
  expect(box!.y).toBeLessThan(290);
  const media = await card.locator('.media-tile').boundingBox();
  expect(media!.width).toBeGreaterThan(300);
  const fit = await card.locator('.media-tile img').evaluate(img => getComputedStyle(img).objectFit);
  expect(fit).toBe('contain');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBeTruthy();
  await card.locator('.media-tile').click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByRole('link', {name: '查看原图'})).toHaveAttribute('href', image);
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(card.locator('.media-tile')).toBeFocused();
});

test('桌面单图足够大，预览失败时回退原图', async ({page}) => {
  await page.route('**/api/posts?**', route => route.fulfill({json: {posts: [{...post, images: [{...photo, medium_url: broken}]}]}}));
  await page.goto('community');
  const media = page.locator('.media-tile').first();
  await expect(media.locator('img')).toHaveAttribute('src', image);
  await expect(media.locator('.server-image')).toHaveClass(/is-loaded/);
  expect((await media.boundingBox())!.width).toBeGreaterThan(450);
});

test('图片完全失败有明确状态，头像缺失回退昵称', async ({page}) => {
  await page.route('**/api/posts?**', route => route.fulfill({json: {posts: [{...post, author: {...author, avatar: broken}, images: [{id: 4, url: broken}]}]}}));
  await page.goto('community');
  const card = page.locator('.feed-card').first();
  await expect(card.locator('.author-avatar')).toHaveText('布');
  await expect(card.locator('.media-tile')).toContainText('图片暂时无法显示');
  await card.locator('.media-tile').click();
  await expect(page.getByRole('button', {name: '重新加载'})).toBeVisible();
});

test('多图数量和方向键预览，详情阅读宽度有限制', async ({page}) => {
  const images = Array.from({length: 3}, (_, i) => ({...photo, id: i + 1}));
  await page.route('**/api/posts/123', route => route.fulfill({json: {...post, images}}));
  await page.goto('post/123');
  await expect(page.locator('.post-media .media-tile')).toHaveCount(3);
  expect((await page.locator('.post-full').boundingBox())!.width).toBeLessThanOrEqual(920);
  await page.locator('.media-tile').first().click();
  await expect(page.locator('.photo-toolbar > span')).toHaveText('1 / 3');
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('.photo-toolbar > span')).toHaveText('2 / 3');
  await page.getByRole('button', {name: '关闭', exact: true}).click();
  await page.getByRole('link', {name: '查看布局验证用户的主页'}).click();
  await expect(page.locator('.profile-head h2')).toHaveText(author.nickname);
  await expect(page.locator('.profile-stats')).toContainText('2');
});

test('加载、空数据、错误重试和登录状态不出现假内容', async ({page}) => {
  let resolve: (() => void) | undefined;
  await page.route('**/api/posts?**', async route => {
    await new Promise<void>(done => {resolve = done;});
    await route.fulfill({status: 503, json: {error: '测试服务暂不可用'}});
  });
  await page.goto('community');
  await expect(page.getByRole('status').filter({hasText: '正在加载'})).toBeVisible();
  resolve!();
  await expect(page.getByText('测试服务暂不可用')).toBeVisible();
  await page.unroute('**/api/posts?**');
  await page.route('**/api/posts?**', route => route.fulfill({json: {posts: [], has_more: false}}));
  await page.getByRole('button', {name: '重试', exact: true}).click();
  await expect(page.getByRole('heading', {name: '暂无内容'})).toBeVisible();
  await expect(page.locator('.feed-card')).toHaveCount(0);
  await page.getByRole('tab', {name: '我的发布'}).click();
  await expect(page.getByRole('heading', {name: '登录后查看这里的内容'})).toBeVisible();
  await expect(page.getByText('正在加载…')).toHaveCount(0);
});

test('手机导航接管键盘焦点，关闭后回到入口', async ({page}) => {
  await page.setViewportSize({width: 390, height: 844});
  await page.goto('community');
  const toggle = page.getByRole('button', {name: '打开导航'});
  await toggle.click();
  const nav = page.getByRole('dialog', {name: '主导航'});
  await expect(nav.getByRole('link', {name: '校园工作台', exact: true})).toBeFocused();
  for (let i = 0; i < 20; i++) {
    await page.keyboard.press('Tab');
    expect(await nav.evaluate(el => el.contains(document.activeElement))).toBeTruthy();
  }
  await page.keyboard.press('Escape');
  await expect(toggle).toBeFocused();
  await expect(page.locator('#primaryNavigation')).toHaveAttribute('inert', '');
  await toggle.click();
  await page.getByRole('button', {name: '关闭导航'}).click();
  await expect(toggle).toBeFocused();
  await toggle.click();
  await page.keyboard.press('Control+k');
  const search = page.getByRole('dialog', {name: '搜索功能'});
  await expect(search).toBeVisible();
  await expect(page.locator('#primaryNavigation')).toHaveAttribute('inert', '');
  await page.keyboard.press('Tab');
  expect(await search.evaluate(el => el.contains(document.activeElement))).toBeTruthy();
});
