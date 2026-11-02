import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  await page.route('**/api/**', route => route.fulfill({ json: { items: [] } }));
  await page.route('**/api/user/profile', route => route.fulfill({ json: { id: 991, nickname: '界面验收同学', role: 'user' } }));
});

test('社区广场全模块在深浅色桌面与手机下保留可见操作和阅读边界', async ({ page }) => {
  test.setTimeout(90000);
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  for (const theme of ['light', 'dark']) {
    await page.addInitScript(value => localStorage.setItem('sylulive-theme', value), theme);
    for (const width of [390, 1440]) {
      await page.setViewportSize({ width, height: 1000 });
      for (const route of ['./', 'community', 'market', 'schedule', 'grades', 'exams', 'campus', 'canteen', 'competition', 'ratings', 'polls', 'ai', 'toolbox', 'feedback', 'profile', 'messages', 'notifications', 'admin']) {
        await page.goto(route);
        await expect(page.locator('#mainContent')).toBeVisible();
        await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
        const layout = await page.locator('#mainContent').evaluate(el => {
          const box = el.getBoundingClientRect();
          return { viewport: document.documentElement.scrollWidth <= innerWidth, content: el.scrollWidth <= el.clientWidth + 1, left: box.left, right: box.right };
        });
        expect(layout.viewport, `${theme} ${width} ${route} document`).toBe(true);
        expect(layout.content, `${theme} ${width} ${route} workspace`).toBe(true);
        expect(layout.left).toBeGreaterThanOrEqual(0);
        expect(layout.right).toBeLessThanOrEqual(width + 1);
        if (route === 'ai') {
          const composer = page.locator('.ai-input');
          const send = composer.getByRole('button', { name: '发送', exact: true });
          await expect(send).toBeVisible();
          const bounds = await send.evaluate(el => {
            const button = el.getBoundingClientRect(), shell = el.closest('.ai-shell')!.getBoundingClientRect();
            return { bottom: button.bottom, shellBottom: shell.bottom, right: button.right, shellRight: shell.right };
          });
          expect(bounds.bottom, `${theme} ${width} composer action not clipped`).toBeLessThanOrEqual(bounds.shellBottom);
          expect(bounds.right).toBeLessThanOrEqual(bounds.shellRight);
        }
        if (['./', 'schedule', 'grades', 'ai', 'campus', 'canteen', 'competition', 'toolbox', 'profile'].includes(route)) {
          await page.screenshot({ path: `artifacts/commons-ui-2026-11-02/${theme}-${width}-${route === './' ? 'home' : route}.png` });
        }
      }
    }
  }
  expect(errors).toEqual([]);
});

test('首页动态加载、失败、重试和空状态，以及游客发布登录入口', async ({ page }) => {
  await page.route('**/api/user/profile', route => route.fulfill({ status: 401, json: { message: '未登录' } }));
  await page.route('**/api/refresh', route => route.fulfill({ status: 401, json: { message: '未登录' } }));
  let failed = true;
  let release: () => void = () => {};
  const gate = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/api/posts?**', async route => {
    await gate;
    return failed ? route.fulfill({ status: 503, json: { message: '测试服务暂不可用' } }) : route.fulfill({ json: { posts: [] } });
  });
  await page.goto('./');
  await expect(page.locator('.dashboard-feed')).toContainText('正在加载');
  release();
  await expect(page.locator('.dashboard-feed')).toContainText('加载未完成', { timeout: 15000 });
  failed = false;
  await page.locator('.dashboard-feed').getByRole('button', { name: '重试', exact: true }).click();
  await expect(page.locator('.dashboard-feed .empty-state')).toBeVisible();
  await page.getByRole('button', { name: '分享校园日常', exact: true }).click();
  await expect(page.getByRole('dialog', { name: '登录沈理校园', exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('button', { name: '分享校园日常', exact: true })).toBeFocused();
});
