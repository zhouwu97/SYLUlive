import {expect, test} from '@playwright/test';
import {readFileSync} from 'node:fs';

// 与 Go 校历接口相同的 schema，避免空 items 夹具掩盖字段错位。
const calendar = JSON.parse(readFileSync('client/assets/data/campus_calendar_fallback.json', 'utf8'));

test.beforeEach(async ({page}) => {
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, nickname: '体验验收同学', role: 'user'}}));
});

test('快捷搜索打开即可输入，回车进入结果并关闭弹窗，Escape 恢复焦点', async ({page}) => {
  await page.goto('./');
  const trigger = page.getByRole('button', {name: '搜索功能', exact: true});
  await trigger.click();
  const dialog = page.getByRole('dialog', {name: '搜索功能', exact: true});
  const input = dialog.getByRole('textbox', {name: '搜索功能', exact: true});
  await expect(input).toBeFocused();
  await input.fill('课表');
  await input.press('Enter');
  await expect(page).toHaveURL(/\/schedule$/);
  await expect(dialog).toHaveCount(0);
  await trigger.click();
  await page.keyboard.press('Escape');
  await expect(trigger).toBeFocused();
});

test('快捷搜索方向键可选择结果，无结果时回车不跳转', async ({page}) => {
  await page.goto('./');
  await page.getByRole('button', {name: '搜索功能', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '搜索功能', exact: true});
  const input = dialog.getByRole('textbox');
  await input.fill('校园');
  await input.press('ArrowDown');
  await expect(dialog.getByRole('button', {name: '校园首页', exact: true})).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(dialog.getByRole('button', {name: '校园社区', exact: true})).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/\/community$/);
  await page.getByRole('button', {name: '搜索功能', exact: true}).click();
  await dialog.getByRole('textbox').fill('不存在的功能');
  await dialog.getByRole('textbox').press('Enter');
  await expect(dialog.getByRole('heading', {name: '没有找到相关功能'})).toBeVisible();
  await expect(page).toHaveURL(/\/community$/);
});

for (const [route, label, key, path] of [
  ['ratings', '搜索', 'q', '/api/teachers'],
  ['competition?tab=directory', '搜索竞赛', 'q', '/api/competitions/events'],
  ['community', '搜索内容', 'q', '/api/posts'],
  ['market', '搜索内容', 'q', '/api/posts'],
  ['canteen?tab=stores', '搜索食堂', 'q', '/api/canteens'],
  ['exams?tab=papers', '搜索试卷', 'keyword', '/api/exam-papers'],
]) {
  test(`浏览器后退同步搜索文字和实际查询：${route}`, async ({page}) => {
    const queries: string[] = [];
    await page.route(`**${path}?**`, request => {
      const url = new URL(request.request().url());
      queries.push(url.searchParams.get(key === 'q' && route.startsWith('competition') ? 'keyword' : key) || '');
      return request.fulfill({json: {items: []}});
    });
    await page.goto(`${route}${route.includes('?') ? '&' : '?'}${key}=${encodeURIComponent('第一词')}`);
    const input = page.locator('main').getByRole('textbox', {name: label, exact: true});
    await expect(input).toHaveValue('第一词');
    await input.fill('第二词');
    await input.press('Enter');
    await expect.poll(() => queries.at(-1)).toBe('第二词');
    await page.goBack();
    await expect(page).toHaveURL(new RegExp(`${key}=${encodeURIComponent('第一词')}`));
    await expect(input).toHaveValue('第一词');
    await page.goForward();
    await expect(input).toHaveValue('第二词');
  });
}

test('手机校园资讯搜索、失败重试和清空仍留在资讯列表', async ({page}) => {
  await page.setViewportSize({width: 390, height: 844});
  let failed = false;
  const queries: URL[] = [];
  await page.route('**/api/campus/articles?**', route => {
    const url = new URL(route.request().url());
    queries.push(url);
    return failed ? route.fulfill({status: 503, json: {message: '资讯暂时不可用'}}) : route.fulfill({json: {items: [{id: 71, title: url.searchParams.get('q') ? '奖学金通知' : '公开通知', author_department: '测试中心'}], has_more: false}});
  });
  await page.goto('campus?view=articles&page=3');
  const input = page.getByRole('textbox', {name: '搜索校园信息', exact: true});
  await input.fill('奖学金');
  failed = true;
  await input.press('Enter');
  await expect(page).toHaveURL(/view=articles/);
  await expect(input).toHaveValue('奖学金');
  await expect(page.locator('main').getByText('资讯暂时不可用', {exact: true})).toBeVisible();
  expect(queries.at(-1)?.searchParams.get('page')).toBe('1');
  failed = false;
  await page.locator('main').getByRole('button', {name: '重试', exact: true}).click();
  await expect(page.getByRole('link', {name: '奖学金通知 测试中心 ·', exact: true})).toBeVisible();
  await input.fill('');
  await input.press('Enter');
  await expect(input).toBeVisible();
  await expect(page).toHaveURL(/view=articles/);
  await expect.poll(() => queries.at(-1)?.searchParams.get('q')).toBe(null);
});

