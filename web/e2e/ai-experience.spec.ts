import { expect, test } from '@playwright/test';

for (const width of [1440, 390]) {
  test(`校园助手已从网页入口移除（${width}px）`, async ({ page }, testInfo) => {
    const assistantRequests: string[] = [];
    const errors: string[] = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
    await page.route('**/api/**', route => route.fulfill({ json: { items: [] } }));
    await page.route('**/api/user/profile', route => route.fulfill({
      json: { id: 991, nickname: '验收同学', role: 'user' },
    }));
    await page.route('**/api/ai/**', route => {
      assistantRequests.push(new URL(route.request().url()).pathname);
      return route.fulfill({ json: { enabled: true, chat_enabled: true, access_allowed: true } });
    });

    await page.goto('ai');
    await expect(page).toHaveURL(/\/web\/campus$/);
    await expect(page.getByRole('heading', { name: '校园', exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: '食堂', exact: true }).first()).toBeVisible();
    await expect(page.locator('a[href="/web/ai"]')).toHaveCount(0);
    await expect(page.getByText(/校园 Agent|AI 校园助手|分析我的成绩摘要/)).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath(`campus-${width}.png`) });

    await page.keyboard.press('Control+k');
    await page.getByRole('textbox', { name: '搜索功能' }).fill('AI');
    await expect(page.locator('.palette-result')).toHaveCount(0);
    await page.getByRole('textbox', { name: '搜索功能' }).fill('课表');
    await expect(page.getByRole('button', { name: '课表', exact: true })).toBeVisible();
    expect(assistantRequests).toEqual([]);
    expect(errors).toEqual([]);
  });
}

test('历史校园助手书签打开校园页', async ({ page }) => {
  await page.route('**/api/**', route => route.fulfill({ json: { items: [] } }));
  await page.goto('./#ai');
  await expect(page).toHaveURL(/\/web\/campus$/);
  await expect(page.getByRole('navigation', { name: '校园服务入口' })).toBeVisible();
});
