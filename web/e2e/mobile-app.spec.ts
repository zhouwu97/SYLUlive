import { test, expect, type Page } from "@playwright/test";

async function setup(page: Page, guest = false) {
  const state = { nextError: false, voteError: false, votes: [] as number[][], queries: [] as URL[], errors: [] as string[], replyReads: [] as number[] };
  const author = { id: 8, nickname: "校园测试同学" };
  const poll = { id: 201, author_id: 8, author, title: "校园投票测试", content: "一起选择本周校园活动", created_at: "2026-11-03T08:00:00+08:00", poll_meta: {
    id: 91, effective_status: "active", selection_mode: "multiple", max_choices: 2, can_vote: true,
    results_visible: true, participant_count: 10,
    options: ["读书", "跑步", "电影", "摄影"].map((text, index) => ({ id: index + 1, text, vote_count: index + 1, ratio: (index + 1) / 10 })),
  } };
  const normal = { id: 202, board_id: 1, author_id: 8, author, title: "校园里的秋天", content: "今天的校园日常。".repeat(35), created_at: poll.created_at, like_count: 3, reply_count: 2 };
  const article = { id: 71, title: "校园通知测试", publish_date: "2026-11-03", author_department: "校园服务中心" };
  page.on("pageerror", error => state.errors.push(error.message));
  await page.route("**/api/**", async route => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/user/profile") return route.fulfill({ status: guest ? 401 : 200, json: guest ? { message: "未登录" } : { id: 7, role: "user", nickname: "界面测试同学", level: 7, credit_score: 100, following_count: 1, followers_count: 22 } });
    if (url.pathname === "/api/refresh") return route.fulfill({ status: 401, json: { message: "未登录" } });
    if (url.pathname === "/api/posts" || url.pathname === "/api/posts/featured") {
      state.queries.push(url);
      if (url.searchParams.get("board") === "2") return route.fulfill({ json: { posts: [{ ...normal, id: 301, board_id: 2, post_type: "sell", title: "二手教材", price: 20 }, { ...normal, id: 302, board_id: 2, post_type: "found", title: "捡到耳机" }], has_more: false } });
      if (url.searchParams.get("page") === "2") return state.nextError ? route.fulfill({ status: 503, json: { message: "测试后续加载失败" } }) : route.fulfill({ json: { posts: [{ ...normal, id: 204, title: "第二页内容" }], has_more: false } });
      return route.fulfill({ json: { pinned_posts: [{ id: 200, title: "电费缴费", is_pinned: true }], posts: [poll, normal, { ...normal, id: 203, title: "图书馆的日常" }], has_more: true, session_id: "mobile-session", next_offset: 3, next_cursor_token: "latest-cursor" } });
    }
    if (url.pathname === "/api/polls/91/ballot") {
      state.votes.push(route.request().postDataJSON().option_ids);
      return state.voteError ? route.fulfill({ status: 503, json: { message: "投票暂时失败" } }) : route.fulfill({ json: { ok: true } });
    }
    if (url.pathname === "/api/posts/201") return route.fulfill({ json: { ...poll, poll_meta: undefined } });
    if (url.pathname === "/api/polls/91") return route.fulfill({ json: poll });
    if (/^\/api\/posts\/\d+\/replies$/.test(url.pathname)) {
      state.replyReads.push(Number(url.pathname.split('/')[3]));
      return route.fulfill({ json: { replies: [] } });
    }
    if (url.pathname === "/api/notifications/replies/unread") return route.fulfill({ json: { count: 1, items: [{ id: 1 }] } });
    if (url.pathname === "/api/campus/articles") return route.fulfill({ json: { items: [article, { ...article, id: 72, title: "第二条校园资讯" }] } });
    if (url.pathname === "/api/user/7/posts") return route.fulfill({ json: { posts: [normal], total: 24 } });
    if (url.pathname === "/api/user/7/following") return route.fulfill({ json: { users: [author] } });
    return route.fulfill({ json: { items: [] } });
  });
  return state;
}