test('校历为空时说明未提供，不能只有一个空壳标题', async ({page}) => {
  await page.route('**/api/campus-calendars/current', route => route.fulfill({json: {calendar: null}}));
  await page.goto('campus');
  await page.getByRole('button', {name: '校历', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '学校校历', exact: true});
  await expect(dialog.getByRole('heading', {name: '暂无可用校历'})).toBeVisible();
  await expect(dialog.getByText('学校尚未提供可展示的校历，请稍后重试或查看学校官网。', {exact: true})).toBeVisible();
  await expect(dialog.getByRole('button', {name: '重试', exact: true})).toBeVisible();
});

test('校历支持未发布 404、旧版图片以及服务端调课规则', async ({page}) => {
  let mode = 'missing';
  await page.route('**/api/campus-calendars/current', route => mode === 'missing'
    ? route.fulfill({status: 404, json: {error: '暂无已发布校历'}})
    : route.fulfill({json: {calendar: mode === 'legacy' ? {academic_year: '2025-2026', image_url: '/calendar-test.png'} : {...calendar, day_overrides: [{date: '2026-11-21', day_mode: 'makeup_teaching', schedule_as_weekday: 1}, {date: '2026-11-22', day_mode: 'no_teaching'}]}}}));
  await page.goto('campus');
  await page.getByRole('button', {name: '校历', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '学校校历', exact: true});
  await expect(dialog.getByRole('heading', {name: '暂无可用校历'})).toBeVisible();
  mode = 'legacy';
  await dialog.getByRole('button', {name: '重试', exact: true}).click();
  await expect(dialog.getByRole('link', {name: '打开学校校历原图'})).toHaveAttribute('href', '/calendar-test.png');
  await dialog.getByRole('button', {name: '关闭', exact: true}).click();
  mode = 'structured';
  await page.reload();
  await page.getByRole('button', {name: '校历', exact: true}).click();
  await expect(dialog.getByText('2026-11-21 · 补课，按周一课表', {exact: true})).toBeVisible();
  await expect(dialog.getByText('2026-11-22 · 不上课', {exact: true})).toBeVisible();
});

for (const width of [390, 1440]) {
  test(`校历按真实接口显示学期、周次、事件和来源 ${width}`, async ({page}, info) => {
    await page.setViewportSize({width, height: 900});
    let failed = true;
    await page.route('**/api/campus-calendars/current', route => failed
      ? route.fulfill({status: 503, json: {error: '校历读取失败'}})
      : route.fulfill({json: {calendar, updated_at: '2026-11-14T12:00:00Z', version: 1}}));
    await page.goto('campus');
    await page.getByRole('button', {name: '校历', exact: true}).click();
    const dialog = page.getByRole('dialog', {name: '学校校历', exact: true});
    await expect(dialog.getByText('校历读取失败', {exact: true})).toBeVisible();
    failed = false;
    await dialog.getByRole('button', {name: '重试', exact: true}).click();
    await expect(dialog.getByRole('heading', {name: '2026-2027 学年校历'})).toBeVisible();
    await expect(dialog.getByRole('heading', {name: '第一学期', exact: true})).toBeVisible();
    await dialog.getByText('查看第一学期教学周', {exact: true}).click();
    await expect(dialog.getByRole('cell', {name: '第 20 周', exact: true}).first()).toBeVisible();
    await expect(dialog.getByRole('heading', {name: '学生放寒假', exact: true})).toBeVisible();
    await expect(dialog.getByText('沈阳理工大学2026—2027学年校历', {exact: false})).toBeVisible();
    expect(await dialog.evaluate(element => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
    await dialog.getByText('查看第一学期教学周', {exact: true}).click();
    await dialog.screenshot({path: info.outputPath(`calendar-${width}.png`)});
  });
}

test('校园地图加载失败可重试，恢复后缩放与复位继续可用', async ({page}, info) => {
  let failed = true;
  await page.route('**/assets/campus-map.png*', route => failed ? route.fulfill({status: 503, body: ''}) : route.continue());
  await page.goto('campus');
  await page.getByRole('button', {name: '打开校园地图', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '校园地图', exact: true});
  await expect(dialog.getByRole('heading', {name: '地图加载失败'})).toBeVisible();
  await expect(dialog.getByRole('button', {name: '放大', exact: true})).toBeDisabled();
  failed = false;
  await dialog.getByRole('button', {name: '重新加载地图', exact: true}).click();
  await expect(dialog.getByRole('button', {name: '放大', exact: true})).toBeEnabled();
  await dialog.getByRole('button', {name: '放大', exact: true}).click();
  await expect(dialog.getByRole('status')).toHaveText('150%');
  await dialog.getByRole('button', {name: '复位地图', exact: true}).click();
  await expect(dialog.getByRole('status')).toHaveText('100%');
  await dialog.screenshot({path: info.outputPath('map-recovered.png')});
});
