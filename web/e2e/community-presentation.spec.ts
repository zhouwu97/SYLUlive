import { test, expect, type Page } from "@playwright/test";

const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900"><rect width="600" height="900" fill="#d8eee9"/><circle cx="300" cy="320" r="130" fill="#147c72"/><text x="300" y="620" text-anchor="middle" font-size="42" fill="#0e625b">UI TEST</text></svg>';
function reply(id: number, nickname: string, parent: number | null = null) {
  return { id, author_id: id + 10, author: { nickname, avatar: "/uploads/e2e-avatar.svg" }, parent_reply_id: parent, content: `${nickname}的讨论内容`, created_at: "2026-10-08T10:30:00+08:00", status: "normal", like_count: 0, is_liked: false, child_reply_count: 0 };
}
async function setup(page: Page, options: { guest?: boolean; owner?: boolean; bookmarked?: boolean } = {}) {
  const root = { ...reply(101, "林同学"), child_reply_count: 3 };
  const children = [reply(102, "小雨", 101), reply(103, "阿青", 101), reply(104, "小周", 101)];
  const deleted = { ...reply(201, "已删除的同学"), status: "deleted", child_reply_count: 1 };
  const post = { id: 675, board_id: 1, title: "社区展示测试", content: "一起讨论校园学习与生活。图片和操作栏使用同一阅读宽度。", author_id: 7, author: { id: 7, nickname: "林同学", avatar: "/uploads/e2e-avatar.svg", level: 3, followers_count: 12 }, created_at: "2026-10-08T09:00:00+08:00", like_count: 4, reply_count: 7, is_liked: false, images: [{ id: 1, thumb_url: "/uploads/e2e-post.svg", origin_url: "/uploads/e2e-post.svg", width: 600, height: 900 }], viewer_permissions: { can_edit: !!options.owner, can_delete: !!options.owner } };
  const state = {
    post, root, children, deleted, errors: [] as string[],
    writes: [] as { path: string; method: string; body: string }[],
    bookmarkIDs: options.bookmarked ? [...Array.from({ length: 50 }, (_, index) => 700 + index), 675] : [] as number[],
    bookmarkPages: [] as number[], bookmarkFail: false, likeFail: false, followFail: false, childrenFail: false,
    commentsMode: "filled", postFail: false, thumbFail: false,
    relatedMode: "filled", relatedPosts: [676, 677, 678].map((id) => ({ ...post, id, title: `校园讨论 ${id}`, content: "更多校园学习和生活的讨论。" })),
    nextPageFail: false, paginate: false,
    releaseLike: undefined as (() => void) | undefined,
    holdLike: false, userID: options.guest ? null : 3 as number | null,
  };
  page.on("pageerror", (error) => state.errors.push(error.message));
  await page.route("**/uploads/e2e-*.svg", async (route) => {
    if (state.thumbFail && route.request().url().endsWith("e2e-post.svg")) return route.fulfill({ status: 503, body: "" });
    await route.fulfill({ contentType: "image/svg+xml", body: svg });
  });
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url()), path = url.pathname, method = route.request().method();
    if (path === "/api/user/profile") return route.fulfill({ json: state.userID ? { id: state.userID, nickname: `测试用户${state.userID}`, role: "user" } : {}, status: state.userID ? 200 : 401 });
    if (path === "/api/refresh") return route.fulfill({ status: 401, json: { message: "未登录" } });
    if (method !== "GET") state.writes.push({ path, method, body: route.request().postData() || "" });
    if (path === "/api/user/7/follow") {
      if (state.followFail) return route.fulfill({ status: 503, json: { message: "关注暂时失败" } });
      state.post.author.followers_count += method === "POST" ? 1 : -1;
      return route.fulfill({ json: { message: "已更新关注" } });
    }
    if (path === "/api/posts/675/like") {
      const actorID = state.userID;
      if (state.holdLike) await new Promise<void>((resolve) => { state.releaseLike = resolve; });
      if (state.likeFail) return route.fulfill({ status: 503, json: { message: "点赞暂时失败，请重试" } });
      if (actorID === state.userID) state.post.is_liked = method === "POST";
      state.post.like_count = method === "POST" ? 5 : 4;
      return route.fulfill({ json: { message: "已更新" } });
    }
    if (path === "/api/posts/675/bookmark") {
      state.bookmarkIDs = method === "PUT" ? [...new Set([...state.bookmarkIDs, 675])] : state.bookmarkIDs.filter((id) => id !== 675);
      return route.fulfill({ json: { bookmarked: method === "PUT" } });
    }
    if (path === "/api/user/bookmarks") {
      if (state.bookmarkFail) return route.fulfill({ status: 503, json: { message: "读取收藏失败" } });
      const pageNumber = Number(url.searchParams.get("page") || 1);
      const limit = Number(url.searchParams.get("limit") || 20);
      state.bookmarkPages.push(pageNumber);
      return route.fulfill({ json: { posts: state.bookmarkIDs.slice((pageNumber - 1) * limit, pageNumber * limit).map((id) => ({ ...state.post, id })), has_more: pageNumber * limit < state.bookmarkIDs.length } });
    }
    if (path === "/api/posts" && url.searchParams.get("limit") === "5") {
      if (state.relatedMode === "error") return route.fulfill({ status: 503, json: { message: "更多帖子加载失败" } });
      if (state.relatedMode === "slow") await new Promise((resolve) => setTimeout(resolve, 700));
      return route.fulfill({ json: { posts: state.relatedMode === "empty" ? [] : [state.post, ...state.relatedPosts], has_more: false } });
    }
    if (path === "/api/posts") return route.fulfill({ json: { posts: [state.post], has_more: false } });
    if (path === "/api/posts/675") return route.fulfill({ status: state.postFail ? 503 : 200, json: state.postFail ? { message: "帖子加载失败" } : { post: state.post } });
    if (/^\/api\/posts\/\d+$/.test(path)) return route.fulfill({ json: { post: state.relatedPosts.find((item) => item.id === Number(path.split("/").at(-1))) } });
    if (path === "/api/posts/675/replies/101/children") {
      if (state.childrenFail) return route.fulfill({ status: 503, json: { message: "楼中楼加载失败" } });
      return route.fulfill({ json: { replies: url.searchParams.has("cursor") ? state.children.slice(3) : state.children.slice(0, 3), next_cursor: state.children.length > 3 && !url.searchParams.has("cursor") ? "next-child" : "" } });
    }
    if (/^\/api\/replies\/\d+\/like$/.test(path)) {
      const id = Number(path.split("/")[3]);
      const target = [state.root, ...state.children].find((item) => item.id === id)!;
      target.is_liked = method === "POST"; target.like_count = method === "POST" ? 1 : 0;
      return route.fulfill({ json: { message: "已更新" } });
    }
    if (path === "/api/posts/675/replies" && method === "POST") {
      state.children.push(reply(105, "新回复", 101)); state.root.child_reply_count += 1; state.post.reply_count += 1;
      return route.fulfill({ json: { reply: state.children.at(-1) } });
    }
    if (path === "/api/posts/675/replies") {
      if (state.commentsMode === "error") return route.fulfill({ status: 503, json: { message: "评论加载失败" } });
      if (state.commentsMode === "slow") await new Promise((resolve) => setTimeout(resolve, 700));
      if (state.commentsMode === "empty") return route.fulfill({ json: { replies: [], total: 0 } });
      if (url.searchParams.has("cursor")) return route.fulfill({ status: state.nextPageFail ? 503 : 200, json: state.nextPageFail ? { message: "下一页评论加载失败" } : { replies: [reply(301, "下一页同学")], total: state.post.reply_count } });
      return route.fulfill({ json: { replies: [state.root, ...state.children.slice(0, 2), state.deleted, reply(202, "保留的讨论", 201)], total: state.post.reply_count, next_cursor: state.paginate ? "next-root" : "" } });
    }
    return route.fulfill({ status: method === "GET" ? 200 : 501, json: method === "GET" ? { items: [] } : { message: "测试未预期的写请求" } });
  });
  return state;
}

