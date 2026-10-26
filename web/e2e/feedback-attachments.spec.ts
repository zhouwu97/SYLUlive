import {test, expect} from '@playwright/test';

// 1x1 PNG：附件必须是真二进制响应，才能验证读取没有走 JSON 解析。
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

function attachment(fileID: number, messageID: number) {
  return {id: fileID * 100 + messageID, file_id: fileID, message_id: messageID};
}

function ticketPayload(overrides: Record<string, unknown> = {}) {
  return {
    ticket: {
      id: 1, ticket_no: 'SY2609220001', title: '工单里的截图看不到',
      description: '初始描述', status: 'waiting_user',
      created_at: '2026-09-22T02:00:00Z', updated_at: '2026-09-22T03:00:00Z',
      // 历史兼容字段：管理员后来发的图同样挂在这里，不能因此重复显示成初始提交的一部分。
      attachments: [attachment(11, 0), attachment(12, 0)],
    },
    initial_submission: {
      message_id: 80, sender_type: 'user', content: '初始描述',
      created_at: '2026-09-22T02:00:00Z', attachments: [attachment(11, 80)],
    },
    messages: [
      {id: 81, sender_type: 'admin', sender_id: 9, message_type: 'request_info',
        content: '请补充一张截图', visible_to_user: true,
        created_at: '2026-09-22T02:30:00Z', attachments: [attachment(12, 81)]},
      {id: 82, sender_type: 'user', sender_id: 3, message_type: 'text',
        content: '补上了', visible_to_user: true,
        created_at: '2026-09-22T02:40:00Z', attachments: [attachment(12, 82)]},
      {id: 83, sender_type: 'admin', sender_id: 9, message_type: 'text',
        content: '这张已经删掉了', visible_to_user: true,
        created_at: '2026-09-22T02:50:00Z', attachments: [attachment(13, 83)]},
    ],
    history: [],
    ...overrides,
  };
}

test.beforeEach(async ({page}) => {
  await page.context().addCookies([{name: 'jwt', value: 'e2e-session', url: 'http://127.0.0.1:5173'}]);
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 3, nickname: '测试用户', role: 'user'}}));
});

test('工单截图只经带鉴权接口渲染，初始区与消息区各显示一次且区分来源', async ({page}) => {
  const attachmentPaths: Record<string, number> = {};
  const publicUploadPaths: string[] = [];
  await page.route('**/uploads/**', async route => {
    publicUploadPaths.push(new URL(route.request().url()).pathname);
    await route.fulfill({status: 404, body: ''});
  });
  await page.route('**/api/feedback/tickets/1', route => route.fulfill({json: ticketPayload()}));
  await page.route('**/api/feedback/attachments/*', async route => {
    const url = new URL(route.request().url());
    const path = url.pathname.replace('/web/', '/');
    attachmentPaths[path] = (attachmentPaths[path] || 0) + 1;
    // 私有附件必须带会话凭据发出，否则服务端只会返回未登录。
    expect(route.request().headers().cookie || '').toContain('jwt=e2e-session');
    if (path.endsWith('/13')) {
      await route.fulfill({status: 404, body: ''});
      return;
    }
    await route.fulfill({status: 200, contentType: 'image/png', body: png});
  });

  await page.goto('feedback/1');
  const thread = page.locator('.thread');
  // 11 只在初始区，12 在两条消息里各一次，13 读取失败。
  await expect(thread.getByRole('img', {name: '初始提交附件 1'})).toHaveCount(1);
  await expect(thread.getByRole('img', {name: '本条消息附件 1'})).toHaveCount(2);
  for (const name of ['初始提交附件 1', '本条消息附件 1']) {
    const image = thread.getByRole('img', {name}).first();
    await expect(image).toBeVisible();
    await expect.poll(() => image.evaluate((node: HTMLImageElement) => node.naturalWidth)).toBeGreaterThan(0);
  }
  // 只读取到这三个受保护地址，且没有任何一次退化成无鉴权的 /uploads 直链。
  // 开发模式下 StrictMode 会重复挂载组件、同一附件可能被读多次，所以这里断言集合而不是次数。
  expect(Object.keys(attachmentPaths).sort()).toEqual([
    '/api/feedback/attachments/11',
    '/api/feedback/attachments/12',
    '/api/feedback/attachments/13',
  ]);
  expect(publicUploadPaths).toEqual([]);
  // 消息来源按类型区分，不再把系统事件与请求补充都叫「官方回复」。
  await expect(thread.getByText('请求补充信息', {exact: true})).toHaveCount(1);
  await expect(thread.getByText('用户补充', {exact: true})).toHaveCount(1);
  // 读取失败的附件给出可辨识的不可访问提示，而不是破图或空白。
  await expect(thread.getByText('无权查看，或文件已被删除')).toBeVisible();
});

test('点击工单截图在弹层里放大查看', async ({page}) => {
  await page.route('**/api/feedback/tickets/1', route => route.fulfill({json: ticketPayload()}));
  await page.route('**/api/feedback/attachments/*', route => route.fulfill({status: 200, contentType: 'image/png', body: png}));
  await page.goto('feedback/1');
  await page.getByRole('img', {name: '初始提交附件 1'}).click();
  const dialog = page.getByRole('dialog', {name: '初始提交附件 1'});
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('img', {name: '初始提交附件 1'})).toBeVisible();
});

test('已关闭工单不再提供注定失败的回复框，只给出重新打开入口', async ({page}) => {
  const payload = ticketPayload();
  (payload.ticket as Record<string, unknown>).status = 'closed';
  await page.route('**/api/feedback/tickets/1', route => route.fulfill({json: payload}));
  await page.route('**/api/feedback/attachments/*', route => route.fulfill({status: 200, contentType: 'image/png', body: png}));
  await page.goto('feedback/1');
  await expect(page.getByText('该工单已关闭')).toBeVisible();
  await expect(page.getByLabel('补充信息')).toHaveCount(0);
  await expect(page.getByRole('button', {name: '发送'})).toHaveCount(0);
  await expect(page.getByRole('button', {name: '重新打开'})).toBeVisible();
});

test('管理员返回列表保留筛选条件与工单标签页', async ({page}) => {
  await page.route('**/api/admin/feedback/tickets*', route => route.fulfill({json: {tickets: [], total: 0, page: 1, limit: 20}}));
  await page.route('**/api/admin/feedback/tickets/1', route => route.fulfill({json: ticketPayload()}));
  await page.route('**/api/feedback/attachments/*', route => route.fulfill({status: 200, contentType: 'image/png', body: png}));
  // 列表筛选写在自己的地址上，详情必须把这份状态带回去。
  await page.goto('admin?status=pending&page=2');
  await expect(page.getByRole('link', {name: '返回列表'})).toHaveCount(0);
  // 直接进详情时同样按当前地址拼返回链接，不会掉到不存在的路由上。
  await page.goto('admin/feedback/1?status=pending&page=2');
  await expect(page.getByRole('link', {name: '返回列表'})).toHaveAttribute('href', '/web/admin?status=pending&page=2&tab=feedback');
});
