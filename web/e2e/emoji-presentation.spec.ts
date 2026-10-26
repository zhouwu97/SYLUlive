import { test, expect, type Page } from "@playwright/test";
import { readFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";

const source = resolve("server/internal/handlers/sticker_assets");
const catalog = JSON.parse(readFileSync(resolve(source, "catalog.json"), "utf8")) as { id: string; name: string; version: number; items: { id: string; label: string; file: string; mime_type: string }[] }[];
const favorite = { id: 9, favorite_id: 9, kind: "custom", asset_id: 33, file_id: 44, mime_type: "image/png", name: "常用图片" };
async function setup(page: Page) {
  const state = {
    userId: 3 as number | null, items: [favorite] as Record<string, any>[], errors: [] as string[],
    packsFail: false, favoritesFail: false, manifestFail: false, fileFail: false, sendFail: false, replyFail: false,
    deleteFail: new Set<number>(), holdFile: false, releaseFile: undefined as (() => void) | undefined,
    holdFavorites: false, releaseFavorites: undefined as (() => void) | undefined,
    writes: [] as { path: string; method: string; body: string }[],
  };
  page.on("pageerror", (error) => state.errors.push(error.message));
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url()), path = url.pathname, method = route.request().method();
    if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") return route.abort();
    if (path.startsWith("/stickers/")) {
      const item = catalog.flatMap((pack) => pack.items).find((item) => item.id === path.split("/").at(-1));
      return item ? route.fulfill({ contentType: item.mime_type, body: readFileSync(resolve(source, item.file)) }) : route.fulfill({ status: 404, body: "" });
    }
    if (!path.startsWith("/api/")) return route.continue();
    if (method !== "GET") state.writes.push({ path, method, body: route.request().postData() || "" });
    if (path === "/api/user/profile") return route.fulfill({ status: state.userId ? 200 : 401, json: state.userId ? { id: state.userId, nickname: "本地界面测试", role: "user" } : {} });
    if (path === "/api/refresh") return route.fulfill({ status: 401, json: { message: "需要登录" } });
    if (path === "/api/messages/conversations") return route.fulfill({ json: { conversations: [{ id: 1, user1_id: state.userId, user2_id: 7, user1: { id: state.userId, nickname: "本地界面测试" }, user2: { id: 7, nickname: "测试同学" } }] } });
    if (path === "/api/messages/conversations/1") return route.fulfill({ json: { messages: [] } });
    if (path === "/api/messages/events") return route.fulfill({ contentType: "text/event-stream", body: ": fixture\n\n" });
    if (path === "/api/messages/7") return route.fulfill({ status: state.sendFail ? 503 : 200, json: { message: state.sendFail ? "发送暂未完成" : "已发送" } });
    if (path === "/api/emoji/packs") return route.fulfill({ status: state.packsFail ? 503 : 200, json: state.packsFail ? { message: "官方目录暂不可用" } : catalog.map((pack) => ({ id: pack.id, name: pack.name, version: pack.version, asset_count: pack.items.length })) });
    if (path === "/api/emoji/favorites" && method === "GET") {
      if (state.holdFavorites) await new Promise<void>((done) => { state.releaseFavorites = done; });
      return route.fulfill({ status: state.favoritesFail ? 503 : 200, json: state.favoritesFail ? { message: "收藏暂不可用" } : { items: state.items, quota_used: 15360, quota_limit: 52428800 } });
    }
    if (path === "/api/emoji/favorites" && method === "POST") {
      const body = route.request().postDataJSON();
      state.items.push({ ...favorite, ...body, id: 99, favorite_id: 99 });
      return route.fulfill({ status: 201, json: state.items.at(-1) });
    }
    if (/^\/api\/emoji\/favorites\/\d+$/.test(path) && method === "DELETE") {
      const id = Number(path.split("/").at(-1));
      if (state.deleteFail.has(id)) return route.fulfill({ status: 503, json: { message: "移除暂未完成" } });
      state.items = state.items.filter((item) => Number(item.favorite_id || item.id) !== id);
      return route.fulfill({ status: 204, body: "" });
    }
    if (/^\/api\/emoji\/favorites\/\d+\/(thumbnail|file)$/.test(path)) {
      if (state.fileFail) return route.fulfill({ status: 403, body: "" });
      if (state.holdFile && path.endsWith("/file")) await new Promise<void>((done) => { state.releaseFile = done; });
      return route.fulfill({ contentType: "image/png", body: readFileSync(resolve(source, catalog[0].items[0].file)) }).catch(() => undefined);
    }
    if (path.includes("/emoji/packs/")) {
      const parts = path.split("/"), pack = catalog.find((pack) => pack.id === parts[4]);
      if (parts[5] === "manifest") return route.fulfill({ status: state.manifestFail ? 503 : 200, json: state.manifestFail ? { message: "表情内容加载失败" } : { assets: pack?.items.map((item) => ({ id: item.id, name: item.label, animated: item.mime_type === "image/gif" })) || [] } });
      const item = pack?.items.find((item) => item.id === parts[6]);
      return item ? route.fulfill({ contentType: item.mime_type, body: readFileSync(resolve(source, item.file)) }) : route.fulfill({ status: 404, body: "" });
    }
    if (path === "/api/upload_multiple") return route.fulfill({ json: { results: [{ file_id: 73 }] } });
    if (path === "/api/posts/675") return route.fulfill({ json: { post: { id: 675, board_id: 1, title: "表情交互测试", content: "本地隔离内容", author_id: 7, author: { id: 7, nickname: "测试同学" }, reply_count: 0, viewer_permissions: {} } } });
    if (path === "/api/posts/675/replies") return route.fulfill({ status: method === "POST" && state.replyFail ? 503 : 200, json: method === "POST" ? { message: state.replyFail ? "评论暂未完成" : "已发布" } : { replies: [], total: 0 } });
    return route.fulfill({ json: { items: [] } });
  });
  return state;
}
async function openPicker(page: Page) {
  await page.goto("messages"); await page.getByRole("button", { name: "选择表情", exact: true }).click();
  await expect(page.locator(".emoji-picker")).toBeVisible();
}
async function openComment(page: Page) {
  await page.goto("post/675"); await page.getByRole("button", { name: "说说你的想法，一起聊聊…", exact: true }).click();
  await page.getByLabel("写下你的回复").fill("保留这条草稿");
  await page.getByRole("button", { name: "☺ 添加表情", exact: true }).click();
}