test("列表互动有可读标签，点赞等待时阻止重复提交，失败后可恢复", async ({ page }) => {
  const state = await setup(page);
  await page.goto("community");
  const actions = page.getByRole("group", { name: "帖子互动" });
  await expect(actions.getByRole("button", { name: "收藏", exact: true })).toBeEnabled();
  await expect(actions.getByRole("link", { name: "评论 7" })).toBeVisible();
  state.holdLike = true;
  const like = actions.getByRole("button", { name: "点赞 4", exact: true });
  await like.click();
  await expect(like).toBeDisabled();
  await expect(like).toHaveAttribute("aria-busy", "true");
  await expect.poll(() => state.releaseLike !== undefined).toBe(true);
  expect(state.writes.filter((item) => item.path.endsWith("/like"))).toHaveLength(1);
  state.holdLike = false; state.releaseLike!();
  const liked = actions.getByRole("button", { name: "已赞 5", exact: true });
  await expect(liked).toHaveAttribute("aria-pressed", "true");
  await expect(liked).toBeEnabled();
  state.likeFail = true;
  await liked.click();
  await expect(page.locator(".toast")).toContainText("点赞暂时失败");
  await expect(liked).toBeEnabled();
  await expect(liked).toHaveAttribute("aria-pressed", "true");
  state.likeFail = false;
  await liked.click();
  await expect(like).toHaveAttribute("aria-pressed", "false");
  expect(state.errors).toEqual([]);
});

