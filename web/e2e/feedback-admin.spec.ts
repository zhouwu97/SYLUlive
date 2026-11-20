import {test, expect, type Page} from '@playwright/test';

const tickets = [
  {id: 8, ticket_no: 'SY2611104316', title: '透明bug', status: 'accepted',
    latest_reply_snippet: '官方：这个就是透明度没有设置下限保护可以调整到全透明，如果不开毛玻璃模糊，自然就会这样',
    updated_at: '2026-11-12T06:11:15Z'},
  {id: 7, ticket_no: 'SY2611094284', title: '课表与实际有些不符', status: 'pending',
    description: '补课没有同步', updated_at: '2026-11-10T00:56:05Z'},
  {id: 6, ticket_no: 'SY2609246129', title: '楼中楼回复照片不显示？', status: 'resolved',
    latest_reply_snippet: '状态变更：已解决', updated_at: '2026-10-12T07:32:44Z'},
];

function detail(messages: unknown[] = [], status = 'accepted') {
  return {
    ticket: {
      id: 8, ticket_no: 'SY2611104316', title: '透明bug', type: 'bug', status, priority: 'P2',
      user_id: 3, user: {id: 3, nickname: '合成用户'},
      description: '帖子评论区透明度异常', steps_to_reproduce: '1. 打开外观设置\n2. 透明度拉到最低',
      app_version: '1.7.12', build_number: '1722', device_model: 'Pixel 8', os_version: 'Android 15',
      current_route: '/post/12',
      created_at: '2026-11-10T11:18:01Z', updated_at: '2026-11-12T06:11:15Z',
    },
    initial_submission: {message_id: 1, sender_type: 'user', content: '帖子评论区透明度异常', created_at: '2026-11-10T11:18:01Z'},
    messages,
    history: [{id: 1, new_status: 'pending', note: '工单已提交', created_at: '2026-11-10T11:18:01Z'}],
  };
}

async function signInAsAdmin(page: Page) {
  await page.context().addCookies([{name: 'jwt', value: 'e2e-session', url: 'http://127.0.0.1:5173'}]);
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 9, nickname: '管理员', role: 'admin'}}));
}

test('桌面工单列表与详情同屏，单号时间完整显示且可切换工单', async ({page}, info) => {
  await signInAsAdmin(page);
  await page.setViewportSize({width: 1440, height: 900});
  await page.route('**/api/admin/feedback/tickets?*', route => route.fulfill({json: {tickets}}));
  await page.route(/\/api\/admin\/feedback\/tickets\/\d+$/, route => {
    const ticket = tickets.find(item => String(item.id) === route.request().url().split('/').pop());
    return route.fulfill({json: {...detail(), ticket: {...detail().ticket, ...ticket}}});
  });
  await page.goto('admin?tab=feedback&status=all');
  const list = page.locator('.admin-ticket-list');
  const pane = page.locator('.admin-ticket-pane');
  const row = list.getByRole('button', {name: /透明bug/});
  await expect(row).toContainText('透明bug');
  await expect(row).toHaveAttribute('aria-current', 'true');
  await expect(pane.getByRole('heading', {name: '透明bug'})).toBeVisible();
  const no = await row.locator('.mono').boundingBox();
  const title = await row.locator('.admin-ticket-top b').boundingBox();
  const timeBox = await row.locator('time').boundingBox();
  expect(title!.y + title!.height).toBeLessThanOrEqual(no!.y);
  expect(no!.x + no!.width).toBeLessThanOrEqual(timeBox!.x);
  expect(timeBox!.height).toBeLessThan(24);
  const listBox = await list.boundingBox(), paneBox = await pane.boundingBox();
  expect(listBox!.x + listBox!.width).toBeLessThanOrEqual(paneBox!.x);
  await expect(page.getByText('处理用户反馈的问题与建议', {exact: false})).toBeVisible();
  await list.getByRole('button', {name: /课表与实际有些不符/}).click();
  await expect(pane.getByRole('heading', {name: '课表与实际有些不符'})).toBeVisible();
  await expect(list.getByRole('button', {name: /课表与实际有些不符/})).toHaveAttribute('aria-current', 'true');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({path: info.outputPath('admin-ticket-list.png'), fullPage: true});
});

