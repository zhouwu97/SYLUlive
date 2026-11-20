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

test('表情包审核使用投稿 ID，按最新状态提供审核操作', async ({page}) => {
  const state = await setup(page);
  const pack = {id: '8f3a174f40b34d638ce5e2175087420f', user_id: 7, name: '合成表情包', status: 'pending'};
  const path = `/api/admin/emoji-packs/${pack.id}`;
  let conflict = false;
  await page.route('**/api/admin/emoji-packs**', async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.pathname === '/api/admin/emoji-packs') {
      return route.fulfill({json: {items: url.searchParams.get('status') === pack.status ? [pack] : []}});
    }
    if (url.pathname === path) return route.fulfill({json: pack});
    if (url.pathname === `${path}/review`) {
      const body = request.postDataJSON();
      state.writes.push({path: url.pathname, body});
      pack.status = body.action === 'approve' ? 'published' : 'unpublished';
      if (conflict) return route.fulfill({status: 409, json: {code: 'emoji_pack_conflict', error: '状态已变化，请刷新后重试'}});
      return route.fulfill({json: {message: '处理成功'}});
    }
    return route.fulfill({status: 404, json: {error: '表情包不存在'}});
  });
  await page.goto('admin?tab=emoji');
  await page.getByRole('button', {name: '查看与审核'}).click();
  const drawer = page.getByRole('dialog', {name: /审核表情包/});
  const operation = drawer.getByLabel('审核操作');
  await expect(operation.locator('option')).toHaveText(['通过并上架', '驳回修改']);
  await operation.selectOption('reject');
  await expect(drawer.getByRole('textbox', {name: /审核说明/})).toHaveAttribute('required', '');
  await operation.selectOption('approve');
  await drawer.getByRole('button', {name: '提交审核结果'}).click();
  await expect(operation.locator('option')).toHaveText(['下架已发布包']);
  expect(state.writes.at(-1)?.body).toEqual({action: 'approve', reason: ''});

  conflict = true;
  await drawer.getByRole('textbox', {name: /审核说明/}).fill('合成下架说明');
  await drawer.getByRole('button', {name: '提交审核结果'}).click();
  await expect(drawer).toContainText('状态已变化，已刷新');
  await expect(operation).toHaveCount(0);
  await expect(drawer).toContainText('已下架');

  pack.user_id = 900;
  pack.status = 'pending';
  await page.reload();
  await page.getByRole('button', {name: '查看详情'}).click();
  await expect(drawer).toContainText('请交由其他管理员完成审核');
  await expect(operation).toHaveCount(0);
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