test("第二页收藏正确回读，取消与重新收藏使用真实状态", async ({ page }) => {
  const state = await setup(page, { bookmarked: true });
  await page.goto("post/675");
  const actions = page.getByRole("group", { name: "帖子互动" });
  const saved = actions.getByRole("button", { name: "已收藏", exact: true });
  await expect(saved).toBeEnabled();
  expect(state.bookmarkPages).toContain(2);
  await saved.click();
  const save = actions.getByRole("button", { name: "收藏", exact: true });
  await expect(save).toBeEnabled();
  expect(state.writes.at(-1)?.method).toBe("DELETE");
  await save.click();
  await expect(saved).toHaveAttribute("aria-pressed", "true");
  expect(state.writes.at(-1)?.method).toBe("PUT");
  expect(state.errors).toEqual([]);
});

test("分享复制成功，拒绝剪贴板时提供可选中链接且不发送 API 写入", async ({ page }) => {
  const state = await setup(page);
  await page.addInitScript(() => Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async () => { throw new Error("denied"); } } }));
  await page.goto("post/675");
  await page.getByRole("button", { name: "分享", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "分享帖子" });
  await expect(dialog.getByLabel("帖子链接")).toHaveValue("http://127.0.0.1:5173/web/post/675");
  await expect(dialog.getByLabel("帖子链接")).toHaveAttribute("readonly");
  await dialog.getByRole("button", { name: "关闭", exact: true }).press("Escape");
  await expect(dialog).toHaveCount(0);
  await page.evaluate(() => Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async (text: string) => { sessionStorage.setItem("copied-post", text); } } }));
  await page.getByRole("button", { name: "分享", exact: true }).click();
  await expect(page.locator(".toast")).toContainText("帖子链接已复制");
  expect(await page.evaluate(() => sessionStorage.getItem("copied-post"))).toContain("/web/post/675");
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});

