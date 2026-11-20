import {test, expect, type Page} from '@playwright/test';

async function fixture(page: Page, role = 'super_admin') {
  let state = 'ready';
  const requests: string[] = [];
  await page.route('**/api/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/api/user/profile') return route.fulfill({json: {id: 900, nickname: '合成管理员', role}});
    if (url.pathname === '/api/super/users') {
      requests.push(url.search);
      if (state === 'error') return route.fulfill({status: 503, json: {error: '读取失败'}});
      if (url.searchParams.get('kind') !== 'ai') return route.fulfill({json: [{id: 7, nickname: '创建者', role: 'user'}]});
      return route.fulfill({json: state === 'empty' ? [] : [{id: 'AI-example', name: '小鱼', owner_id: 7, owner_name: '创建者', enabled: true}]});
    }
    return route.fulfill({json: {items: []}});
  });
  return {requests, setState(value: string) {state = value;}};
}

test('AI 独立入口、搜索、失败恢复和窄屏渲染', async ({page}) => {
  const f = await fixture(page);
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/web/admin?tab=bots');
  await expect(page.getByRole('complementary', {name: '管理模块'}).getByRole('link', {name: '所属 AI', exact: true})).toHaveAttribute('aria-current', 'page');
  await expect(page.getByText('小鱼', {exact: true})).toBeVisible();
  await expect(page.getByText(/AI-example · 归属于 创建者/)).toBeVisible();
  await expect(page.getByText('用户所属 AI', {exact: true})).toBeVisible();
  await expect(page.getByText('诚信分', {exact: false})).toHaveCount(0);
  await page.getByRole('textbox', {name: '搜索 AI 或创建者'}).fill('小鱼');
  await page.getByRole('button', {name: '搜索', exact: true}).click();
  await expect.poll(() => f.requests.some(value => new URLSearchParams(value).get('search') === '小鱼')).toBe(true);
  f.setState('error');
  await page.getByRole('button', {name: '刷新', exact: true}).click();
  await expect(page.getByRole('button', {name: '重试', exact: true})).toBeVisible();
  f.setState('empty');
  await page.getByRole('button', {name: '重试', exact: true}).click();
  await expect(page.getByText('暂无记录', {exact: true})).toBeVisible();
  f.setState('ready');
  await page.getByRole('button', {name: '刷新', exact: true}).click();
  await expect(page.getByText('小鱼', {exact: true})).toBeVisible();
  await page.setViewportSize({width: 390, height: 844});
  const activeTab = page.getByRole('tab', {name: '所属 AI', exact: true});
  await expect(activeTab).toBeInViewport({ratio: 1});
  await expect.poll(() => activeTab.evaluate(element => {
    const bounds = element.getBoundingClientRect();
    return element.contains(document.elementFromPoint(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2));
  })).toBe(true);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({path: test.info().outputPath('所属AI-手机.png')});
  expect(errors).toEqual([]);
});

test('普通管理员无法读取所属 AI 超管数据', async ({page}) => {
  const f = await fixture(page, 'admin');
  await page.goto('/web/admin?tab=bots');
  await expect(page.getByRole('heading', {name: '此模块需要超级管理员权限'})).toBeVisible();
  await expect(page.getByRole('complementary', {name: '管理模块'}).getByRole('link', {name: '所属 AI', exact: true})).toHaveCount(0);
  expect(f.requests).toEqual([]);
  await page.setViewportSize({width: 390, height: 844});
  await expect(page.getByRole('heading', {name: '此模块需要超级管理员权限'})).toBeVisible();
  await expect(page.getByRole('tab', {name: '所属 AI', exact: true})).toHaveCount(0);
  expect(f.requests).toEqual([]);
});
