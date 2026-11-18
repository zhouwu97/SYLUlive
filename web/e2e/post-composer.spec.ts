import {expect, test, type Page} from '@playwright/test';

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64');
const image = (name: string) => ({name, mimeType: 'image/png', buffer: png});
async function setup(page: Page) {
  const state = {userId: 991, sectionState: 'ready', uploadFailed: false, postState: 'ready', writes: [] as {path: string; body: string; method: string}[], uploads: [] as string[]};
  const post = {id: 77, board_id: 1, title: '原有帖子', content: '原有正文', post_type: 'study', author_id: 991, author: {id: 991, nickname: '体验同学'}, viewer_permissions: {can_edit: true, can_delete: true}, images: [{id: 5, file_id: 101, origin_url: '/uploads/existing.png'}]};
  await page.route('**/uploads/*.png', route => route.fulfill({contentType: 'image/png', body: png}));
  await page.route('**/api/**', async route => {
    const request = route.request(), url = new URL(request.url()), path = url.pathname;
    if (path === '/api/user/profile') return route.fulfill({json: {id: state.userId, role: 'user', nickname: `体验同学${state.userId}`}});
    if (path === '/api/water/sections') return state.sectionState === 'error' ? route.fulfill({status: 503, json: {message: '分区读取失败'}}) : route.fulfill({json: {sections: state.sectionState === 'empty' ? [] : [{id: 1, slug: 'campus_life', title: '校园生活'}, {id: 2, slug: 'study', title: '课程学习', description: '交流学习方法与课程体验'}]}});
    if (path === '/api/upload_multiple') {
      state.uploads.push(request.postData() || '');
      return state.uploadFailed ? route.fulfill({status: 413, json: {message: '测试图片上传失败'}}) : route.fulfill({json: {results: [{file_id: 73}]}});
    }
    if (path === '/api/posts' && request.method() === 'GET') return route.fulfill({json: {posts: [post], has_more: false}});
    if (path === '/api/posts/77' && request.method() === 'GET') return route.fulfill({json: {post}});
    if (/^\/api\/posts(?:\/77)?$/.test(path) && request.method() !== 'GET') {
      state.writes.push({path, body: request.postData() || '', method: request.method()});
      if (state.postState === 'network') return route.abort('failed');
      if (state.postState === 'rejected') return route.fulfill({status: 403, json: {message: '当前分区暂时禁止发布'}});
      if (state.postState === 'rules') return route.fulfill({status: 403, json: {code: 'community_rules_required', message: '请先确认社区规则'}});
      if (state.postState === 'missing-id') return route.fulfill({json: {message: '已接收'}});
      return route.fulfill({json: {id: 77}});
    }
    return route.fulfill({json: {items: []}});
  });
  return state;
}

async function open(page: Page, route = 'community') {
  await page.goto(route);
  await page.getByRole('button', {name: route.startsWith('market') ? '发布闲置' : '发布', exact: true}).click();
  await expect(page).toHaveURL(/\/compose(?:\?|$)/);
  await expect(page.getByRole('dialog')).toHaveCount(0);
  return page.locator('.post-editor-page');
}

test('编辑、预览、暂存返回和重新打开保留文字及图片，不落入浏览器持久存储', async ({page}) => {
  const state = await setup(page);
  const editor = await open(page, 'community?type=study');
  await expect(editor.getByLabel('分区', {exact: true})).toHaveValue('study');
  await editor.getByLabel('内容', {exact: true}).fill('本次未发布的合成草稿');
  await editor.getByLabel('选择图片', {exact: true}).setInputFiles(image('draft.png'));
  await editor.getByRole('button', {name: '预览', exact: true}).click();
  await expect(editor.getByRole('region', {name: '帖子预览'})).toContainText('本次未发布的合成草稿');
  await editor.getByRole('button', {name: '暂存并返回', exact: true}).click();
  await expect(editor).toHaveCount(0);
  await page.getByRole('button', {name: '发布', exact: true}).click();
  await expect(editor.getByLabel('内容', {exact: true})).toHaveValue('本次未发布的合成草稿');
  await expect(editor.getByAltText('draft.png预览', {exact: true})).toBeVisible();
  expect(state.uploads).toHaveLength(0);
  expect(state.writes).toHaveLength(0);
  expect(await page.evaluate(() => JSON.stringify([Object.values(localStorage), Object.values(sessionStorage)]))).not.toContain('本次未发布的合成草稿');
});