test("评论入口定位讨论区，返回保留列表筛选；更多操作支持键盘关闭与权限", async ({ page }) => {
  const state = await setup(page);
  await page.goto("community?sort=time&q=校园");
  await page.getByRole("link", { name: "评论 7" }).click();
  await expect(page).toHaveURL(/post\/675#post-comments$/);
  await expect(page.getByRole("region", { name: "评论区" })).toBeFocused();
  expect(await page.locator(".post-comments-head").evaluate((element) => element.getBoundingClientRect().top >= document.querySelector(".topbar")!.getBoundingClientRect().bottom)).toBe(true);
  await page.locator(".post-more summary").press("Enter");
  await expect(page.getByRole("button", { name: "举报", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "编辑", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "删除", exact: true })).toHaveCount(0);
  await page.locator(".post-more summary").press("Escape");
  await expect(page.locator(".post-more")).not.toHaveAttribute("open");
  await page.getByRole("button", { name: "返回列表", exact: true }).click();
  await expect(page).toHaveURL((url) => url.pathname.endsWith("/community") && url.searchParams.get("sort") === "time" && url.searchParams.get("q") === "校园");
  expect(state.errors).toEqual([]);
});

test("楼中楼不重复，已删除评论保留讨论，子回复点赞与精确回复目标正确", async ({ page }) => {
  const state = await setup(page);
  await page.goto("post/675");
  await expect(page.getByText("该评论已删除", { exact: true })).toBeVisible();
  await expect(page.getByText("保留的讨论的讨论内容", { exact: true })).toBeVisible();
  await expect(page.getByRole("article", { name: "已删除的同学的评论" }).getByRole("button")).toHaveCount(0);
  state.childrenFail = true;
  await page.getByRole("button", { name: "展开其余 1 条回复" }).click();
  await expect(page.getByText("楼中楼加载失败", { exact: true })).toBeVisible();
  await expect(page.getByRole("article", { name: "小雨的评论" })).toHaveCount(1);
  state.childrenFail = false;
  await page.getByRole("button", { name: "重试", exact: true }).click();
  const child = page.getByRole("article", { name: "小周的评论" });
  await expect(child).toHaveCount(1);
  await child.getByRole("button", { name: "点赞小周的评论，0赞", exact: true }).click();
  await expect(child.getByRole("button", { name: "取消点赞小周的评论，1赞" })).toBeEnabled();
  await child.getByRole("button", { name: "回复", exact: true }).click();
  await page.getByLabel("写下你的回复").fill("本地隔离测试回复");
  await page.getByRole("button", { name: "发布评论", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  const submission = state.writes.find((item) => item.path === "/api/posts/675/replies")!;
  expect(submission.body).toMatch(/name="parent_reply_id"\r\n\r\n101/);
  expect(submission.body).toMatch(/name="reply_to_reply_id"\r\n\r\n104/);
  expect(submission.body).toMatch(/name="reply_to_user_id"\r\n\r\n114/);
  await expect(page.getByRole("heading", { name: "全部评论 8" })).toBeVisible();
  await page.getByRole("button", { name: "加载更多回复", exact: true }).click();
  await expect(page.getByRole("article", { name: "新回复的评论" })).toHaveCount(1);
  await expect(page.getByRole("article", { name: "小雨的评论" })).toHaveCount(1);
  expect(state.errors).toEqual([]);
});

test("评论加载、空态、失败重试以及分页失败保留已读内容", async ({ page }) => {
  const state = await setup(page); state.commentsMode = "slow";
  await page.goto("post/675");
  await expect(page.getByRole("region", { name: "评论区" }).getByRole("status")).toContainText("正在加载");
  await expect(page.getByRole("article", { name: "林同学的评论" })).toBeVisible();
  state.commentsMode = "error";
  await page.getByLabel("评论排序").selectOption("latest");
  await expect(page.getByText("评论加载失败", { exact: true })).toBeVisible();
  state.commentsMode = "empty";
  await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.getByRole("heading", { name: "还没有评论" })).toBeVisible();
  state.commentsMode = "filled"; state.paginate = true;
  await page.reload();
  await page.getByRole("button", { name: "加载更多评论", exact: true }).click();
  await expect(page.getByRole("article", { name: "下一页同学的评论" })).toBeVisible();
  await page.reload(); state.nextPageFail = true;
  await page.getByRole("button", { name: "加载更多评论", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("下一页评论加载失败");
  await expect(page.getByRole("article", { name: "林同学的评论" })).toBeVisible();
  state.nextPageFail = false;
  await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.getByRole("article", { name: "下一页同学的评论" })).toHaveCount(1);
  expect(state.errors).toEqual([]);
});

test("游客点赞与回复先登录，所有操作不会未经登录发送写请求", async ({ page }) => {
  const state = await setup(page, { guest: true });
  await page.goto("post/675");
  await page.getByRole("button", { name: "点赞 4", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园" })).toBeVisible();
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.getByRole("button", { name: "登录后参与讨论…", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园" })).toBeVisible();
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});

test("桌面与手机互动栏不溢出，点击区域足够，图片失败能重试和预览", async ({ page }) => {
  const state = await setup(page); state.thumbFail = true;
  await page.goto("post/675");
  await expect(page.getByText("图片加载失败 · 点击重试", { exact: true })).toBeVisible();
  state.thumbFail = false;
  await page.getByRole("button", { name: "社区展示测试第 1 张", exact: true }).click();
  await expect(page.locator(".post-detail-gallery img")).toBeVisible();
  await page.getByRole("button", { name: "社区展示测试第 1 张", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "图片预览" })).toBeVisible();
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  for (const width of [1900, 1440, 1040, 390, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    const geometry = await page.locator(".post-toolbar").evaluate((element) => {
      const bounds = element.getBoundingClientRect();
      return [...element.querySelectorAll("button,summary")].filter((item) => item.getBoundingClientRect().height > 0).map((item) => { const box = item.getBoundingClientRect(); return { inside: box.left >= bounds.left - 1 && box.right <= bounds.right + 1, height: box.height }; });
    });
    expect(geometry.every((item) => item.inside && item.height >= 44)).toBe(true);
    expect(await page.locator("#mainContent").evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
    expect(await page.locator(".post-detail-main").evaluate((element) => element.getBoundingClientRect().width)).toBeLessThanOrEqual(860);
    await page.getByRole("button", { name: "切换主题" }).click();
    await page.getByRole("button", { name: "评论 7", exact: true }).click();
    await expect(page.getByRole("region", { name: "评论区" })).toBeFocused();
    expect(await page.locator(".post-comments-head").evaluate((element) => element.getBoundingClientRect().top >= document.querySelector(".topbar")!.getBoundingClientRect().bottom)).toBe(true);
  }
  expect(state.errors).toEqual([]);
});

test("管理操作继续按服务端权限显示，并保留删除确认", async ({ page }) => {
  const state = await setup(page, { owner: true });
  await page.goto("post/675");
  await page.locator(".post-more summary").click();
  await expect(page.getByRole("button", { name: "编辑", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "删除", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "删除内容" })).toBeVisible();
  await expect(page.getByRole("button", { name: "确认删除", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(page.locator(".post-more summary")).toBeFocused();
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});

test("收藏读取失败保留重试，恢复读取后才允许切换收藏", async ({ page }) => {
  const state = await setup(page); state.bookmarkFail = true;
  await page.goto("post/675");
  const retry = page.getByRole("button", { name: "重试收藏", exact: true });
  await expect(retry).toBeEnabled();
  await retry.click();
  await expect(page.locator(".toast")).toContainText("读取收藏失败");
  await expect(retry).toBeEnabled();
  expect(state.writes).toEqual([]);
  state.bookmarkFail = false;
  await retry.click();
  const save = page.getByRole("group", { name: "帖子互动" }).getByRole("button", { name: "收藏", exact: true });
  await expect(save).toBeEnabled();
  await save.click();
  await expect(page.getByRole("button", { name: "已收藏", exact: true })).toBeEnabled();
  expect(state.writes).toHaveLength(1); expect(state.errors).toEqual([]);
});

test("切换账号会隔离正在等待的点赞和收藏状态", async ({ page }) => {
  const state = await setup(page, { bookmarked: true });
  await page.goto("post/675");
  await expect(page.getByRole("button", { name: "已收藏", exact: true })).toBeEnabled();
  state.holdLike = true;
  await page.getByRole("button", { name: "点赞 4", exact: true }).click();
  await expect.poll(() => state.releaseLike !== undefined).toBe(true);
  state.userID = 8; state.bookmarkIDs = [];
  await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  const actions = page.getByRole("group", { name: "帖子互动" });
  await expect(actions.getByRole("button", { name: "收藏", exact: true })).toBeEnabled();
  await expect(actions.getByRole("button", { name: "点赞 4", exact: true })).toBeEnabled();
  state.holdLike = false; state.releaseLike!();
  await expect(actions.getByRole("button", { name: /^点赞 / })).toHaveAttribute("aria-pressed", "false");
  await expect(actions.getByRole("button", { name: "收藏", exact: true })).toHaveAttribute("aria-pressed", "false");
  expect(state.writes).toHaveLength(1); expect(state.errors).toEqual([]);
});

test("手机侧栏关闭时不露出或抢占焦点，窄屏顶部与详情标题不溢出", async ({ page }) => {
  const state = await setup(page);
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    await page.goto("post/675");
    await expect(page.getByRole("button", { name: "分享", exact: true })).toBeVisible();
    await expect(page.locator(".sidebar")).toHaveCSS("visibility", "hidden");
    await expect(page.getByRole("link", { name: "课表", exact: true })).toHaveCount(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
    const positions = await page.locator(".post-detail-page .page-head").evaluate((element) => [element.querySelector("h1")!.getBoundingClientRect().top, element.querySelector("button")!.getBoundingClientRect().top]);
    expect(Math.abs(positions[0] - positions[1])).toBeLessThan(12);
    await page.getByRole("button", { name: "打开导航", exact: true }).click();
    await expect(page.getByRole("link", { name: "课表", exact: true })).toBeVisible();
    await page.getByRole("button", { name: "收起导航", exact: true }).click();
    await expect(page.locator(".sidebar")).toHaveCSS("visibility", "hidden");
  }
  expect(state.errors).toEqual([]);
});

test("没有标题的帖子只展示一次正文，宽屏右栏与阅读区域保持紧凑", async ({ page }) => {
  const state = await setup(page); state.post.title = ""; state.post.content = "没有标题也可以分享日常";
  for (const width of [1900, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("community");
    await expect(page.getByText("没有标题也可以分享日常", { exact: true })).toHaveCount(1);
    await expect(page.locator(".feed-card h3")).toHaveCount(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
    if (width === 1900) {
      const gap = await page.evaluate(() => document.querySelector(".right-rail")!.getBoundingClientRect().left - document.querySelector(".community-page")!.getBoundingClientRect().right);
      expect(gap).toBeLessThan(48); expect(gap).toBeGreaterThan(12);
    }
  }
  await page.goto("post/675");
  await expect(page.locator(".post-full h1")).toHaveCount(0);
  await expect(page.locator(".post-full .post-body")).toHaveText("没有标题也可以分享日常");
  expect(state.errors).toEqual([]);
});

test("关注按钮保留成功状态和取消能力，兼容作者列表没有回填关注字段", async ({ page }) => {
  const state = await setup(page); state.followFail = true;
  await page.goto("post/675");
  const follow = page.locator(".post-author .author-follow");
  await follow.click();
  await expect(page.locator(".toast")).toContainText("关注暂时失败");
  await expect(follow).toHaveAttribute("aria-pressed", "false");
  state.followFail = false;
  await follow.click();
  await expect(follow).toHaveText("已关注");
  await expect(follow).toHaveAttribute("aria-pressed", "true");
  await follow.click();
  await expect(follow).toHaveText("关注");
  expect(state.writes.at(-1)?.method).toBe("DELETE");
  expect(state.errors).toEqual([]);
});

test("宽屏详情补齐作者与最新讨论，顶部紧凑，相关帖子可进入并返回", async ({ page }) => {
  const state = await setup(page);
  await page.goto("post/675");
  const context = page.getByRole("complementary", { name: "帖子相关信息" });
  await expect(context.getByRole("heading", { name: "关于作者" })).toBeVisible();
  await expect(context.locator(".post-context-item")).toHaveCount(3);
  await expect(context.getByRole("link", { name: /社区展示测试/ })).toHaveCount(0);
  for (const width of [1900, 1440, 1280]) {
    await page.setViewportSize({ width, height: 1000 });
    const layout = await page.evaluate(() => {
      const head = document.querySelector(".post-detail-head")!.getBoundingClientRect();
      const main = document.querySelector(".post-detail-main")!.getBoundingClientRect();
      const rail = document.querySelector(".post-detail-rail")!.getBoundingClientRect();
      return { headHeight: head.height, topGap: main.top - head.bottom, columnsGap: rail.left - main.right, aligned: Math.abs(rail.top - main.top), mainWidth: main.width };
    });
    expect(layout.headHeight).toBeLessThanOrEqual(48);
    expect(layout.topGap).toBeGreaterThanOrEqual(8);
    expect(layout.topGap).toBeLessThanOrEqual(16);
    expect(layout.columnsGap).toBeGreaterThanOrEqual(16);
    expect(layout.columnsGap).toBeLessThanOrEqual(28);
    expect(layout.aligned).toBeLessThanOrEqual(2);
    expect(layout.mainWidth).toBeLessThanOrEqual(860);
    await expect(context).toBeVisible();
  }
  await context.getByRole("button", { name: "查看评论", exact: true }).click();
  await expect(page.getByRole("region", { name: "评论区" })).toBeFocused();
  await page.getByRole("button", { name: "返回列表", exact: true }).press("Control+Home");
  await context.getByRole("link", { name: /校园讨论 676/ }).click();
  await expect(page.locator(".post-full h1")).toHaveText("校园讨论 676");
  await page.getByRole("button", { name: "返回列表", exact: true }).click();
  await expect(page.locator(".post-full h1")).toHaveText("社区展示测试");
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});

test("右侧更多帖子加载、失败、重试和空态不影响正文与作者信息", async ({ page }) => {
  const state = await setup(page); state.relatedMode = "slow";
  await page.goto("post/675");
  const context = page.getByRole("complementary", { name: "帖子相关信息" });
  await expect(context.getByRole("status")).toHaveText("正在加载更多帖子…");
  await expect(page.locator(".post-full h1")).toHaveText("社区展示测试");
  await expect(context.locator(".post-context-item")).toHaveCount(3);
  state.relatedMode = "error"; await page.reload();
  await expect(context.getByRole("alert")).toContainText("暂时无法加载更多帖子");
  await expect(context.getByRole("heading", { name: "关于作者" })).toBeVisible();
  await expect(page.getByRole("group", { name: "帖子互动" })).toBeVisible();
  state.relatedMode = "filled"; await context.getByRole("button", { name: "重试", exact: true }).click();
  await expect(context.locator(".post-context-item")).toHaveCount(3);
  state.relatedMode = "empty"; await page.reload();
  await expect(context.getByText("暂时没有其他帖子", { exact: true })).toBeVisible();
  await expect(context.locator(".post-context-item")).toHaveCount(0);
  await expect(context.getByRole("link", { name: "继续逛逛校园社区" })).toHaveAttribute("href", "/web/community?sort=time");
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});

test("详情失败仍可返回，闲置详情使用集市上下文，窄屏侧栏不占阅读空间", async ({ page }) => {
  const state = await setup(page); state.postFail = true;
  await page.goto("post/675");
  await expect(page.getByText("帖子加载失败", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "返回列表", exact: true })).toBeVisible();
  await expect(page.locator(".post-detail-rail")).toHaveCount(0);
  state.postFail = false; await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.locator(".post-full h1")).toHaveText("社区展示测试");
  Object.assign(state.post, { board_id: 2, price: 88, contact: "", contact_type: "微信" });
  await page.reload();
  await expect(page.locator(".post-detail-head").getByRole("link", { name: "二手集市", exact: true })).toHaveAttribute("href", "/web/market");
  await expect(page.getByRole("heading", { name: "最新闲置", exact: true })).toBeVisible();
  for (const width of [1040, 390, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    await expect(page.locator(".post-detail-rail")).toBeHidden();
    expect(await page.locator("#mainContent").evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
    await expect(page.getByRole("button", { name: "返回列表", exact: true })).toBeVisible();
  }
  expect(state.writes).toEqual([]); expect(state.errors).toEqual([]);
});