test('管理端详情展示排查信息，进度说明可空提交，回复发送后输入清空', async ({page}, info) => {
  await signInAsAdmin(page);
  await page.setViewportSize({width: 1440, height: 1000});
  let messages: unknown[] = [];
  let status = 'accepted';
  const statusBodies: Record<string, unknown>[] = [];
  await page.route('**/api/admin/feedback/tickets/8', route => route.fulfill({json: detail(messages, status)}));
  await page.route('**/api/admin/feedback/tickets/8/status', async route => {
    const body = route.request().postDataJSON();
    statusBodies.push(body);
    status = body.status;
    await route.fulfill({json: {message: 'ok'}});
  });
  await page.route('**/api/admin/feedback/tickets/8/messages', async route => {
    const body = route.request().postDataJSON();
    messages = [...messages, {id: 50 + messages.length, sender_type: 'admin', message_type: 'text', content: body.content,
      visible_to_user: body.visible_to_user, created_at: '2026-11-12T07:00:00Z'}];
    await route.fulfill({json: {message: 'ok'}});
  });
  await page.goto('admin/feedback/8');

  const facts = page.locator('.ticket-facts');
  await expect(facts).toContainText('合成用户 · UID 3');
  await expect(facts).toContainText('1.7.12 (1722)');
  await expect(facts).toContainText('Pixel 8 · Android 15');
  await expect(page.locator('.ticket-extra')).toContainText('透明度拉到最低');
  await page.screenshot({path: info.outputPath('admin-ticket-detail.png')});

  const aside = page.locator('.ticket-aside');
  await aside.locator('select[name="status"]').selectOption('fixing');
  await aside.getByRole('button', {name: '更新状态'}).click();
  await expect.poll(() => statusBodies.length).toBe(1);
  expect(statusBodies[0]).toMatchObject({status: 'fixing', status_note: '', expected_status: 'accepted'});
  await expect(aside.locator('.ticket-status')).toHaveText('修复中');

  const reply = page.locator('.reply-form');
  await reply.locator('textarea[name="content"]').fill('已定位，下个版本修复');
  await reply.getByRole('button', {name: '发送'}).click();
  await expect(page.locator('.thread')).toContainText('已定位，下个版本修复');
  await expect(reply.locator('textarea[name="content"]')).toHaveValue('');
});

test('窄屏工单列表沿用 App 式两列布局且无横向溢出', async ({page}) => {
  await signInAsAdmin(page);
  await page.setViewportSize({width: 390, height: 844});
  await page.route('**/api/admin/feedback/tickets?*', route => route.fulfill({json: {tickets}}));
  await page.goto('admin?tab=feedback');
  await expect(page.locator('.ticket-list .ticket-row').first()).toBeVisible();
  await expect(page.locator('.ticket-list .ticket-row > .mono').first()).toBeHidden();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy();
});

test('工单全部筛选在桌面与手机之间切换保持选中且不发送 all 状态码', async ({page}) => {
  await signInAsAdmin(page);
  const requests: URL[] = [];
  await page.route('**/api/admin/feedback/tickets?*', route => {
    requests.push(new URL(route.request().url()));
    return route.fulfill({json: {tickets}});
  });
  await page.goto('admin?tab=feedback&status=all');
  await expect(page.getByRole('tab', {name: '全部', exact: true})).toHaveAttribute('aria-selected', 'true');
  await page.setViewportSize({width: 390, height: 844});
  await expect(page.getByRole('tab', {name: '全部', exact: true})).toHaveAttribute('aria-selected', 'true');
  await page.getByRole('tab', {name: '待受理', exact: true}).click();
  await page.getByRole('tab', {name: '全部', exact: true}).click();
  await page.setViewportSize({width: 1440, height: 900});
  await expect(page.getByRole('tab', {name: '全部', exact: true})).toHaveAttribute('aria-selected', 'true');
  expect(requests.some(url => url.searchParams.get('status_filter') === 'all')).toBe(false);
});