test('分区失败与空数据有明确说明，恢复分区不会丢失正文', async ({page}) => {
  const state = await setup(page); state.sectionState = 'error';
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('等待分区恢复的草稿');
  await expect(editor.getByText('分区读取失败', {exact: true})).toBeVisible();
  await expect(editor.getByRole('button', {name: '发布', exact: true})).toBeDisabled();
  state.sectionState = 'empty';
  await editor.getByRole('button', {name: '重新加载分区', exact: true}).click();
  await expect(editor.getByText('暂无可用分区', {exact: true})).toBeVisible();
  state.sectionState = 'ready';
  await editor.getByRole('button', {name: '重新加载分区', exact: true}).click();
  await expect(editor.getByLabel('内容', {exact: true})).toHaveValue('等待分区恢复的草稿');
  await expect(editor.getByRole('button', {name: '发布', exact: true})).toBeEnabled();
});

test('上传失败保留图片和正文，发布失败重试复用上传编号，成功回读真实帖子', async ({page}) => {
  const state = await setup(page); state.uploadFailed = true;
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('完整发布流程');
  await editor.getByLabel('选择图片', {exact: true}).setInputFiles(image('one.png'));
  await editor.getByRole('button', {name: '发布', exact: true}).click();
  await expect(editor.getByRole('alert')).toContainText('测试图片上传失败');
  await expect(editor.getByRole('alert')).toBeInViewport();
  expect(state.writes).toHaveLength(0);
  state.uploadFailed = false; state.postState = 'rejected';
  await editor.getByRole('button', {name: '重新发布', exact: true}).click();
  await expect(editor.getByRole('alert')).toContainText('当前分区暂时禁止发布');
  await expect(editor.getByRole('alert')).toBeInViewport();
  await expect(editor.getByLabel('内容', {exact: true})).toHaveValue('完整发布流程');
  state.postState = 'ready';
  await editor.getByRole('button', {name: '重新发布', exact: true}).click();
  await expect(page).toHaveURL(/\/post\/77$/);
  await expect(editor).toHaveCount(0);
  expect(state.uploads).toHaveLength(2);
  expect(state.writes.at(-1)?.body).toContain('[73]');
});

for (const mode of ['network', 'missing-id']) test(`发布结果不确定时不自动重放或进入 undefined 页面：${mode}`, async ({page}) => {
  const state = await setup(page); state.postState = mode;
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('需要核对结果的帖子');
  await editor.getByRole('button', {name: '发布', exact: true}).click();
  await expect(editor.getByRole('heading', {name: '发布结果尚未确认'})).toBeVisible();
  await expect(editor.getByRole('button', {name: '查看我的发布', exact: true})).toBeVisible();
  await expect(editor.getByRole('button', {name: '待核对结果', exact: true})).toBeDisabled();
  expect(state.writes).toHaveLength(1);
  expect(page.url()).not.toContain('undefined');
});

test('编辑添加图片时保留原图片，而不是用新图覆盖原图', async ({page}) => {
  const state = await setup(page);
  await page.goto('post/77');
  await page.getByLabel('更多操作', {exact: true}).click();
  await page.getByRole('button', {name: '编辑', exact: true}).click();
  const editor = page.locator('.post-editor-page');
  await expect(editor.getByAltText('已发布图片1', {exact: true})).toBeVisible();
  await editor.getByLabel('选择图片', {exact: true}).setInputFiles(image('new.png'));
  await editor.getByRole('button', {name: '保存修改', exact: true}).click();
  await expect(editor).toHaveCount(0);
  expect(state.writes.at(-1)).toMatchObject({path: '/api/posts/77', method: 'PUT'});
  expect(state.writes.at(-1)?.body).toContain('[101,73]');
});