for (const theme of ["light", "dark"]) {
  test(`手机五个主入口布局、导航、安全区域和服务内容 ${theme}`, async ({ page }) => {
    const state = await setup(page);
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    for (const width of [320, 412]) {
      await page.setViewportSize({ width, height: 917 });
      await page.goto("./");
      const dock = page.getByRole("navigation", { name: "底部导航" });
      for (const [label, route] of [["首页", ""], ["集市", "market"], ["课表", "schedule"], ["校园", "campus"], ["我", "profile"]]) {
        await dock.getByRole("link", { name: label, exact: true }).click();
        await expect(dock.getByRole("link", { name: label, exact: true })).toHaveAttribute("aria-current", "page");
        await expect(page.locator("#mainContent")).toBeVisible();
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        expect(await dock.locator("a").evaluateAll(links => links.every(link => {
          const bounds = link.getBoundingClientRect();
          return bounds.width >= 44 && bounds.height >= 44 && bounds.left >= 0 && bounds.right <= innerWidth;
        }))).toBe(true);
        if (route === "") await expect(page.locator(".mobile-feed-poll")).toHaveCount(1);
        if (route === "market") await expect(page.getByRole("group", { name: "闲置分类" }).getByRole("button")).toHaveCount(6);
        if (route === "schedule") await expect(page.getByRole("heading", { name: "还没有课表" })).toBeVisible();
        if (route === "campus") await expect(page.getByRole("navigation", { name: "校园服务" }).locator("a, button")).toHaveCount(6);
        if (route === "profile") await expect(page.locator(".mobile-profile-stats")).toContainText("24");
        if (width === 412) await page.screenshot({ path: `.codex-captures/mobile-restore/${theme}-${route || "home"}.png` });
      }
    }
    expect(state.errors).toEqual([]);
  });
}

