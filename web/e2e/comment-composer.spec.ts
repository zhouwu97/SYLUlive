import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==", "base64");
const sticker = readFileSync("server/internal/handlers/sticker_assets/catalog.json", "utf8");
const pack = JSON.parse(sticker)[0];
const post = { id: 936, board_id: 1, title: "周末一起去图书馆吗", content: "期末复习开始啦，准备周六上午去图书馆。\n有没有同学一起？可以互相分享复习资料。", author_id: 7, author: { id: 7, nickname: "林同学", followers_count: 12 }, like_count: 3, reply_count: 2, created_at: "2026-11-16T07:28:00+08:00", viewer_permissions: {} };
const root = { id: 101, author_id: 8, author: { nickname: "小雨" }, content: "我也准备去！几点集合？", like_count: 1, child_reply_count: 1, created_at: "2026-11-16T07:38:00+08:00" };
const child = { id: 102, parent_reply_id: 101, author_id: 7, author: { nickname: "林同学" }, content: "@小雨 @路人 九点在一楼门口见～", mentions: [{ user_id: 8, nickname: "小雨" }], created_at: "2026-11-16T08:15:00+08:00" };

async function setup(page: Page) {
  const state = { userId: 3 as number | null, failReply: false, rulesRequired: false, failUpload: false, holdReply: false, holdUpload: false, release: () => {}, writes: [] as { path: string; body: string }[], errors: [] as string[] };
  page.on("pageerror", error => state.errors.push(error.message));
  await page.route("**/*", async route => {
    const { hostname, pathname: path } = new URL(route.request().url());
    if (!["localhost", "127.0.0.1"].includes(hostname)) return route.abort();
    if (path.startsWith("/stickers/")) return route.fulfill({ contentType: pack.items[0].mime_type, body: readFileSync(`server/internal/handlers/sticker_assets/${pack.items[0].file}`) });
    if (!path.startsWith("/api/")) return route.continue();
    const method = route.request().method();
    if (method !== "GET") state.writes.push({ path, body: route.request().postData() || "" });
    if (path === "/api/user/profile") return route.fulfill({ status: state.userId ? 200 : 401, json: state.userId ? { id: state.userId, nickname: "纯合子", role: "user" } : {} });
    if (path === "/api/refresh") return route.fulfill({ status: 401, json: {} });
    if (/^\/api\/posts\/\d+$/.test(path)) return route.fulfill({ json: { post: { ...post, id: Number(path.split("/").at(-1)) } } });
    if (path === "/api/posts") return route.fulfill({ json: { posts: [937, 938, 939].map((id, index) => ({ ...post, id, title: ["校园跑步搭子集合", "分享一下这周的校园日常", "求推荐好吃的食堂窗口"][index] })) } });
    if (path === "/api/posts/936/replies" && method === "POST") {
      if (state.holdReply) await new Promise<void>(resolve => { state.release = resolve; });
      return route.fulfill({ status: state.failReply ? 400 : state.rulesRequired ? 403 : 200, json: state.failReply ? { message: "评论暂未完成，请重试" } : state.rulesRequired ? { code: "community_rules_required", message: "请先确认社区规则" } : { reply: { id: 103 } } });
    }
    if (path.endsWith("/replies")) return route.fulfill({ json: { replies: [root, child], total: 2 } });
    if (path === "/api/upload_multiple") {
      if (state.holdUpload) await new Promise<void>(resolve => { state.release = resolve; });
      return route.fulfill({ status: state.failUpload ? 400 : 200, json: state.failUpload ? { message: "图片上传未完成" } : { results: [{ file_id: 73 }] } });
    }
    if (path === "/api/user/community-rules") { state.rulesRequired = false; return route.fulfill({ json: {} }); }
    if (path === "/api/emoji/packs") return route.fulfill({ json: [{ id: pack.id, name: pack.name, version: pack.version }] });
    if (path === "/api/emoji/favorites") return route.fulfill({ json: { items: [{ id: 9, favorite_id: 9, kind: "builtin", sticker_id: pack.items[0].id, name: "开心" }] } });
    if (path.includes("/emoji/packs/") && path.endsWith("/manifest")) return route.fulfill({ json: { assets: pack.items.map((item: { id: string; label: string }) => ({ id: item.id, name: item.label })) } });
    if (path.includes("/emoji/") && !path.endsWith("/manifest")) return route.fulfill({ contentType: pack.items[0].mime_type, body: readFileSync(`server/internal/handlers/sticker_assets/${pack.items[0].file}`) });
    return route.fulfill({ json: { items: [] } });
  });
  return state;
}

async function open(page: Page) {
  await page.goto("post/936");
  await page.getByRole("button", { name: "说说你的想法，一起聊聊…", exact: true }).click();
  return page.locator(".post-comment-input .reply-inline-composer");
}