test('食堂审核与商户菜品运营、安全中心告警处置及获奖核验备注契约完整可用', async ({page}, info) => {
  const writes: {path: string; method: string; body: any}[] = [];
  await page.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (req.method() !== 'GET') writes.push({path, method: req.method(), body: req.postDataJSON()});
    if (path === '/api/user/profile') return route.fulfill({json: {id: 900, nickname: '超级管理员', role: 'super_admin'}});
    if (path === '/api/canteens/pending') return route.fulfill({json: {items: [{id: 21, name: '新开牛肉面', location_area: '一食堂', location_floor: '二楼', description: '手工拉面', created_at: '2026-11-16T08:00:00Z'}]}} );
    if (path === '/api/canteens/admin-list') return route.fulfill({json: {items: [{id: 5, name: '馋熙椒麻鸡', location_area: '二食堂', location_floor: '一楼', operating_status: 'open', average_star: 4.7, rating_count: 18}]}});
    if (path === '/api/canteens/5/admin-dishes') return route.fulfill({json: {items: [{id: 301, name: '招牌椒麻鸡', status: 'active', average_score: 4.8, photos: []}]}});
    if (path === '/api/admin/security/overview') return route.fulfill({json: {actionable_high_count: 1, open_high_count: 1, total_events: 4, active_blocks_count: 0}});
    // 字段与服务端 securityEventResponse 一致：未处置状态是 active，时间字段是 first/last_seen_at。
    const securityEvent = {id: 88, event_type: 'admin_login_new_device', severity: 'high', status: 'active', actionable: true, action: 'observed', method: 'POST', route: '/api/login', attempt_count: 1, target_masked: '24***28', source_attribution_valid: true, source_ip_status: 'available', source_ip: '203.0.113.9', source_region: '测试地区', source_fingerprint: 'b40c…4d94', source_key: 'fixture-source-key', first_seen_at: '2026-11-17T06:00:00Z', last_seen_at: '2026-11-17T06:00:00Z'};
    if (path === '/api/admin/security/events') return route.fulfill({json: {items: [securityEvent]}});
    if (path === '/api/admin/security/events/88') return route.fulfill({json: securityEvent});
    if (path === '/api/admin/security/events/88/block') return route.fulfill({status: 201, json: {id: 7, event_resolved: true}});
    if (path === '/api/admin/security/logs') return route.fulfill({json: {items: [{id: 501, admin_id: 900, admin_name: '超级管理员', action: 'security_block_created', target: 'b40c…4d94', detail: '管理员新设备登录 · /api/login · 1440 分钟', created_at: '2026-11-17T06:05:00Z'}]}});
    if (path === '/api/admin/competition-awards/verifications') return route.fulfill({json: {items: [{id: 66, award_name: '省一等奖', competition_title: '蓝桥杯'}]}} );
    if (path === '/api/admin/competition-awards/verifications/66') return route.fulfill({json: {id: 66, award_name: '省一等奖', competition_title: '蓝桥杯', evidence_file_ids: []}});
    return route.fulfill({json: {items: []}});
  });

  await page.setViewportSize({width: 1440, height: 960});
  await page.goto('admin?tab=canteens');
  await expect(page.getByText('新开牛肉面', {exact: true})).toBeVisible();
  await page.getByRole('button', {name: '通过上架'}).click();
  expect(writes.some(w => w.path === '/api/canteens/21/approve' && w.method === 'POST')).toBe(true);
  await page.getByRole('button', {name: '全部商户与菜品'}).click();
  await expect(page.getByText('馋熙椒麻鸡', {exact: true})).toBeVisible();
  await page.screenshot({path: info.outputPath('admin-canteen-ops.png'), fullPage: true});

  await page.goto('admin?tab=security');
  await expect(page.getByText('管理员新设备登录（待核查）', {exact: true})).toBeVisible();
  await expect(page.locator('.security-event-row')).toContainText('待处置');
  await expect(page.locator('.security-event-row')).toContainText('203.0.113.9（测试地区）');
  const resolveWrites = () => writes.filter(w => w.path === '/api/admin/security/events/88/resolve');
  // 列表快捷结案需要两次点击：第一次只进入待确认，不发请求。
  await page.locator('.security-quick-actions').getByRole('button', {name: '结案', exact: true}).click();
  expect(resolveWrites()).toHaveLength(0);
  await page.locator('.security-quick-actions').getByRole('button', {name: '确认结案', exact: true}).click();
  await expect.poll(() => resolveWrites().at(-1)?.body.note).toBe('列表快捷结案：已核查');
  await page.locator('.security-event-open').click();
  const securityDialog = page.getByRole('dialog', {name: '管理员新设备登录（待核查）'});
  await expect(securityDialog).toContainText('POST /api/login');
  await securityDialog.getByRole('button', {name: /确认是本人登录/}).click();
  expect(resolveWrites()).toHaveLength(1);
  await securityDialog.getByRole('button', {name: /再点一次确认/}).click();
  await expect.poll(() => resolveWrites().at(-1)?.body.note).toBe('已确认为账号本人登录');
  await page.keyboard.press('Escape');
  // 列表快捷封禁：两步确认，默认按账号相关接口封禁 1 天，并由服务端同时结案。
  const blockWrites = () => writes.filter(w => w.path === '/api/admin/security/events/88/block');
  await page.locator('.security-quick-actions').getByRole('button', {name: '封禁 1 天', exact: true}).click();
  expect(blockWrites()).toHaveLength(0);
  await page.locator('.security-quick-actions').getByRole('button', {name: '确认封禁 1 天', exact: true}).click();
  await expect.poll(() => blockWrites().at(-1)?.body).toMatchObject({scope: 'account', duration_minutes: 1440});
  await page.getByRole('button', {name: '操作记录', exact: true}).click();
  await expect(page.locator('.security-log-list')).toContainText('封禁来源');
  await expect(page.locator('.security-log-list')).toContainText('超级管理员');
  await page.screenshot({path: info.outputPath('admin-security.png'), fullPage: true});

  await page.goto('admin?tab=awards');
  await page.getByRole('button', {name: '处理', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '获奖核验'});
  await dialog.getByLabel('处理说明', {exact: false}).fill('证书编号核验一致');
  await dialog.getByRole('button', {name: '保存', exact: true}).click();
  expect(writes.find(w => w.path === '/api/admin/competition-awards/verifications/66/approve')?.body).toEqual({note: '证书编号核验一致'});
});