test("手机首页接入新版信息流、完整投票选项、失败重试和真实投票编号", async ({ page }) => {
  const state = await setup(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  await expect(page.locator(".mobile-reply-reminder")).toContainText("1 条新回复");
  await expect(page.locator(".mobile-feed-poll .poll-choice")).toHaveCount(3);
  expect(state.queries[0].searchParams.get("feed_version")).toBe("3");
  expect(state.queries[0].searchParams.get("capabilities")).toBe("poll_v1");
  await page.getByRole("button", { name: "还有 1 个选项" }).click();
  await expect(page.locator(".mobile-feed-poll .poll-choice")).toHaveCount(4);
  await page.getByRole("checkbox", { name: "摄影", exact: true }).check();
  state.voteError = true;
  await page.getByRole("button", { name: "提交选择", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("投票暂时失败");
  await expect(page.getByRole("checkbox", { name: "摄影", exact: true })).toBeChecked();
  state.voteError = false;
  await page.getByRole("button", { name: "重试投票", exact: true }).click();
  await expect.poll(() => state.votes).toEqual([[4], [4]]);
  await page.getByRole("tab", { name: "最新", exact: true }).click();
  await expect(page).toHaveURL(/sort=time/);
  await expect.poll(() => state.queries.at(-1)?.searchParams.get("sort")).toBe("time");
  await page.getByRole("link", { name: "校园投票测试", exact: true }).click();
  await expect(page).toHaveURL(/polls\/91$/);
  await expect(page.locator(".post-full .poll-choice")).toHaveCount(4);
  await expect.poll(() => page.locator('.post-comments').count()).toBe(1);
  expect(state.replyReads).toContain(201);
  expect(state.replyReads).not.toContain(91);
  await expect(page.getByRole("navigation", { name: "底部导航" })).toHaveCount(0);
  await page.getByRole("button", { name: "返回上一页", exact: true }).click();
  await expect(page).toHaveURL(/sort=time/);
  expect(state.errors).toEqual([]);
});

test("手机后续加载失败保留已读内容，快照与最新游标继续传递", async ({ page }) => {
  const state = await setup(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  state.nextError = true;
  await page.getByRole("button", { name: "加载更多", exact: true }).click();
  await expect(page.locator(".mobile-app-feed > article")).toHaveCount(3);
  await expect(page.getByRole("alert")).toContainText("已读帖子已保留");
  expect(state.queries.at(-1)?.searchParams.get("session_id")).toBe("mobile-session");
  expect(state.queries.at(-1)?.searchParams.get("offset")).toBe("3");
  state.nextError = false;
  await page.getByRole("button", { name: "重试加载", exact: true }).click();
  await expect(page.locator(".mobile-app-feed > article")).toHaveCount(4);
  await page.getByRole("tab", { name: "最新", exact: true }).click();
  await page.getByRole("button", { name: "加载更多", exact: true }).click();
  expect(state.queries.at(-1)?.searchParams.get("cursor")).toBe("latest-cursor");
  expect(state.errors).toEqual([]);
});

test("手机课表保留添加、编辑、冲突验证、周次与学校连接入口", async ({ page }) => {
  await setup(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("schedule");
  await page.getByRole("button", { name: "课表工具", exact: true }).click();
  await page.getByRole("button", { name: "添加课程", exact: true }).click();
  await page.getByLabel("课程名称", { exact: true }).fill("手机测试课程");
  await page.getByLabel("地点", { exact: true }).fill("测试教室");
  await page.getByRole("button", { name: "保存", exact: true }).click();
  await expect(page.locator(".mobile-course-grid .course")).toHaveCount(1);
  await page.getByRole("button", { name: "课表工具", exact: true }).click();
  await page.getByRole("button", { name: "添加课程", exact: true }).click();
  await page.getByLabel("课程名称", { exact: true }).fill("冲突课程");
  await page.getByRole("button", { name: "保存", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("冲突");
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.getByRole("button", { name: "下一周", exact: true }).click();
  await expect(page).toHaveURL(/week=2/);
  await page.locator(".mobile-course-grid .course").click();
  await page.getByRole("button", { name: "删除本地课程", exact: true }).click();
  await expect(page.getByRole("heading", { name: "还没有课表", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "课表拉取", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "更新学校课表", exact: true })).toBeVisible();
});

test("手机校园入口与个人统计进入真实页面，返回与滚动位置正确", async ({ page }) => {
  const state = await setup(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  await expect(page.locator(".mobile-feed-poll")).toBeVisible();
  // 初始化认证会触发信息流重取；等页面稳定后再记录真实滚动位置。
  await page.waitForLoadState("networkidle");
  await page.evaluate(() => window.scrollTo(0, 200));
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(200);
  const position = await page.evaluate(() => scrollY);
  const dock = page.getByRole("navigation", { name: "底部导航" });
  await dock.getByRole("link", { name: "校园", exact: true }).click();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
  await page.getByRole("button", { name: "校园地图", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "校园地图", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.goBack();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(position);
  await dock.getByRole("link", { name: "我", exact: true }).click();
  await page.locator(".mobile-profile-stats").getByRole("link", { name: /我的内容/ }).click();
  await expect(page).toHaveURL(/view=posts/);
  await expect(page.getByRole("heading", { name: "我的帖子", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "返回我的主页", exact: true }).click();
  await expect(page.locator(".mobile-profile-identity")).toContainText("界面测试同学");
  expect(state.errors).toEqual([]);
});

test("游客手机发布与个人入口先登录，桌面恢复既有三栏与发布区", async ({ page }) => {
  const state = await setup(page, true);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  await page.getByRole("tab", { name: "关注", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true })).toBeVisible();
  expect(state.queries.some(url => url.searchParams.get('sort') === 'following')).toBe(false);
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.getByRole("button", { name: "发布校园内容", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.getByRole("navigation", { name: "底部导航" }).getByRole("link", { name: "我", exact: true }).click();
  await expect(page.getByRole("button", { name: "登录", exact: true })).toBeVisible();
  await page.goto('community?sort=bookmarks');
  await expect(page.getByRole('heading', { name: '登录后查看我的收藏' })).toBeVisible();
  await expect(page.locator('.loading-state')).toHaveCount(0);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto("./");
  await expect(page.locator(".campus-composer")).toBeVisible();
  await expect(page.locator(".mobile-bottom-nav, .mobile-header, .mobile-app-feed")).toHaveCount(0);
  await expect(page.locator(".sidebar")).toHaveCSS("width", "214px");
  await expect(page.locator(".right-rail")).toBeVisible();
  expect(state.queries.at(-1)?.searchParams.has("feed_version")).toBe(false);
  expect(state.votes).toEqual([]);
});
