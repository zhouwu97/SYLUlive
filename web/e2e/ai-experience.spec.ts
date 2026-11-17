import {expect, test, type Page} from '@playwright/test';

async function setup(page: Page) {
  const state = {userId: 991};
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: state.userId, nickname: `验收同学${state.userId}`, role: 'user'}}));
  await page.route('**/api/ai/conversations', route => route.fulfill({json: {conversations: [{id: 'a', title: '第一段会话'}, {id: 'b', title: '第二段会话'}]}}));
  return state;
}

function gate() {
  let release!: () => void;
  return {pending: new Promise<void>(resolve => {release = resolve;}), release: () => release()};
}

test('连续切换历史会话，迟到响应不能覆盖最后选择', async ({page}) => {
  await setup(page);
  const first = gate();
  let reads = 0;
  await page.route('**/api/ai/conversations/a', async route => {reads++; await first.pending; await route.fulfill({json: {messages: [{role: 'assistant', content: '迟到的旧会话'}]}});});
  await page.route('**/api/ai/conversations/b', route => route.fulfill({json: {messages: [{role: 'assistant', content: '当前选择的会话'}]}}));
  await page.goto('ai');
  await page.getByRole('button', {name: '第一段会话', exact: true}).click();
  await expect.poll(() => reads).toBe(1);
  await page.getByRole('button', {name: '第二段会话', exact: true}).click();
  await expect(page.locator('.ai-output')).toContainText('当前选择的会话');
  first.release();
  await page.waitForLoadState('networkidle');
  await expect(page.locator('.ai-output')).toContainText('当前选择的会话');
  await expect(page.locator('main')).not.toContainText('迟到的旧会话');
});

test('新建会话同时清理旧来源，正常提问可完成并保留请求契约', async ({page}) => {
  await setup(page);
  const writes: Record<string, unknown>[] = [];
  await page.route('**/api/ai/runs', route => {writes.push(route.request().postDataJSON()); return route.fulfill({json: {run: {id: 'run-1', conversation_id: 'created'}}});});
  await page.route('**/api/ai/runs/run-1/events', route => route.fulfill({contentType: 'text/event-stream', body: 'event: answer.completed\ndata: {"payload":{"text":"合成回答"}}\n\nevent: sources.ready\ndata: {"payload":{"sources":[{"title":"旧回答的来源"}]}}\n\nevent: run.completed\ndata: {"payload":{}}\n\n'}));
  await page.goto('ai');
  await page.getByRole('textbox', {name: '问题', exact: true}).fill('查询校园公开信息');
  await page.getByRole('button', {name: '发送', exact: true}).click();
  await expect(page.locator('.ai-output')).toHaveText('合成回答');
  await expect(page.getByText('旧回答的来源', {exact: true})).toBeVisible();
  await page.getByRole('button', {name: '＋ 新建会话', exact: true}).click();
  await expect(page.getByText('旧回答的来源', {exact: true})).toHaveCount(0);
  await expect(page.getByRole('textbox', {name: '问题', exact: true})).toHaveValue('');
  expect(writes).toHaveLength(1);
  expect(writes[0]).toMatchObject({message: '查询校园公开信息'});
  expect(writes[0].client_request_id).toEqual(expect.any(String));
});

test('创建响应未返回时可以停止等待，迟到响应不会再连接事件流', async ({page}) => {
  await setup(page);
  const creation = gate();
  let creates = 0, streams = 0;
  await page.route('**/api/ai/runs', async route => {creates++; await creation.pending; await route.fulfill({json: {run: {id: 'late-run'}}});});
  await page.route('**/api/ai/runs/late-run/events', route => {streams++; return route.fulfill({contentType: 'text/event-stream', body: 'event: answer.completed\ndata: {"payload":{"text":"不应回填的回答"}}\n\n'});});
  await page.goto('ai');
  await page.getByRole('textbox', {name: '问题', exact: true}).fill('测试等待创建');
  await page.getByRole('button', {name: '发送', exact: true}).click();
  await expect.poll(() => creates).toBe(1);
  await page.getByRole('button', {name: '停止生成', exact: true}).click();
  // 先释放响应，保证失败时也不会把测试挂在等待中。
  creation.release();
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('alert')).toContainText('已停止等待创建结果');
  await expect(page.getByRole('button', {name: '重试', exact: true})).toBeEnabled();
  expect(creates).toBe(1);
  expect(streams).toBe(0);
  await expect(page.locator('main')).not.toContainText('不应回填的回答');
});

test('账号切换清除已读 AI 会话，旧账号的迟到历史不能回填', async ({page}) => {
  const state = await setup(page);
  const old = gate();
  let reads = 0;
  await page.route('**/api/ai/conversations/a', async route => {reads++; await old.pending; await route.fulfill({json: {messages: [{role: 'assistant', content: '甲账号迟到内容'}]}});});
  await page.route('**/api/ai/conversations/b', route => route.fulfill({json: {messages: [{role: 'assistant', content: '甲账号已读内容'}]}}));
  await page.goto('ai');
  await page.getByRole('button', {name: '第二段会话', exact: true}).click();
  await expect(page.locator('.ai-output')).toContainText('甲账号已读内容');
  await page.getByRole('button', {name: '第一段会话', exact: true}).click();
  await expect.poll(() => reads).toBe(1);
  state.userId = 992;
  await page.evaluate(() => {const channel = new BroadcastChannel('sylulive-auth'); channel.postMessage('changed'); channel.close();});
  await expect(page.getByRole('region', {name: '校园个人资料'})).toContainText('验收同学992');
  old.release();
  await page.waitForLoadState('networkidle');
  await expect(page.locator('main')).not.toContainText('甲账号已读内容');
  await expect(page.locator('main')).not.toContainText('甲账号迟到内容');
});

test('已创建运行停止失败可重试，停止中阻止重复提交且成功后不回填旧回答', async ({page}) => {
  await setup(page);
  const stream = gate(), cancellation = gate();
  let creates = 0, streams = 0, cancels = 0, failed = true;
  await page.route('**/api/ai/runs', route => {creates++; return route.fulfill({json: {run: {id: 'known-run'}}});});
  await page.route('**/api/ai/runs/known-run/events', async route => {streams++; await stream.pending; await route.fulfill({contentType: 'text/event-stream', body: 'event: answer.completed\ndata: {"payload":{"text":"已停止的旧回答"}}\n\n'});});
  await page.route('**/api/ai/runs/known-run/cancel', async route => {
    cancels++;
    if (failed) await cancellation.pending;
    await route.fulfill(failed ? {status: 503, json: {message: '暂时无法停止，请重试'}} : {json: {ok: true}});
  });
  await page.goto('ai');
  await page.getByRole('textbox', {name: '问题', exact: true}).fill('测试可恢复的停止');
  await page.getByRole('button', {name: '发送', exact: true}).click();
  await expect.poll(() => streams).toBe(1);
  await page.getByRole('button', {name: '停止生成', exact: true}).click();
  await expect(page.getByRole('button', {name: '正在停止…', exact: true})).toBeDisabled();
  await expect.poll(() => cancels).toBe(1);
  cancellation.release();
  await expect(page.locator('.toast')).toHaveText('暂时无法停止，请重试');
  failed = false;
  await page.getByRole('button', {name: '停止生成', exact: true}).click();
  await expect(page.getByRole('alert')).toHaveText('已取消');
  stream.release();
  await page.waitForLoadState('networkidle');
  await expect(page.locator('main')).not.toContainText('已停止的旧回答');
  expect(creates).toBe(1);
  expect(cancels).toBe(2);
});