test("评论只把真实被 @ 的昵称渲染成主页链接", async ({ page }) => {
  const state = await setup(page);
  await page.goto("post/936");
  const comment = page.getByRole("article", { name: "林同学的评论" });
  await expect(comment.locator(".comment-mention")).toHaveCount(1);
  await expect(comment.getByRole("link", { name: "@小雨", exact: true })).toHaveAttribute("href", /\/user\/8$/);
  await expect(comment.getByText("@路人", { exact: false })).toBeVisible();
  expect(state.errors).toEqual([]);
});

test("桌面评论原地展开，收起保留草稿与焦点，快捷键只发送一次", async ({ page }) => {
  const state = await setup(page);
  const editor = await open(page), input = editor.getByLabel("写下你的回复");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(editor.getByRole("button", { name: "发布评论", exact: true })).toBeDisabled();
  await expect(input).toBeFocused();
  await input.fill("周六九点见！");
  await input.dispatchEvent("keydown", { key: "Enter", ctrlKey: true, isComposing: true });
  expect(state.writes.filter(item => item.path.endsWith("/replies"))).toHaveLength(0);
  await input.press("Escape");
  const trigger = page.getByRole("button", { name: "说说你的想法，一起聊聊…", exact: true });
  await expect(trigger).toBeFocused();
  await trigger.click(); await expect(input).toHaveValue("周六九点见！");
  state.failReply = true;
  await input.press("Control+Enter");
  await expect(editor.getByRole("alert")).toContainText("评论暂未完成");
  await expect(input).toHaveValue("周六九点见！");
  state.failReply = false; state.holdReply = true;
  await input.press("Control+Enter");
  await expect(editor.getByRole("button", { name: "正在提交…" })).toBeDisabled();
  await page.keyboard.press("Control+Enter");
  expect(state.writes.filter(item => item.path.endsWith("/replies"))).toHaveLength(2);
  state.release();
  await expect(editor).toHaveCount(0); await expect(trigger).toBeVisible();
  await trigger.click(); await expect(input).toHaveValue("");
  expect(state.errors).toEqual([]);
});

test("楼中楼原位回复，内容与目标正确，主评论草稿互不覆盖", async ({ page }) => {
  const state = await setup(page), main = await open(page);
  await main.getByLabel("写下你的回复").fill("主评论草稿");
  const row = page.getByRole("article", { name: "林同学的评论" });
  await row.getByRole("button", { name: "回复", exact: true }).click();
  const editor = row.locator(".reply-inline-composer");
  await expect(editor).toContainText("回复 林同学");
  await expect(editor.getByLabel("写下你的回复")).toBeFocused();
  await editor.getByLabel("写下你的回复").fill("收到，门口见");
  await editor.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect(editor).toHaveCount(0);
  expect(state.writes.at(-1)?.body).toMatch(/name="parent_reply_id"\r\n\r\n101/);
  expect(state.writes.at(-1)?.body).toMatch(/name="reply_to_reply_id"\r\n\r\n102/);
  expect(state.writes.at(-1)?.body).toMatch(/name="reply_to_user_id"\r\n\r\n7/);
  await expect(main.getByLabel("写下你的回复")).toHaveValue("主评论草稿");
  expect(state.errors).toEqual([]);
});

test("图片按需选择，校验与上传失败保留草稿，收起后图片仍在", async ({ page }) => {
  const state = await setup(page), editor = await open(page);
  const fileInput = editor.getByLabel("选择图片", { exact: true });
  await expect(editor.locator(".media-upload-drop")).toBeHidden();
  await fileInput.setInputFiles({ name: "说明.txt", mimeType: "text/plain", buffer: Buffer.from("invalid") });
  await expect(editor.getByRole("alert")).toContainText("仅支持 png、jpeg、gif 图片");
  await fileInput.setInputFiles({ name: "复习资料.png", mimeType: "image/png", buffer: png });
  await expect(editor.locator(".media-upload-item")).toHaveCount(1);
  await editor.getByLabel("写下你的回复").fill("图片草稿");
  await editor.getByRole("button", { name: "收起", exact: true }).click();
  await page.getByRole("button", { name: "说说你的想法，一起聊聊…", exact: true }).click();
  await expect(editor.locator(".media-upload-item")).toHaveCount(1);
  state.failUpload = true;
  await editor.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect(editor.getByRole("alert")).toContainText("图片上传未完成");
  expect(state.writes.filter(item => item.path.endsWith("/replies"))).toHaveLength(0);
  state.failUpload = false;
  await editor.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect(editor).toHaveCount(0);
  expect(state.writes.at(-1)?.body).toMatch(/name="file_ids"\r\n\r\n\[73\]/);
  expect(state.errors).toEqual([]);
});