test('发布确认中禁用重复提交，返回与全局搜索不会中断结果确认', async ({page}) => {
  const state = await setup(page);
  let release!: () => void, writes = 0;
  const gate = new Promise<void>(resolve => {release = resolve;});
  await page.route('**/api/posts', async route => {
    if (route.request().method() === 'GET') return route.fallback();
    writes++; await gate; await route.fulfill({json: {id: 77}});
  });
  try {
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('等待确认中的帖子');
  await editor.getByRole('button', {name: '发布', exact: true}).click();
  await expect.poll(() => writes).toBe(1);
  await expect(editor.getByRole('button', {name: '正在发布…', exact: true})).toBeDisabled();
  await editor.getByRole('button', {name: '返回上一页', exact: true}).click();
  await expect(editor).toBeVisible();
  await expect(page.locator('.toast')).toContainText('正在确认发布结果');
  await page.keyboard.press('Control+k');
  await expect(page.getByRole('dialog', {name: '搜索功能', exact: true})).toHaveCount(0);
  await page.keyboard.press('Control+Enter');
  expect(writes).toBe(1);
  release();
  await expect(page).toHaveURL(/\/post\/77$/);
  expect(state.uploads).toHaveLength(0);
  } finally {release();}
});

test('跨账号再返回原账号也不恢复旧草稿', async ({page}) => {
  const state = await setup(page);
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('甲账号的未发布草稿');
  await editor.getByRole('button', {name: '暂存并返回', exact: true}).click();
  for (const userId of [992, 991]) {
    state.userId = userId;
    await page.evaluate(() => {const channel = new BroadcastChannel('sylulive-auth'); channel.postMessage('changed'); channel.close();});
    await expect(page.getByRole('region', {name: '校园个人资料'})).toContainText(`体验同学${userId}`);
  }
  await page.getByRole('button', {name: '发布', exact: true}).click();
  await expect(editor.getByLabel('内容', {exact: true})).toHaveValue('');
  expect(state.writes).toHaveLength(0);
});

test('社区规则确认保留草稿并由本人重新发布，确认不会自动重放', async ({page}) => {
  const state = await setup(page); state.postState = 'rules';
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('等待规则确认的内容');
  await editor.getByRole('button', {name: '发布', exact: true}).click();
  await editor.getByRole('button', {name: '我已阅读并同意社区规则', exact: true}).click();
  await expect(editor.getByRole('alert')).toContainText('规则已确认');
  await expect(editor.getByLabel('内容', {exact: true})).toHaveValue('等待规则确认的内容');
  expect(state.writes).toHaveLength(1);
  state.postState = 'ready';
  await editor.getByRole('button', {name: '重新发布', exact: true}).click();
  await expect(page).toHaveURL(/\/post\/77$/);
  expect(state.writes).toHaveLength(2);
});

test('粘贴图片、非法文件和正文边界不会丢失已经输入的内容', async ({page}) => {
  const state = await setup(page);
  const editor = await open(page);
  const content = editor.getByLabel('内容', {exact: true});
  await content.fill('   ');
  await editor.getByRole('button', {name: '发布', exact: true}).click();
  await expect(editor.getByRole('alert')).toContainText('不能只填写空格');
  await content.fill('图片粘贴测试');
  await content.evaluate((element, encoded) => {
    const transfer = new DataTransfer();
    transfer.items.add(new File([Uint8Array.from(atob(encoded), c => c.charCodeAt(0))], 'pasted.png', {type: 'image/png'}));
    element.dispatchEvent(new ClipboardEvent('paste', {bubbles: true, cancelable: true, clipboardData: transfer}));
  }, png.toString('base64'));
  await expect(editor.getByAltText('pasted.png预览')).toBeVisible();
  await editor.getByLabel('选择图片', {exact: true}).setInputFiles({name: 'bad.pdf', mimeType: 'application/pdf', buffer: Buffer.from('invalid')});
  await expect(editor.getByRole('alert').filter({hasText: 'bad.pdf'})).toBeVisible();
  await expect(editor.getByAltText('pasted.png预览')).toBeVisible();
  await content.fill('字'.repeat(10001));
  await editor.getByRole('button', {name: '重新发布', exact: true}).click();
  await expect(editor.getByRole('alert').filter({hasText: '正文最多 10000 字'})).toBeVisible();
  expect(state.writes).toHaveLength(0);
});