test("收藏图片预览与私信 file_id 正确，失败保留草稿及重试身份", async ({ page }) => {
  const state = await setup(page); state.sendFail = true; await openPicker(page);
  await page.locator(".emoji-option").first().click();
  await expect(page.locator(".composer-sticker img")).toHaveAttribute("src", /\/api\/emoji\/favorites\/9\/file/);
  await page.locator(".message-composer textarea").fill("图片消息草稿");
  await page.getByRole("button", { name: "发送", exact: true }).click();
  await expect(page.locator(".toast")).toContainText("发送暂未完成");
  await expect(page.locator(".message-composer textarea")).toHaveValue("图片消息草稿");
  const first = JSON.parse(state.writes.find((write) => write.path === "/api/messages/7")!.body);
  expect(first.file_id).toBe(44); expect(first.sticker_id).toBeUndefined(); expect(first.asset_key).toBeUndefined();
  state.sendFail = false; await page.getByRole("button", { name: "发送", exact: true }).click();
  await expect(page.locator(".composer-sticker")).toHaveCount(0);
  const last = JSON.parse(state.writes.filter((write) => write.path === "/api/messages/7").at(-1)!.body);
  expect(last.client_message_id).toBe(first.client_message_id); expect(state.errors).toEqual([]);
});

test("加载与空收藏可辨认，添加图片使用实际上传编号", async ({ page }) => {
  const state = await setup(page); state.items = []; state.holdFavorites = true; await openPicker(page);
  await expect(page.locator('.emoji-picker').getByRole('status')).toContainText('正在加载表情');
  await expect.poll(() => !!state.releaseFavorites).toBe(true); state.holdFavorites = false; state.releaseFavorites!();
  await expect(page.locator('.emoji-picker')).toContainText('还没有收藏表情');
  await page.locator('.emoji-picker').getByRole('button', { name: '管理', exact: true }).click();
  await page.getByLabel('添加收藏图片', { exact: true }).setInputFiles({ name: '新增收藏.png', mimeType: 'image/png', buffer: readFileSync(resolve(source, catalog[0].items[0].file)) });
  await expect(page.locator('.emoji-notice')).toContainText('图片已添加到收藏');
  expect(JSON.parse(state.writes.find((write) => write.path === '/api/emoji/favorites' && write.method === 'POST')!.body)).toEqual({ kind: 'custom', file_id: 73 });
  await expect(page.locator('.emoji-option')).toHaveCount(1); expect(state.errors).toEqual([]);
});