test("规则确认保留内容且不自动重放，切号中止旧上传与草稿", async ({ page }) => {
  const state = await setup(page), editor = await open(page);
  await editor.getByLabel("写下你的回复").fill("规则确认前的草稿");
  state.rulesRequired = true;
  await editor.getByRole("button", { name: "发布评论", exact: true }).click();
  await editor.getByRole("button", { name: "我已阅读并同意社区规则" }).click();
  await expect(editor.getByRole("alert")).toContainText("请重新提交");
  await expect(editor.getByLabel("写下你的回复")).toHaveValue("规则确认前的草稿");
  expect(state.writes.filter(item => item.path.endsWith("/replies"))).toHaveLength(1);
  await editor.getByLabel("选择图片", { exact: true }).setInputFiles({ name: "test.png", mimeType: "image/png", buffer: png });
  state.holdUpload = true;
  await editor.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect.poll(() => state.writes.filter(item => item.path.includes("upload")).length).toBe(1);
  state.userId = 8;
  await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  await expect(editor).toHaveCount(0);
  state.release();
  await page.getByRole("button", { name: "说说你的想法，一起聊聊…", exact: true }).click();
  await expect(editor.getByLabel("写下你的回复")).toHaveValue("");
  expect(state.writes.filter(item => item.path.endsWith("/replies"))).toHaveLength(1);
  expect(state.errors).toEqual([]);
});

test("表情在编辑器下方打开，Escape 返回工具栏，实际明暗与窄桌面无溢出", async ({ page }) => {
  const state = await setup(page);
  for (const theme of ["light", "dark"]) {
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    for (const width of [1568, 1280, 768, 601]) {
      await page.setViewportSize({ width, height: 1000 });
      const editor = await open(page);
      await editor.getByLabel("写下你的回复").fill("周六九点见，一起复习～");
      await editor.getByRole("button", { name: "添加表情", exact: true }).click();
      await expect(editor.getByRole("region", { name: "选择评论表情" })).toBeVisible();
      const panel = editor.getByRole("region", { name: "选择评论表情" });
      await panel.locator(".emoji-option img").first().evaluate(async (img: HTMLImageElement) => { await img.decode(); });
      // 实际命中检查能发现父级 overflow:hidden 裁切，不能只依赖 DOM 可见性。
      const option = panel.locator(".emoji-option").first();
      await option.scrollIntoViewIfNeeded();
      expect(await option.evaluate(el => { const box = el.getBoundingClientRect(); return el.contains(document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)); })).toBe(true);
      await expect(page.getByRole("dialog")).toHaveCount(0);
      await page.keyboard.press("Escape");
      await expect(editor.getByRole("button", { name: "添加表情", exact: true })).toBeFocused();
      await expect(editor.getByLabel("写下你的回复")).toHaveValue("周六九点见，一起复习～");
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      const size = await editor.boundingBox();
      if (width === 1568) {
        await page.screenshot({ path: `.codex-captures/comment-composer/${theme}-inline.png`, fullPage: true });
        await editor.getByRole("button", { name: "添加表情", exact: true }).click();
        await page.screenshot({ path: `.codex-captures/comment-composer/${theme}-emoji.png`, fullPage: true });
      }
      expect(size!.height).toBeLessThan(140);
    }
  }
  expect(state.errors).toEqual([]);
});

test("手机保留底部入口和原弹框，游客先登录", async ({ page }) => {
  const state = await setup(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("post/936");
  await page.getByRole("button", { name: "写下你的想法…", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "发表评论" })).toBeVisible();
  await expect(page.locator(".reply-inline-composer")).toHaveCount(0);
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  state.userId = null;
  await page.setViewportSize({ width: 1440, height: 1000 }); await page.reload();
  await page.getByRole("button", { name: "登录后参与讨论…", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园" })).toBeVisible();
  expect(state.writes.filter(item => item.path.endsWith("/replies"))).toHaveLength(0);
  expect(state.errors).toEqual([]);
});

test("长文可滚动编辑，大字号下工具栏和楼中楼不溢出", async ({ page }) => {
  const state = await setup(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  for (const width of [601, 1280, 1568]) {
    await page.setViewportSize({ width, height: 1000 });
    const main = await open(page);
    await main.getByLabel("写下你的回复").fill(Array(24).fill("一起复习，互相分享资料。\n").join(""));
    const input = main.getByLabel("写下你的回复");
    expect((await input.boundingBox())!.height).toBeLessThanOrEqual(200);
    expect(await input.evaluate(el => el.scrollHeight > el.clientHeight)).toBe(true);
    const row = page.getByRole("article", { name: "林同学的评论" });
    await row.getByRole("button", { name: "回复", exact: true }).click();
    await row.getByLabel("写下你的回复").fill("这是放大字号后的回复。");
    await page.locator(".reply-inline-composer").evaluateAll(editors => {
      for (const editor of editors) {
        const nodes = [...editor.querySelectorAll<HTMLElement>("textarea,button,span")];
        const sizes = nodes.map(node => parseFloat(getComputedStyle(node).fontSize));
        nodes.forEach((node, index) => { node.style.fontSize = `${sizes[index] * 1.3}px`; });
      }
    });
    for (const editor of [main, row.locator(".reply-inline-composer")]) {
      expect(await editor.evaluate(el => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
      expect(await editor.locator("button").evaluateAll(buttons => buttons.filter(el => el.getClientRects().length).every(el => { const box = el.getBoundingClientRect(), frame = el.closest("fieldset")!.getBoundingClientRect(); return box.left >= frame.left && box.right <= frame.right; }))).toBe(true);
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});
