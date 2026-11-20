import {test, expect} from '@playwright/test';

for (const width of [1440, 390]) {
  for (const theme of ['light', 'dark']) {
    test(`首页骨架占满信息流，加载失败可重试 ${width} ${theme}`, async ({page}, info) => {
      await page.setViewportSize({width, height: 1000});
      await page.addInitScript(value => localStorage.setItem('sylulive-theme', value), theme);
      const errors: string[] = [];
      page.on('pageerror', error => errors.push(error.message));
      let mode = 'error';
      let release!: () => void;
      const pending = new Promise<void>(resolve => {release = resolve;});
      await page.route('**/api/**', async route => {
        const url = new URL(route.request().url());
        if (url.pathname === '/api/user/profile') return route.fulfill({json: {id: 7, nickname: '加载测试同学', role: 'user'}});
        if (url.pathname === '/api/posts' && url.searchParams.get('sort') === 'all') {
          await pending;
          if (mode === 'error') return route.fulfill({status: 503, json: {message: '测试读取失败'}});
          return route.fulfill({json: {posts: mode === 'empty' ? [] : [{id: 45, board_id: 1, title: '加载完成的校园动态', content: '合成测试内容', author_id: 8, author: {id: 8, nickname: '测试作者'}, created_at: '2026-11-13T08:00:00Z'}], has_more: false}});
        }
        return route.fulfill({json: {items: []}});
      });
      await page.goto('./');
      const feed = page.locator('.dashboard-feed');
      const skeleton = feed.getByRole('status');
      await expect(skeleton).toBeVisible();
      await expect(skeleton).toHaveCSS('opacity', '1');
      await expect(skeleton).toContainText('正在加载');
      await expect(skeleton.locator('.skeleton-card')).toHaveCount(3);
      const feedBox = await feed.boundingBox();
      const cards = await skeleton.locator('.skeleton-card').evaluateAll(items => items.map(item => {
        const bounds = item.getBoundingClientRect();
        return {x: bounds.x, width: bounds.width};
      }));
      for (const card of cards) {
        expect(Math.abs(card.x - feedBox!.x)).toBeLessThan(2);
        expect(Math.abs(card.width - feedBox!.width)).toBeLessThan(2);
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await skeleton.screenshot({path: info.outputPath('skeleton-only.png')});
      await page.screenshot({path: info.outputPath('feed-loading.png')});
      await page.emulateMedia({reducedMotion: 'reduce'});
      expect(await skeleton.locator('.skeleton-block').first().evaluate(element =>
        element.getAnimations({subtree: true}).every(animation => animation.playState !== 'running'))).toBe(true);
      release();
      await expect(feed.getByRole('heading', {name: '加载未完成'})).toBeVisible();
      await expect(feed.locator('.skeleton-card')).toHaveCount(0);
      mode = 'ready';
      await feed.getByRole('button', {name: '重试', exact: true}).click();
      await expect(feed).toContainText('加载完成的校园动态');
      await expect(feed.locator('.skeleton-card')).toHaveCount(0);
      mode = 'empty';
      await page.reload();
      await expect(feed.getByRole('heading', {name: width > 600 ? '暂时没有新的校园动态' : '暂时没有帖子'})).toBeVisible();
      expect(errors).toEqual([]);
    });
  }
}