test('未登录评论入口要求登录，不暴露收藏', async ({ page }) => {
  const state = await setup(page); state.userId = null; await page.goto('post/675');
  await page.getByRole('button', { name: '登录后参与讨论…', exact: true }).click();
  await expect(page.getByRole('dialog', { name: '登录沈理校园' })).toBeVisible();
  await expect(page.locator('.emoji-picker')).toHaveCount(0);
  expect(state.writes.filter((write) => write.path.includes('/emoji/') || write.path.includes('/replies'))).toHaveLength(0);
});

test("目录和资源失败有独立重试，收藏仍然可用", async ({ page }) => {
  const state = await setup(page); state.packsFail = true; state.fileFail = true; await openPicker(page);
  await expect(page.locator(".emoji-picker")).toContainText("官方表情包加载未完成");
  await expect(page.locator(".emoji-option")).toHaveCount(1);
  state.packsFail = false; await page.getByRole("button", { name: "重试官方表情包" }).click();
  await expect(page.getByRole("tab", { name: "明风 OvO", exact: true })).toBeVisible();
  await page.locator(".emoji-option").first().click();
  await expect(page.locator(".composer-sticker")).toContainText("图片暂不可用");
  state.fileFail = false; await page.locator(".composer-sticker").getByRole("button", { name: "重试图片" }).click();
  await expect(page.locator(".composer-sticker img")).toBeVisible();
  state.manifestFail = true; await page.getByRole("tab", { name: "明风 OvO", exact: true }).click();
  await expect(page.locator(".emoji-picker")).toContainText("表情内容加载失败");
  state.manifestFail = false; await page.locator(".emoji-picker").getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.locator(".emoji-option")).toHaveCount(16); expect(state.errors).toEqual([]);
});

test("收藏整理部分成功保留失败选择，撤销使用原文件身份", async ({ page }) => {
  const state = await setup(page); state.items.push({ ...favorite, id: 10, favorite_id: 10, file_id: 45 }); state.deleteFail.add(10);
  await openPicker(page); await page.locator(".emoji-picker").getByRole("button", { name: "管理", exact: true }).click();
  await page.getByRole("button", { name: "批量整理" }).click();
  await page.locator(".emoji-option").nth(0).click(); await page.locator(".emoji-option").nth(1).click();
  await page.getByRole("button", { name: "移除所选（2）" }).click();
  await expect(page.locator(".emoji-notice")).toContainText("已移除 1 个，1 个未完成");
  await expect(page.locator(".emoji-option[aria-pressed=true]")).toHaveCount(1);
  await page.getByRole("button", { name: "撤销移除" }).click();
  await expect(page.locator(".emoji-notice")).toContainText("已恢复 1 个收藏");
  expect(JSON.parse(state.writes.find((write) => write.path === "/api/emoji/favorites" && write.method === "POST")!.body)).toEqual({ kind: "custom", file_id: 44 });
  await expect(page.locator(".emoji-option")).toHaveCount(2); expect(state.errors).toEqual([]);
});

test("评论内管理与预览保留草稿，私有收藏仅在提交时转换附件，失败重用上传", async ({ page }) => {
  const state = await setup(page); await openComment(page);
  await page.locator(".emoji-picker").getByRole("button", { name: "管理", exact: true }).click();
  await page.locator(".emoji-option").first().click();
  await expect(page.getByRole("dialog", { name: "发表评论" })).toHaveCount(1);
  await page.locator('.emoji-picker').getByRole('button', { name: '返回', exact: true }).click();
  await expect(page.locator('.emoji-option').first()).toBeFocused();
  await page.locator('.emoji-option').first().click();
  await expect(page.getByLabel("写下你的回复")).toHaveValue("保留这条草稿");
  await page.getByRole("button", { name: "选择这个表情" }).click();
  expect(state.writes.filter((write) => write.path.includes("upload"))).toHaveLength(0);
  state.replyFail = true; await page.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("评论暂未完成");
  await expect(page.getByLabel("写下你的回复")).toHaveValue("保留这条草稿");
  const sent = state.writes.find((write) => write.path === "/api/posts/675/replies")!;
  expect(sent.body).toMatch(/name="file_ids"\r\n\r\n\[73\]/); expect(sent.body).not.toContain('name="sticker_id"'); expect(sent.body).not.toContain("[44]");
  state.replyFail = false; await page.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(state.writes.filter((write) => write.path === "/api/upload_multiple")).toHaveLength(1); expect(state.errors).toEqual([]);
});

