import {expect, test, type Page} from '@playwright/test';

async function syntheticUser(page: Page) {
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, nickname: '恢复测试同学', role: 'user'}}));
}

test('私信列表区分加载、失败、重试与真正的空会话', async ({page}) => {
  await syntheticUser(page);
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  let state: 'pending' | 'failed' | 'empty' = 'pending';
  await page.route('**/api/messages/conversations', async route => {
    if (state === 'pending') await pending;
    if (state !== 'empty') {
      return route.fulfill({status: 503, json: {message: '私信暂时不可用，请重试'}});
    }
    return route.fulfill({json: {conversations: []}});
  });
  await page.goto('messages');
  const main = page.locator('main');
  await expect(main.getByText('正在加载…', {exact: true})).toBeVisible();
  await expect(main.getByText('还没有会话', {exact: true})).toHaveCount(0);
  state = 'failed'; release();
  await expect(main.getByText('私信暂时不可用，请重试', {exact: true})).toBeVisible();
  await expect(main.getByText('还没有会话', {exact: true})).toHaveCount(0);
  state = 'empty';
  await main.getByRole('button', {name: '重试', exact: true}).click();
  await expect(main.getByText('还没有会话', {exact: true})).toBeVisible();
});

test('私信暂停开放明确说明状态，不继续启动实时通道', async ({page}) => {
  await syntheticUser(page);
  let eventRequests = 0;
  await page.route('**/api/messages/events', route => {
    eventRequests++;
    return route.fulfill({status: 410, json: {code: 'PRIVATE_CHAT_DISABLED', message: '私聊功能已暂停开放'}});
  });
  await page.route('**/api/messages/conversations', route => route.fulfill({status: 410, json: {code: 'PRIVATE_CHAT_DISABLED', message: '私聊功能已暂停开放'}}));
  await page.goto('messages');
  await expect(page.locator('main').getByText('私聊功能已暂停开放', {exact: true})).toBeVisible();
  await expect(page.locator('main').getByText('还没有会话', {exact: true})).toHaveCount(0);
  expect(eventRequests).toBe(0);
});

test('正常私信仍能读取已有会话和消息', async ({page}) => {
  await syntheticUser(page);
  await page.route('**/api/messages/conversations', route => route.fulfill({json: {conversations: [{id: 51, user1_id: 991, user2_id: 8, user1: {id: 991, nickname: '恢复测试同学'}, user2: {id: 8, nickname: '同学乙'}}]}}));
  await page.route('**/api/messages/conversations/51', route => route.fulfill({json: {messages: [{id: 1, sender_id: 8, content: '这是已有的私信内容'}]}}));
  await page.route('**/api/messages/events', route => route.fulfill({contentType: 'text/event-stream', body: ''}));
  await page.goto('messages');
  await expect(page.getByText('这是已有的私信内容', {exact: true})).toBeVisible();
});

test('GPA 缺字段不产生结果，明确的零绩点和多行加权可以计算', async ({page}) => {
  await syntheticUser(page);
  await page.goto('toolbox');
  await page.getByRole('button', {name: 'GPA 计算 按学分加权计算，以学校公布结果为准'}).click();
  const dialog = page.getByRole('dialog');
  const input = dialog.getByRole('textbox');
  await input.fill('3,0');
  await dialog.getByRole('button', {name: '计算', exact: true}).click();
  await expect(dialog.getByText('加权 GPA：0.000', {exact: true})).toBeVisible();
  for (const invalid of ['3,', '3,   ', ',4', '3,4,2', '0,4', '1e308,5']) {
    await input.fill(invalid);
    await dialog.getByRole('button', {name: '计算', exact: true}).click();
    await expect(dialog.getByRole('alert')).toBeVisible();
    await expect(dialog.locator('.metric')).toHaveCount(0);
  }
  await input.fill('3，4\n1,0');
  await dialog.getByRole('button', {name: '计算', exact: true}).click();
  await expect(dialog.getByText('加权 GPA：3.000', {exact: true})).toBeVisible();
});

