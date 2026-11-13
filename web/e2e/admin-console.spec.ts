import {test, expect, type Page} from '@playwright/test';

async function setup(page: Page) {
  const ticket = {id: 8, ticket_no: 'SY2611130008', title: '合成工单', status: 'pending', type: 'bug', user_id: 7,
    user: {id: 7, nickname: '合成用户'}, description: '合成排查信息', created_at: '2026-11-09T08:00:00Z'};
  const state = {
    ticket, messages: [] as Record<string, unknown>[], writes: [] as {path: string; body: any}[],
    failStatus: false, failNotice: false, failStats: false, emptyTickets: false,
  };
  await page.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path === '/api/user/profile') return route.fulfill({json: {id: 900, nickname: '合成管理员', role: 'admin'}});
    if (req.method() !== 'GET') state.writes.push({path, body: req.postDataJSON()});
    if (path === '/api/admin/feedback/tickets/stats') return state.failStats
      ? route.fulfill({status: 503, json: {error: '概览读取失败'}})
      : route.fulfill({json: {pending_count: ticket.status === 'pending' ? 1 : 0, unviewed_count: 0}});
    if (path === '/api/admin/feedback/tickets') return route.fulfill({json: {tickets: state.emptyTickets ? [] : [ticket], has_more: false}});
    if (path === '/api/admin/feedback/tickets/8') return route.fulfill({json: {ticket, initial_submission: {content: ticket.description}, messages: state.messages}});
    if (path === '/api/admin/feedback/tickets/8/messages') {
      const message = req.postDataJSON();
      if (ticket.status === 'closed' && message.visible_to_user) return route.fulfill({status: 409, json: {code: 'feedback_closed_public_reply', error: '已关闭工单不能公开回复'}});
      state.messages.push({id: state.messages.length + 1, sender_type: 'admin', ...message});
      if (message.visible_to_user && ticket.status === 'pending') ticket.status = 'accepted';
      return route.fulfill({json: {message: state.messages.at(-1), ticket}});
    }
    if (path === '/api/admin/feedback/tickets/8/status') {
      if (state.failStatus) return route.fulfill({status: 503, json: {error: '状态更新失败'}});
      if (req.postDataJSON().expected_status !== ticket.status) return route.fulfill({status: 409, json: {error: '工单状态已变化'}});
      ticket.status = req.postDataJSON().status;
      return route.fulfill({json: {message: 'ok'}});
    }
    if (path === '/api/announcements/admin/list') return route.fulfill({json: {announcements: []}});
    if (path === '/api/announcements' && req.method() === 'POST') return state.failNotice
      ? route.fulfill({status: 503, json: {error: '公告保存失败'}})
      : route.fulfill({json: {id: 55}});
    return route.fulfill({json: {items: []}});
  });
  return state;
}