test("切号中的评论读取不继续上传，旧预览及草稿立即关闭", async ({ page }) => {
  const state = await setup(page); await openComment(page); await page.locator(".emoji-option").first().click();
  state.holdFile = true; await page.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect.poll(() => !!state.releaseFile).toBe(true);
  state.userId = 8; await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  await expect(page.getByRole("dialog")).toHaveCount(0); state.releaseFile!();
  await expect(page.locator(".toast")).not.toContainText("回复已发布");
  expect(state.writes.filter((write) => write.path === "/api/upload_multiple" || write.path === "/api/posts/675/replies")).toHaveLength(0);
});

test("紧凑列表实际渲染：明暗、窄屏、大字号、44px 控件与键盘分类", async ({ page }) => {
  test.setTimeout(120000); const state = await setup(page); await openPicker(page);
  const evidence = process.env.EMOJI_EVIDENCE_DIR; if (evidence) mkdirSync(evidence, { recursive: true });
  for (const dark of [false, true]) for (const width of [320, 375, 600, 768, 1440]) for (const scale of [1, 1.3, 1.5]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.evaluate(({ dark, scale }) => { document.documentElement.dataset.theme = dark ? "dark" : "light"; document.documentElement.style.fontSize = `${16 * scale}px`; }, { dark, scale });
    await page.locator(".emoji-picker").getByRole("button", { name: "管理", exact: true }).click();
    await page.getByRole("tab", { name: "官方表情包", exact: true }).click();
    await expect(page.locator(".emoji-pack-row")).toHaveCount(4);
    // CSS 采用 px 字号；必须实际放大文字，不能只修改根字号冒充大字号验收。
    await page.locator(".emoji-picker").evaluate((root, scale) => {
      const elements = [root, ...root.querySelectorAll<HTMLElement>("*")].filter((item): item is HTMLElement => item instanceof HTMLElement);
      const bases = elements.map((item) => {
        const base = Number(item.dataset.emojiFontBase || parseFloat(getComputedStyle(item).fontSize));
        item.dataset.emojiFontBase = String(base); return base;
      });
      elements.forEach((item, i) => { item.style.fontSize = `${bases[i] * scale}px`; });
    }, scale);
    expect(await page.locator(".emoji-pack-copy b").first().evaluate((item) => parseFloat(getComputedStyle(item).fontSize))).toBeCloseTo(14 * scale);
    const failures = await page.locator(".emoji-picker").evaluate((root) => {
      const bounds = root.getBoundingClientRect();
      const errors: string[] = [];
      if (root.scrollWidth > root.clientWidth + 1) errors.push("panel overflow");
      for (const button of root.querySelectorAll("button:not(:disabled)")) {
        const rect = button.getBoundingClientRect();
        if (rect.width < 44 || rect.height < 44) errors.push(`small control ${button.textContent}`);
        if (rect.left < bounds.left - 1 || rect.right > bounds.right + 1) errors.push(`clipped control ${button.textContent}`);
      }
      return errors;
    });
    expect(failures, `${dark}/${width}/${scale}`).toEqual([]);
    if (evidence && width === 375 && (scale === 1 || (!dark && scale === 1.5))) await page.locator(".emoji-picker").screenshot({ path: resolve(evidence, `after-web-managed-${dark ? "dark" : scale === 1.5 ? "large" : "light"}.png`) });
    await page.getByRole("button", { name: "返回选择" }).click();
  }
  await page.getByRole("tab", { name: "我的收藏", exact: true }).focus();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("tab", { name: "明风·日常", exact: true })).toHaveAttribute("aria-selected", "true");
  await expect(page.locator(".emoji-option")).toHaveCount(16);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  // 全站减少动态效果规则使用 0.001ms；验证没有可见过渡，不要求特定序列化字符串。
  expect(await page.locator('.emoji-option').first().evaluate((item) => Math.max(...getComputedStyle(item).transitionDuration.split(',').map(parseFloat)))).toBeLessThanOrEqual(.00001);
  if (evidence) await page.locator(".emoji-picker").screenshot({ path: resolve(evidence, "after-web-picker-dark.png") });
  expect(state.errors).toEqual([]);
});