test('闲置发布要求图片，保留小数价格与联系方式', async ({page}) => {
  const state = await setup(page);
  const editor = await open(page, 'market');
  await editor.getByLabel('物品名称', {exact: true}).fill('测试二手教材');
  await editor.getByLabel('内容', {exact: true}).fill('合成物品说明');
  await editor.getByLabel('价格或预算', {exact: true}).fill('12.50');
  await editor.getByLabel('联系方式', {exact: true}).fill('test-only-contact');
  await editor.getByRole('button', {name: '发布', exact: true}).click();
  await expect(editor.getByRole('alert')).toContainText('至少添加一张图片');
  expect(state.writes).toHaveLength(0);
  await editor.getByLabel('选择图片', {exact: true}).setInputFiles(image('book.png'));
  await editor.getByRole('button', {name: '重新发布', exact: true}).click();
  await expect(page).toHaveURL(/\/post\/77$/);
  expect(state.writes.at(-1)?.body).toContain('12.50');
  expect(state.writes.at(-1)?.body).toContain('test-only-contact');
});

test('独立发帖页返回原筛选与阅读位置，长正文自动增高而不是嵌套滚动', async ({page}) => {
  await setup(page);
  await page.route('**/api/posts?**', route => route.fulfill({json: {posts: Array.from({length: 20}, (_, i) => ({id: i + 100, title: `阅读位置测试${i}`, content: '保留当前筛选与阅读位置。', author: {nickname: '合成同学'}})), has_more: false}}));
  await page.goto('community?type=study&q=test');
  await expect(page.getByRole('button', {name: '我的账号', exact: true})).toBeVisible();
  await expect(page.locator('.community-feed .feed-card')).toHaveCount(20);
  // 让首次路由的滚动恢复和布局先完成，再建立用户的阅读位置。
  await page.locator('.community-feed .feed-card').nth(3).scrollIntoViewIfNeeded();
  await page.evaluate(() => window.scrollTo(0, 400));
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(400);
  await page.getByRole('button', {name: '发布校园内容', exact: true}).click();
  const editor = page.locator('.post-editor-page');
  await expect(page).toHaveURL(/\/compose\?type=study$/);
  await expect(page.getByRole('dialog')).toHaveCount(0);
  const content = editor.getByLabel('内容', {exact: true});
  await expect(content).toBeFocused();
  await content.fill('单一滚动区域的长正文。\n'.repeat(35));
  expect(await content.evaluate(el => el.scrollHeight <= el.clientHeight + 2)).toBe(true);
  await expect(editor.getByRole('button', {name: '发布', exact: true})).toBeInViewport();
  await editor.getByRole('button', {name: '暂存并返回', exact: true}).click();
  await expect(page).toHaveURL(/\/community\?type=study&q=test$/);
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(400);
});