test('没有课表时不宣称整周空闲，可以关闭弹窗前往课表', async ({page}) => {
  await syntheticUser(page);
  await page.goto('toolbox');
  await page.getByRole('button', {name: '空闲时间 从当前课表计算本周无课节次'}).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByText('还没有课表', {exact: true})).toBeVisible();
  await expect(dialog.getByText(/周一：/)).toHaveCount(0);
  await dialog.getByRole('link', {name: '前往课表', exact: true}).click();
  await expect(page).toHaveURL(/\/schedule$/);
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

async function importSchedule(page: Page, start: string, weeks: number[]) {
  await page.clock.setFixedTime(new Date('2026-11-11T12:00:00+08:00'));
  await syntheticUser(page);
  await page.goto('schedule');
  await page.getByRole('button', {name: '课表设置', exact: true}).click();
  const archive = {version: 1, term: {year: '2026', semester: '3'}, termStart: start, courses: [{id: 'course-1', name: '测试课程', teacher: '', room: '', day: 1, periods: [1, 2], weeks}], overrides: {}, grades: [], exams: []};
  await page.getByLabel('导入本地资料（将替换当前数据）').setInputFiles({name: 'schedule.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(archive))});
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.getByRole('link', {name: '工具箱', exact: true}).first().click();
  await page.getByRole('button', {name: '空闲时间 从当前课表计算本周无课节次'}).click();
  return page.getByRole('dialog');
}

test('已有课表按本周排课计算空闲，不把有课节次列为空闲', async ({page}) => {
  const dialog = await importSchedule(page, '2026-09-07', Array.from({length: 18}, (_, i) => i + 1));
  await expect(dialog.getByText('周一：3、4、5、6、7、8、9、10、11、12', {exact: true})).toBeVisible();
});

test('当前日期超出课表已知周次时提示核对，不推断全部空闲', async ({page}) => {
  const dialog = await importSchedule(page, '2026-09-07', [1, 2]);
  await expect(dialog.getByText('当前周超出课表已知范围', {exact: true})).toBeVisible();
  await expect(dialog.getByText(/周一：/)).toHaveCount(0);
});

test('未知页面显示可恢复的未找到状态', async ({page}) => {
  await syntheticUser(page);
  await page.goto('this-page-does-not-exist');
  await expect(page.getByRole('heading', {name: '页面不存在', exact: true})).toBeVisible();
  await page.getByRole('link', {name: '返回首页', exact: true}).click();
  await expect(page).toHaveURL(/\/web\/$/);
});

test('注册协议链接使用当前站点，不跳到固定生产站点', async ({page}) => {
  await page.route('**/api/**', route => route.fulfill({status: 401, json: {message: '未登录'}}));
  await page.goto('profile');
  await page.getByRole('button', {name: '登录', exact: true}).first().click();
  await page.getByRole('button', {name: /注册/}).click();
  await expect(page.getByRole('link', {name: '用户协议', exact: true})).toHaveAttribute('href', '/terms');
  await expect(page.getByRole('link', {name: '隐私政策', exact: true})).toHaveAttribute('href', '/privacy');
});

test('页面模块下载失败有恢复入口，重新加载后可以进入原页面', async ({page}) => {
  await syntheticUser(page);
  await page.route('**/src/connected-apps.tsx', route => route.abort());
  await page.goto('connected-apps');
  await expect(page.getByText('页面加载未完成', {exact: true})).toBeVisible();
  await page.unroute('**/src/connected-apps.tsx');
  await page.getByRole('button', {name: '重新加载页面', exact: true}).click();
  await expect(page.getByText('页面加载未完成', {exact: true})).toHaveCount(0);
  await expect(page.locator('main')).toContainText('当前账号：恢复测试同学');
});