for (const width of [1440, 390]) for (const theme of ['light', 'dark']) {
  test(`公告编辑预览、失败保留草稿、成功关闭 ${width} ${theme}`, async ({page}, info) => {
    const state = await setup(page);
    state.failNotice = true;
    await page.setViewportSize({width, height: 900});
    await page.addInitScript(value => localStorage.setItem('sylulive-theme', value), theme);
    await page.goto('admin?tab=notices');
    const open = page.getByRole('button', {name: '新增公告'});
    await open.click();
    const dialog = page.getByRole('dialog', {name: '新建公告'});
    await dialog.getByLabel('公告标题', {exact: true}).fill('合成公告预览');
    await dialog.getByLabel('正文', {exact: true}).fill('这是一份未发布的测试草稿。');
    const preview = dialog.locator('.notice-preview');
    await expect(preview).toContainText('合成公告预览');
    await expect(preview).toContainText('这是一份未发布的测试草稿。');
    await dialog.getByLabel('展示方式', {exact: false}).selectOption('modal');
    await expect(preview.locator('.notice-preview-modal')).toContainText('合成公告预览');
    if (width > 600) {
      // 右缘对齐遮罩内容区域，排除根元素保留的滚动条槽。
      const viewportWidth = await page.locator('.overlay-drawer').evaluate(element => element.getBoundingClientRect().right);
      await expect.poll(async () => {const box = await dialog.boundingBox(); return Math.abs(box!.x + box!.width - viewportWidth);}).toBeLessThan(2);
      expect((await dialog.boundingBox())!.height).toBe(900);
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await dialog.getByRole('button', {name: '保存', exact: true}).click();
    await expect(dialog.getByRole('alert')).toContainText('公告保存失败');
    await expect(dialog.getByLabel('公告标题', {exact: true})).toHaveValue('合成公告预览');
    await dialog.screenshot({path: info.outputPath('notice-editor.png')});
    state.failNotice = false;
    await dialog.getByRole('button', {name: '保存', exact: true}).click();
    await expect(dialog).toHaveCount(0);
    await expect(open).toBeFocused();
    expect(state.writes.filter(x => x.path === '/api/announcements').at(-1)?.body).toMatchObject({title: '合成公告预览', display_mode: 'modal', status: 'draft'});
  });
}

test('待受理工单首次公开回复自动受理后仍可设为待补充', async ({page}) => {
  const state = await setup(page);
  await page.goto('admin?tab=feedback');
  const pane = page.getByRole('region', {name: '工单详情'});
  await pane.getByRole('textbox', {name: '回复内容', exact: true}).fill('请补充截图');
  await pane.getByRole('button', {name: '发送并设为待补充'}).click();
  await expect(pane.locator('.ticket-status')).toHaveText('待补充');
  expect(state.writes.filter(x => x.path.endsWith('/status'))[0].body.expected_status).toBe('accepted');
  expect(state.writes.filter(x => x.path.endsWith('/messages'))).toHaveLength(1);
});

test('回复发送成功但状态失败时不保留可重复发送的正文', async ({page}) => {
  const state = await setup(page);
  state.failStatus = true;
  await page.goto('admin?tab=feedback');
  const pane = page.getByRole('region', {name: '工单详情'});
  await pane.getByRole('textbox', {name: '回复内容', exact: true}).fill('请补充截图');
  await pane.getByRole('button', {name: '发送并设为待补充'}).click();
  await expect(pane.getByRole('alert')).toContainText('回复已发送');
  await expect(pane.getByRole('textbox', {name: '回复内容', exact: true})).toHaveValue('');
  await expect(pane.locator('.thread')).toContainText('请补充截图');
  state.failStatus = false;
  await pane.getByLabel('处理状态', {exact: true}).selectOption('waiting_user');
  await pane.getByRole('button', {name: '更新状态', exact: true}).click();
  await expect(pane.locator('.ticket-status')).toHaveText('待补充');
  expect(state.writes.filter(x => x.path.endsWith('/messages'))).toHaveLength(1);
});

test('已关闭工单只允许内部备注，公开回复须先重新打开', async ({page}) => {
  const state = await setup(page);
  state.ticket.status = 'closed';
  await page.goto('admin?tab=feedback&status=all');
  const pane = page.getByRole('region', {name: '工单详情'});
  await expect(pane).toContainText('该工单已关闭');
  await expect(pane.getByRole('textbox', {name: '回复内容', exact: true})).toHaveCount(0);
  await pane.getByRole('tab', {name: '内部备注', exact: true}).click();
  await pane.getByRole('textbox', {name: '内部备注内容'}).fill('合成内部交接');
  await pane.getByRole('button', {name: '保存备注'}).click();
  await expect(pane.locator('.thread')).toContainText('合成内部交接');
  expect(state.writes.filter(x => x.path.endsWith('/messages'))[0].body.visible_to_user).toBe(false);
  await page.goto('admin/feedback/8');
  const fullPage = page.locator('.reply-form');
  await expect(fullPage).toContainText('该工单已关闭');
  await expect(fullPage.getByRole('combobox', {name: /回复方式/})).toHaveValue('internal');
  await expect(fullPage.locator('option[value="public"]')).toHaveCount(0);
});

test('工作台读取计数失败时不能提示没有待受理工单', async ({page}) => {
  const state = await setup(page);
  state.failStats = true;
  state.emptyTickets = true;
  await page.goto('admin');
  const kpi = page.locator('.admin-kpi').filter({hasText: '待受理工单'});
  await expect(kpi).toContainText('读取失败');
  await expect(kpi).not.toContainText('没有待受理工单');
  state.failStats = false;
  await page.getByRole('button', {name: '刷新工作台', exact: true}).click();
  await expect(kpi).not.toContainText('读取失败');
  await expect(page.getByRole('link', {name: '操作日志', exact: true})).toHaveCount(0);
});

test('浏览器标签页使用站点图标且资源不会回退为 HTML', async ({page}) => {
  await setup(page);
  await page.goto('./');
  const icon = await page.locator('link[rel="icon"]').getAttribute('href');
  expect(icon).toBe('/web/assets/app-icon.png');
  const response = await page.request.get(icon!);
  expect(response.ok()).toBe(true);
  expect(response.headers()['content-type']).toContain('image/png');
  const brand = await page.locator('.brand-mark img').getAttribute('src');
  expect(icon).toBe(brand);
});