test('直达编辑页覆盖加载、失败重试和权限拒绝，不能仅靠入口隐藏控制编辑', async ({page}) => {
  await setup(page);
  let phase: 'loading' | 'error' | 'denied' | 'ready' = 'loading', release!: () => void;
  const gate = new Promise<void>(resolve => {release = resolve;});
  await page.route('**/api/posts/77', async route => {
    if (phase === 'loading') await gate;
    if (phase === 'error') return route.fulfill({status: 503, json: {message: '帖子读取失败'}});
    return route.fulfill({json: {post: {id: 77, board_id: 1, title: '权限验收帖子', content: '可编辑原文', post_type: 'study', viewer_permissions: {can_edit: phase === 'ready'}}}});
  });
  await page.goto('post/77/edit');
  await expect(page.getByRole('status').filter({hasText: '正在加载'})).toBeVisible();
  phase = 'error'; release();
  await expect(page.getByRole('heading', {name: '加载未完成', exact: true})).toBeVisible();
  await expect(page.getByText('帖子读取失败', {exact: true})).toBeVisible();
  phase = 'denied';
  await page.getByRole('button', {name: '重试', exact: true}).click();
  await expect(page.getByRole('heading', {name: '当前账号不能编辑此帖'})).toBeVisible();
  await expect(page.locator('.post-composer')).toHaveCount(0);
  phase = 'ready'; await page.reload();
  await expect(page.getByLabel('内容', {exact: true})).toHaveValue('可编辑原文');
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('发帖页内切换账号立即清稿，游客直达仍用原登录框', async ({page}) => {
  const state = await setup(page);
  const editor = await open(page);
  await editor.getByLabel('内容', {exact: true}).fill('不能带到乙账号的内容');
  state.userId = 992;
  await page.evaluate(() => {const channel = new BroadcastChannel('sylulive-auth'); channel.postMessage('changed'); channel.close();});
  await expect(editor.locator('.post-composer-author')).toContainText('体验同学992');
  await expect(editor.getByLabel('内容', {exact: true})).toHaveValue('');
  await page.route('**/api/user/profile', route => route.fulfill({status: 401, json: {message: '未登录'}}));
  await page.route('**/api/refresh', route => route.fulfill({status: 401, json: {message: '未登录'}}));
  await page.reload();
  await expect(page.getByRole('heading', {name: '登录后发布内容'})).toBeVisible();
  await page.locator('.post-editor-page').getByRole('button', {name: '登录', exact: true}).click();
  await expect(page.getByRole('dialog', {name: '登录沈理校园', exact: true})).toBeVisible();
  expect(state.writes).toHaveLength(0);
});

test('发布请求已发送时浏览器后退仍保留待核对状态，重开不会重复发送', async ({page}) => {
  await setup(page);
  let writes = 0, release!: () => void;
  const gate = new Promise<void>(resolve => {release = resolve;});
  await page.route('**/api/posts', async route => {
    if (route.request().method() === 'GET') return route.fallback();
    writes++; await gate; await route.fulfill({json: {id: 77}});
  });
  try {
    const editor = await open(page);
    await editor.getByLabel('内容', {exact: true}).fill('后退也不能直接重发');
    await editor.getByRole('button', {name: '发布', exact: true}).click();
    await expect.poll(() => writes).toBe(1);
    await page.goBack();
    await expect(page).toHaveURL(/\/community$/);
    await page.getByRole('button', {name: '发布', exact: true}).click();
    await expect(editor.getByRole('heading', {name: '发布结果尚未确认'})).toBeVisible();
    await expect(editor.getByRole('button', {name: '待核对结果', exact: true})).toBeDisabled();
    expect(writes).toBe(1);
  } finally {release();}
});

for (const width of [390, 1440]) test(`评论在手机使用输入弹框、桌面原地展开，不进入发帖页 ${width}`, async ({page}, info) => {
  await setup(page);
  await page.setViewportSize({width, height: 900});
  let comment = '';
  await page.route('**/api/posts/77/replies**', route => {
    if (route.request().method() === 'GET') return route.fulfill({json: {replies: []}});
    comment = route.request().postData() || '';
    return route.fulfill({json: {id: 90}});
  });
  await page.goto('post/77');
  await page.locator('.post-comment-start').click();
  if (width <= 600) {
    const dialog = page.getByRole('dialog', {name: '发表评论', exact: true});
    await expect(dialog.locator('.reply-emoji-composer')).toHaveCount(1);
    await expect(dialog.locator('.post-composer')).toHaveCount(0);
    await expect(dialog.locator('.media-upload-picker-compact')).toHaveCount(0);
    await dialog.getByLabel('写下你的回复', {exact: true}).fill('继续用原来的评论框');
    await page.screenshot({path: info.outputPath(`comment-original-${width}.png`), animations: 'disabled'});
    await dialog.getByRole('button', {name: '发布评论', exact: true}).click();
    await expect(dialog).toHaveCount(0);
  } else {
    const inline = page.locator('.post-comment-input .reply-inline-composer');
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await expect(inline).toHaveCount(1);
    await expect(page.locator('.post-composer')).toHaveCount(0);
    await inline.getByLabel('写下你的回复', {exact: true}).fill('继续用原来的评论框');
    await page.screenshot({path: info.outputPath(`comment-original-${width}.png`), animations: 'disabled'});
    await inline.getByRole('button', {name: '发布评论', exact: true}).click();
  }
  await expect(page).toHaveURL(/\/post\/77$/);
  expect(comment).toContain('继续用原来的评论框');
});

for (const width of [320, 1440]) test(`写作页顶部可确认分区，键盘焦点可见且指针编辑不出现大边框 ${width}`, async ({page}) => {
  await setup(page);
  await page.setViewportSize({width, height: 740});
  const editor = await open(page);
  await expect(editor.getByLabel('分区', {exact: true})).toBeInViewport();
  await expect(editor.getByRole('button', {name: '发布', exact: true})).toBeInViewport();
  await expect(editor.getByRole('button', {name: '返回上一页', exact: true})).toBeInViewport();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  const title = editor.getByLabel('标题', {exact: true}), content = editor.getByLabel('内容', {exact: true});
  await title.focus();
  await title.press('Tab');
  await expect(content).toBeFocused();
  expect(await content.evaluate(el => getComputedStyle(el).outlineWidth)).toBe('2px');
  await content.click();
  expect(await content.evaluate(el => getComputedStyle(el).outlineStyle)).toBe('none');
  if (width > 600) await expect(page.locator('.topbar')).toBeVisible();
});

for (const theme of ['light', 'dark']) for (const width of [390, 1440]) test(`发帖真实渲染、固定操作栏与键盘排序 ${theme} ${width}`, async ({page}, info) => {
  await setup(page);
  await page.setViewportSize({width, height: 900});
  await page.addInitScript(value => localStorage.setItem('sylulive-theme', value), theme);
  const editor = await open(page);
  await expect(editor.getByLabel('分区', {exact: true})).toBeInViewport();
  await editor.getByLabel('标题', {exact: true}).fill('一起记录校园里的小事');
  await editor.getByLabel('内容', {exact: true}).fill('今天图书馆门口的银杏很好看。\n想把这份日常分享给同学，也欢迎推荐你常去的校园角落。');
  // 等字体布局和浏览器绘制完成，截图不能只捕获到提交前的空白绘制层。
  await page.evaluate(async () => {await document.fonts.ready; await new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));});
  await page.screenshot({path: info.outputPath(`post-editor-${theme}-${width}.png`), animations: 'disabled'});
  await editor.getByLabel('选择图片', {exact: true}).setInputFiles([image('first.png'), image('second.png')]);
  await editor.getByRole('button', {name: '将second.png前移', exact: true}).click();
  await expect(editor.locator('.media-upload-item').first()).toContainText('second.png');
  await expect(editor.getByRole('button', {name: '发布', exact: true})).toBeInViewport();
  expect(await editor.evaluate(el => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
  await editor.locator('.post-composer-scroll').evaluate(el => el.scrollTo(0, 0));
  await page.screenshot({path: info.outputPath(`post-composer-${theme}-${width}.png`), animations: 'disabled'});
});
