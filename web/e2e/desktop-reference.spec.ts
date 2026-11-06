import { test, expect, type Page } from "@playwright/test";

test("校园资讯按真实 item 封装进入详情并完整显示正文与官方来源", async ({ page }) => {
  await fixture(page, true);
  const article = { id: 600, title: "校园公开通知的完整标题", author_department: "校园服务中心", publish_date: "2026-11-03", content_text: "这是一则学校公开通知的完整正文。", source_url: "https://www.sylu.edu.cn/notice/test.htm" };
  await page.route("**/api/campus/articles/600", route => route.fulfill({ json: { item: article } }));
  await page.goto("campus/600");
  await expect(page.getByRole("heading", { name: article.title, level: 1, exact: true })).toBeVisible();
  await expect(page.locator("#mainContent")).toContainText(article.content_text);
  await expect(page.getByRole("link", { name: "查看官方来源", exact: true })).toHaveAttribute("href", article.source_url);
  await page.getByRole("link", { name: "返回列表", exact: true }).click();
  await expect(page).toHaveURL(/\/campus$/);
});

test("经验字段在桌面资料、作者、详情侧栏与手机资料显示同一 App 等级", async ({ page }) => {
  await fixture(page);
  await page.goto("./");
  await expect(page.locator(".profile-rail-card")).toContainText("Lv.7");
  await expect(page.locator(".dashboard-feed .author-level").first()).toHaveText("Lv.6");
  await page.goto("post/811");
  await expect(page.locator(".post-detail-page .author-level")).toHaveText("Lv.6");
  await expect(page.locator(".post-context-person")).toContainText("Lv.6");
  await page.setViewportSize({ width: 412, height: 915 });
  await page.goto("profile");
  await expect(page.locator(".mobile-profile-badges")).toContainText("Lv.7");
});

test("普通桌面高度向下阅读时两侧组件保持可见且底部入口可达", async ({ page }) => {
  const { posts, errors } = await fixture(page);
  const feedPosts = Array.from({ length: 24 }, (_, index) => ({ ...posts[1], id: 1000 + index }));
  await page.route("**/api/posts?**", route => route.fulfill({ json: { posts: new URL(route.request().url()).searchParams.get("sort") === "hot" ? posts : feedPosts, has_more: false } }));
  for (const [width, height] of [[1750, 880], [1280, 720]]) {
    await page.setViewportSize({ width, height });
    await page.goto("./");
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(24);
    await page.evaluate(() => window.scrollTo(0, 1600));
    const geometry = () => page.evaluate(() => {
      const box = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
      return { scroll: scrollY, navTop: box(".sidebar").top, navBottom: box(".sidebar").bottom, railTop: box(".right-rail").top, railBottom: box(".right-rail").bottom, headerBottom: box(".topbar").bottom };
    });
    await expect.poll(async () => (await geometry()).navTop).toBe(65);
    const layout = await geometry();
    expect(layout.scroll).toBeGreaterThan(1400);
    expect(layout.railTop).toBe(95);
    expect(layout.navBottom).toBeLessThanOrEqual(height);
    expect(layout.railBottom).toBeLessThanOrEqual(height);
    await expect(page.getByRole("region", { name: "校园个人资料" })).toBeInViewport();
    await expect(page.locator(".right-rail .today-card")).toBeInViewport();
    if (width === 1750) await page.screenshot({ path: ".codex-captures/desktop-bugs/reading-fixed.png" });
    const services = page.locator(".right-rail").getByRole("link", { name: "校园工具箱", exact: true });
    await services.scrollIntoViewIfNeeded();
    await expect(services).toBeInViewport();
    const tools = page.getByLabel("主导航").getByRole("link", { name: "工具箱", exact: true });
    await tools.scrollIntoViewIfNeeded();
    await expect(tools).toBeInViewport();
    expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
    if (width === 1750) await page.screenshot({ path: ".codex-captures/desktop-bugs/scroll-fixed.png" });
  }
  expect(errors).toEqual([]);
});

test("桌面首页滚到底继续快照分页，失败重试保留原帖并合并去重", async ({ page }) => {
  const { posts, errors } = await fixture(page);
  const firstPage = Array.from({ length: 12 }, (_, index) => ({ ...posts[1], id: 1100 + index }));
  const calls: URL[] = [];
  let nextAttempts = 0;
  await page.route("**/api/posts?**", route => {
    const url = new URL(route.request().url());
    if (url.searchParams.get("capabilities") !== "feed_pagination_meta_v1") return route.fallback();
    if (url.searchParams.get("sort") === "hot") return route.fulfill({ json: { posts } });
    calls.push(url);
    if (url.searchParams.get("page") === "1") return route.fulfill({ json: { posts: [posts[0], ...firstPage], has_more: true, session_id: "desktop-snapshot", next_offset: 20 } });
    if (++nextAttempts === 1) return route.fulfill({ status: 503, json: { message: "后续页暂不可用" } });
    return route.fulfill({ json: { posts: [firstPage[0], { ...posts[2], id: 1200, title: "第二页里的校园日常" }], has_more: false, session_id: "desktop-snapshot", next_offset: 40 } });
  });
  await page.goto("./");
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(12);
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await expect(page.getByRole("alert").filter({ hasText: "后续内容加载失败" })).toBeVisible();
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(12);
  await page.getByRole("button", { name: "重试加载", exact: true }).click();
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(13);
  await expect(page.locator(".dashboard-feed")).toContainText("第二页里的校园日常");
  await expect(page.getByText("已经看完啦", { exact: true })).toBeVisible();
  expect(nextAttempts).toBe(2);
  const next = calls.find(url => url.searchParams.get("page") === "2")!;
  expect(next.searchParams.get("scene")).toBe("loadmore");
  expect(next.searchParams.get("session_id")).toBe("desktop-snapshot");
  expect(next.searchParams.get("offset")).toBe("20");
  expect(next.searchParams.get("capabilities")).toContain("feed_pagination_meta_v1");
  expect(calls.some(url => url.searchParams.has("feed_version"))).toBe(false);
  expect(errors).toEqual([]);
});

test("桌面快照过期可刷新，空短页仍按服务端偏移继续加载", async ({ page }) => {
  const { posts } = await fixture(page);
  const initial = Array.from({ length: 8 }, (_, index) => ({ ...posts[1], id: 1300 + index }));
  let refreshed = false;
  const snapshots: string[] = [];
  const offsets: string[] = [];
  await page.route("**/api/posts?**", route => {
    const params = new URL(route.request().url()).searchParams;
    if (params.get("capabilities") !== "feed_pagination_meta_v1") return route.fallback();
    if (params.get("sort") === "hot") return route.fulfill({ json: { posts } });
    if (params.get("page") === "1") {
      const snapshot = refreshed ? "snapshot-2" : "snapshot-1";
      snapshots.push(snapshot);
      return route.fulfill({ json: { posts: initial, has_more: true, session_id: snapshot, next_offset: 20 } });
    }
    if (params.get("session_id") === "snapshot-1") return route.fulfill({ status: 409, json: { code: "feed_session_expired", error: "信息流已更新" } });
    offsets.push(params.get("offset")!);
    if (params.get("offset") === "20") return route.fulfill({ json: { posts: [], has_more: true, session_id: "snapshot-2", next_offset: 40 } });
    return route.fulfill({ json: { posts: [{ ...posts[2], id: 1400, title: "空短页后的下一条内容" }], has_more: false, next_offset: 60 } });
  });
  await page.goto("./");
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(8);
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await expect(page.getByRole("alert")).toContainText("信息流已更新");
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(8);
  refreshed = true;
  await page.getByRole("button", { name: "刷新动态", exact: true }).click();
  await expect(page.locator(".dashboard-feed")).toContainText("空短页后的下一条内容");
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(9);
  expect(new Set(snapshots)).toEqual(new Set(["snapshot-1", "snapshot-2"]));
  expect(offsets).toEqual(["20", "40"]);
});

test("首页后续页迟到不会覆盖已切换的排序，排序从页首开始", async ({ page }) => {
  const { posts } = await fixture(page);
  const initial = Array.from({ length: 8 }, (_, index) => ({ ...posts[1], id: 1500 + index }));
  let release = () => {}, pending = false;
  const blocked = new Promise<void>(resolve => { release = resolve; });
  const latestQueries: URL[] = [];
  await page.route("**/api/posts?**", async route => {
    const url = new URL(route.request().url());
    if (url.searchParams.get("capabilities") !== "feed_pagination_meta_v1") return route.fallback();
    if (url.searchParams.get("sort") === "hot") return route.fulfill({ json: { posts } });
    if (url.searchParams.get("sort") === "time") {
      latestQueries.push(url);
      return route.fulfill({ json: { posts: [{ ...posts[2], title: "只属于最新排序的内容" }], has_more: false } });
    }
    if (url.searchParams.get("page") === "1") return route.fulfill({ json: { posts: initial, has_more: true, session_id: "slow-all", next_offset: 20 } });
    pending = true;
    await blocked;
    return route.fulfill({ json: { posts: [{ ...posts[2], title: "已经过时的推荐后续页" }], has_more: false } });
  });
  try {
    await page.goto("./");
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(8);
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await expect.poll(() => pending).toBe(true);
    await page.getByRole("tab", { name: "最新", exact: true }).click();
    await expect(page.locator(".dashboard-feed")).toContainText("只属于最新排序的内容");
    release();
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(1);
    await expect(page.locator(".dashboard-feed")).not.toContainText("已经过时的推荐后续页");
    await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
    expect(latestQueries.every(url => url.searchParams.get("page") === "1" && !url.searchParams.has("session_id"))).toBe(true);
  } finally { release(); }
});

test("切换账号隔离迟到后续页与等级，游客关注页有明确登录入口", async ({ page }) => {
  const { posts } = await fixture(page);
  let account = 991, release = () => {}, pending = false;
  const blocked = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/user/profile", route => account ? route.fulfill({ json: { id: account, nickname: `同学${account}`, role: "user", exp: account === 991 ? 5432 : 50 } }) : route.fulfill({ status: 401, json: { message: "未登录" } }));
  await page.route("**/api/posts?**", async route => {
    const params = new URL(route.request().url()).searchParams;
    if (params.get("capabilities") !== "feed_pagination_meta_v1") return route.fallback();
    if (params.get("sort") === "hot") return route.fulfill({ json: { posts } });
    if (account === 992) return route.fulfill({ json: { posts: [{ ...posts[2], title: "新账号的信息流" }], has_more: false } });
    if (params.get("page") === "1") return route.fulfill({ json: { posts: Array.from({ length: 8 }, (_, index) => ({ ...posts[1], id: 1600 + index })), has_more: true, session_id: "account-991", next_offset: 20 } });
    pending = true;
    await blocked;
    return route.fulfill({ json: { posts: [{ ...posts[2], title: "旧账号迟到的信息流" }], has_more: false } });
  });
  const changeAccount = () => page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  try {
    await page.goto("./");
    await expect(page.locator(".profile-rail-card")).toContainText("Lv.7");
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(8);
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await expect.poll(() => pending).toBe(true);
    account = 992;
    await changeAccount();
    await expect(page.locator(".profile-rail-card")).toContainText("Lv.2");
    await expect(page.locator(".dashboard-feed")).toContainText("新账号的信息流");
    release();
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(1);
    await expect(page.locator(".dashboard-feed")).not.toContainText("旧账号迟到的信息流");
    account = 0;
    await changeAccount();
    await expect(page.locator(".profile-rail-card")).toContainText("欢迎来到沈理校园");
    await page.getByRole("tab", { name: "关注", exact: true }).click();
    await expect(page.locator(".dashboard-feed")).toContainText("登录后查看关注动态");
    await page.locator(".dashboard-feed").getByRole("button", { name: "登录", exact: true }).click();
    await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true })).toBeVisible();
  } finally { release(); }
});

test("桌面打开详情后返回保留窗口阅读位置", async ({ page }) => {
  await fixture(page);
  await page.goto("./");
  const summary = page.locator(".dashboard-feed .post-summary").last();
  await summary.scrollIntoViewIfNeeded();
  const position = await page.evaluate(() => scrollY);
  expect(position).toBeGreaterThan(300);
  await summary.click();
  await expect(page.locator(".post-detail-page")).toBeVisible();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
  await page.goBack();
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(3);
  await expect.poll(() => page.evaluate(saved => Math.abs(scrollY - saved), position)).toBeLessThan(2);
});

async function fixture(page: Page, guest = false) {
  const posts = [
    { id: 810, board_id: 1, title: "关于校园公共服务使用的提醒", content: "关注身边的新鲜事，也一起维护友好、真实的校园交流空间。", is_pinned: true },
    { id: 811, board_id: 1, title: "下次有人说沈理烂，就这样说回去", content: "在沈理待久了，你会发现这所学校很擅长把浪漫藏在不太体面的细节里：主楼前的风永远比天气预报大两级，琴湖的鸭子比早八的人准时，冬天教室的暖气总要迟到十分钟。\n但它也有自己的好。图书馆四楼靠窗能看见一整排银杏；二食堂三楼的阿姨会记得你少放辣；晚上十点从实验楼出来，整条路只剩你和路灯。", images: [{ id: 1, origin_url: "/uploads/desktop-campus.svg", thumb_url: "/uploads/desktop-campus.svg", width: 900, height: 330 }] },
    { id: 812, board_id: 1, title: "图书馆四楼靠窗的位置，真的很适合自习", content: "今天的阳光刚刚好。带一本书，给忙碌的一周留一点安静的时间。" },
    { id: 813, board_id: 1, title: "过期的公共帖子仍在普通信息流", content: "这条数据验证置顶过期后仍然可读。", is_pinned: true, pinned_until: "2020-01-01T00:00:00Z" },
  ].map(post => ({ ...post, author_id: 7, author: { id: 7, nickname: "校园测试同学", exp: 2750, avatar: "/uploads/server-avatar.svg" }, created_at: "2026-11-03T10:00:00+08:00", like_count: 128, reply_count: 26 }));
  const articles = ["供暖试水通知与冬季宿舍报修服务办理安排", "社团纳新宣讲：在这里找到志同道合的伙伴", "秋季双选会岗位发布与毕业生参会报名通知", "校园歌手赛初赛时间、场地与选手签到说明"].map((title, index) => ({ id: 90 + index, title, publish_date: `2026-11-0${index + 1}`, author_department: "校园服务中心" }));
  const queries: string[] = [];
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("**/uploads/server-*.svg", route => route.fulfill({ contentType: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80"><rect width="80" height="80" rx="20" fill="#e4ecff"/><circle cx="40" cy="29" r="16" fill="#5778d2"/><path d="M12 80V66a28 28 0 0 1 56 0v14" fill="#5778d2"/></svg>' }));
  await page.route("**/uploads/desktop-campus.svg", route => route.fulfill({ contentType: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="330" viewBox="0 0 900 330"><rect width="900" height="330" fill="#e9f0f7"/><path d="M0 230Q200 195 450 240T900 225V330H0" fill="#d3e0d8"/><path d="M0 290Q250 260 490 290T900 270V330H0" fill="#bacdb6"/><path d="M360 45h250v240H360z" fill="#e4e6e2" stroke="#91a7b2" stroke-width="3"/><path d="M345 45l140-45 140 45" fill="#839eaf"/><path d="M388 98h36v45h-36zm58 0h36v45h-36zm58 0h36v45h-36zm58 0h30v45h-30zM388 157h36v45h-36zm58 0h36v45h-36zm58 0h36v45h-36zm58 0h30v45h-30z" fill="#9db6c2"/><path d="M468 223h34v62h-34" fill="#748e97"/><path d="M140 115l8 192M755 110l-25 185" stroke="#6d8a7a" stroke-width="10" stroke-linecap="round"/><g fill="#b9cfad"><circle cx="135" cy="110" r="65"/><circle cx="85" cy="150" r="55"/><circle cx="190" cy="150" r="54"/><circle cx="760" cy="100" r="64"/><circle cx="710" cy="150" r="59"/><circle cx="820" cy="148" r="59"/></g><g fill="#e2cdcd"><circle cx="100" cy="115" r="24"/><circle cx="180" cy="125" r="28"/><circle cx="763" cy="70" r="26"/><circle cx="824" cy="125" r="25"/></g></svg>' }));
  await page.route("**/api/**", route => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/user/profile") return guest ? route.fulfill({ status: 401, json: { message: "未登录" } }) : route.fulfill({ json: { id: 991, nickname: "纯合子", avatar: "https://sylulive.online/uploads/server-avatar.svg", role: "user", exp: 5432, bio: "把普通日子记得认真一点。", total_likes_received: 1248, followers_count: 326, following_count: 84 } });
    if (url.pathname === "/api/refresh") return route.fulfill({ status: 401, json: { message: "未登录" } });
    if (url.pathname === "/api/posts") { queries.push(url.search); return route.fulfill({ json: { posts, has_more: false } }); }
    if (/^\/api\/posts\/\d+$/.test(url.pathname)) return route.fulfill({ json: { post: posts.find(post => String(post.id) === url.pathname.split("/").pop()) } });
    if (url.pathname === "/api/campus/articles") return route.fulfill({ json: { items: articles } });
    if (url.pathname === "/api/water/sections") return route.fulfill({ json: { sections: ["失物招领", "食堂测评", "考研上岸", "二手数码", "社团招新"].map((title, index) => ({ id: index + 1, slug: `section-${index}`, title, avatar_url: "/uploads/server-section.svg", post_count: 24 + index })) } });
    return route.fulfill({ json: { items: [] } });
  });
  return { posts, queries, errors };
}

test("桌面按参考呈现三栏、公共帖子与真实筛选，并保留详情和发布", async ({ page }) => {
  const state = await fixture(page);
  await page.setViewportSize({ width: 1480, height: 1120 });
  await page.goto("./");
  await expect(page.getByRole("navigation", { name: "快捷导航" })).toBeVisible();
  await expect(page.locator(".sidebar .profile-rail-card")).toContainText("纯合子");
  await expect(page.locator(".right-rail .today-card")).toBeVisible();
  const columns = await page.evaluate(() => {
    const bounds = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
    const profile = bounds(".sidebar .profile-rail-card"), main = bounds(".main-pane"), rail = bounds(".right-rail");
    return { profileWidth: profile.width, leftGap: main.left - profile.right, rightGap: rail.left - main.right, railWidth: rail.width };
  });
  expect(columns.profileWidth).toBeGreaterThanOrEqual(210);
  expect(columns.profileWidth).toBeLessThanOrEqual(214);
  expect(columns.leftGap).toBeGreaterThanOrEqual(24);
  expect(columns.rightGap).toBe(26);
  expect(columns.railWidth).toBe(296);
  const publicPosts = page.getByRole("region", { name: "公共帖子", exact: true });
  await expect(publicPosts).toContainText(state.posts[0].title);
  await expect(publicPosts).not.toContainText("置顶");
  await expect(publicPosts).not.toContainText(state.posts[3].title);
  await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(3);
  await expect(page.locator(".dashboard-feed .media-gallery img")).toBeVisible();
  await page.screenshot({ path: ".codex-captures/desktop-white-blue/desktop-1480.png" });
  await publicPosts.getByRole("link").click();
  await expect(page).toHaveURL(/post\/810$/);
  await expect(page.locator(".post-detail-page")).toContainText(state.posts[0].title);
  await page.goto("./");
  await page.getByRole("tab", { name: "最新", exact: true }).click();
  await expect.poll(() => state.queries.some(query => query.includes("sort=time"))).toBe(true);
  await page.getByRole("button", { name: "分享校园日常", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "发布内容", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("button", { name: "分享校园日常", exact: true })).toBeFocused();
  await page.goto("community");
  await expect(publicPosts).toContainText(state.posts[0].title);
  await page.screenshot({ path: ".codex-captures/desktop-white-blue/community-1480.png" });
  await page.locator(".sidebar-more summary").click();
  const grades = page.getByLabel("主导航").getByRole("link", { name: "成绩与学业", exact: true });
  await expect(grades).toBeVisible();
  await grades.press("Enter");
  await expect(page).toHaveURL(/grades$/);
  await page.setViewportSize({ width: 820, height: 1000 });
  await page.goto("market");
  const more = page.locator(".sidebar-more");
  await more.evaluate(el => { (el as HTMLDetailsElement).open = false; });
  await more.locator("summary").click();
  await page.getByLabel("主导航").getByRole("link", { name: "成绩与学业", exact: true }).click();
  await expect(page).toHaveURL(/grades$/);
  expect(state.errors).toEqual([]);
});

test("游客在桌面查看空公共帖子、加载失败与重试，发布要求登录", async ({ page }) => {
  await fixture(page, true);
  let failed = true;
  let release = () => {};
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/posts?**", async route => {
    if (new URL(route.request().url()).searchParams.get("sort") === "hot") return route.fulfill({ json: { posts: [] } });
    await pending;
    return failed ? route.fulfill({ status: 503, json: { message: "校园动态暂不可用" } }) : route.fulfill({ json: { posts: [] } });
  });
  await page.goto("./");
  await expect(page.locator(".dashboard-feed")).toContainText("正在加载");
  release();
  await expect(page.locator(".dashboard-feed")).toContainText("加载未完成");
  failed = false;
  await page.locator(".dashboard-feed").getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.locator(".dashboard-feed")).toContainText("暂时没有新的校园动态");
  await expect(page.getByRole("region", { name: "公共帖子", exact: true })).toHaveCount(0);
  await expect(page.locator(".dashboard-feed .empty-state")).toBeVisible();
  await page.getByRole("button", { name: "分享校园日常", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true })).toBeVisible();
});

test("长标题与宽窗口保留参考侧栏比例，资料、数量和热榜不越界", async ({ page }) => {
  await fixture(page);
  const longTitle = "2026-2027-1学年校园课程与公开服务信息安排及办理说明".repeat(4);
  await page.route("**/api/user/profile", route => route.fulfill({ json: { id: 991, nickname: "校园里的同学".repeat(8), bio: "把普通日子记得认真一点。".repeat(10), role: "user", level: 6, total_likes_received: 1248, followers_count: 326, following_count: 84 } }));
  await page.route("**/api/water/sections", route => route.fulfill({ json: { sections: Array.from({ length: 5 }, (_, index) => ({ id: index + 1, slug: `section-${index}`, title: "课程学习与校园生活交流".repeat(4), post_count: 1234 })) } }));
  await page.route("**/api/campus/articles?**", route => route.fulfill({ json: { items: Array.from({ length: 4 }, (_, index) => ({ id: 600 + index, title: longTitle, publish_date: "2026-11-03", author_department: "校园服务中心" })) } }));
  await page.route("**/api/posts?**", route => route.fulfill({ json: { posts: Array.from({ length: 5 }, (_, index) => ({ id: 500 + index, title: longTitle, content: "测试正文", author: { nickname: "测试同学" }, reply_count: 123 })) } }));
  let cardHeights: number[] | undefined;
  for (const [width, height] of [[1280, 800], [1480, 1120], [1920, 1080], [2540, 1258]]) {
    await page.setViewportSize({ width, height });
    await page.goto("./");
    await expect(page.locator(".campus-event")).toHaveCount(4);
    await expect(page.locator(".campus-hot-item")).toHaveCount(5);
    const layout = await page.evaluate(() => {
      const bounds = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
      const profile = bounds(".profile-rail-card"), sidebar = bounds(".sidebar-scroll");
      const rail = bounds(".right-rail"), cards = [".today-card", ".campus-events-card", ".campus-hot-card"].map(selector => bounds(selector).height);
      const clippedBoardLabels = [...document.querySelectorAll(".sidebar-board")].some(el => {
        const row = el.getBoundingClientRect();
        return [...el.children].some(child => { const box = child.getBoundingClientRect(); return box.left < row.left - 1 || box.right > row.right + 1; });
      });
      const outsideHotRows = [...document.querySelectorAll(".campus-hot-item")].some(el => {
        const box = el.getBoundingClientRect();
        return box.left < rail.left || box.right > rail.right || el.scrollWidth > el.clientWidth;
      });
      const titles = [...document.querySelectorAll(".campus-event b, .campus-hot-item > span:nth-child(2)")].map(el => ({ ellipsis: getComputedStyle(el).textOverflow, width: el.getBoundingClientRect().width }));
      const eventSpacing = [...document.querySelectorAll(".campus-event")].map(el => {
        const row = el.getBoundingClientRect(), title = el.querySelector("b")!.getBoundingClientRect(), source = el.querySelector(".event-source")!.getBoundingClientRect();
        return { gap: source.top - title.bottom, top: title.top - row.top, bottom: row.bottom - source.bottom };
      });
      return { profileWidth: profile.width, profileHeight: profile.height, profileInside: profile.left >= sidebar.left && profile.right <= sidebar.right + 1, railWidth: rail.width, cards, clippedBoardLabels, outsideHotRows, titles, eventSpacing, overflow: document.documentElement.scrollWidth > innerWidth };
    });
    expect(layout.profileWidth).toBe(214);
    expect(layout.profileHeight).toBeGreaterThanOrEqual(190);
    expect(layout.profileHeight).toBeLessThanOrEqual(210);
    expect(layout.profileInside).toBe(true);
    expect(layout.railWidth).toBe(296);
    expect(layout.cards[0]).toBeGreaterThanOrEqual(228);
    expect(layout.cards[1]).toBe(416);
    expect(layout.cards[2]).toBe(304);
    if (cardHeights) layout.cards.forEach((value, index) => expect(Math.abs(value - cardHeights![index])).toBeLessThan(0.1));
    else cardHeights = layout.cards;
    expect(layout.clippedBoardLabels).toBe(false);
    expect(layout.outsideHotRows).toBe(false);
    expect(layout.titles.every(title => title.ellipsis === "ellipsis" && title.width > 0)).toBe(true);
    expect(layout.eventSpacing.every(row => row.gap >= 5 && row.top >= 10 && row.bottom >= 10)).toBe(true);
    await expect(page.locator(".event-month").first()).toHaveText("11月");
    await expect(page.locator(".event-day").first()).toHaveText("03");
    await expect(page.locator(".campus-event time").first()).toHaveAttribute("datetime", "2026-11-03");
    expect(layout.overflow).toBe(false);
    if (width === 1480 || width === 2540) await page.screenshot({ path: `.codex-captures/desktop-ratio-fix/long-titles-${width}.png` });
  }
});

test("侧栏加载、失败重试、空数据和恢复后保持卡片比例", async ({ page }) => {
  await fixture(page);
  let phase: "error" | "empty" | "filled" = "error";
  let release = () => {};
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/campus/articles?**", async route => {
    await pending;
    return phase === "error" ? route.fulfill({ status: 503, json: { message: "测试服务暂不可用" } }) : route.fulfill({ json: { items: phase === "filled" ? Array.from({ length: 4 }, (_, index) => ({ id: index, title: "校园公开资讯", publish_date: "2026-11-03" })) : [] } });
  });
  await page.route("**/api/posts?**", async route => {
    if (new URL(route.request().url()).searchParams.get("sort") !== "hot") return route.fulfill({ json: { posts: [] } });
    await pending;
    return phase === "error" ? route.fulfill({ status: 503, json: { message: "测试热榜暂不可用" } }) : route.fulfill({ json: { posts: phase === "filled" ? Array.from({ length: 5 }, (_, index) => ({ id: index, title: "校园热门讨论", reply_count: 123 })) : [] } });
  });
  await page.goto("./");
  const news = page.locator(".campus-events-card"), hot = page.locator(".campus-hot-card");
  const heights = () => page.locator(".campus-events-card, .campus-hot-card").evaluateAll(es => es.map(el => el.getBoundingClientRect().height));
  await expect(news.getByRole("status")).toBeVisible();
  expect(await heights()).toEqual([416, 304]);
  release();
  await expect(news.getByRole("alert")).toBeVisible();
  await expect(hot.getByRole("alert")).toBeVisible();
  expect(await heights()).toEqual([416, 304]);
  phase = "empty";
  await news.getByRole("button", { name: "重试", exact: true }).click();
  await hot.getByRole("button", { name: "重试", exact: true }).click();
  await expect(news).toContainText("暂时没有新内容");
  await expect(hot).toContainText("暂时没有新内容");
  expect(await heights()).toEqual([416, 304]);
  phase = "filled";
  await page.reload();
  await expect(news.locator(".campus-event")).toHaveCount(4);
  await expect(hot.locator(".campus-hot-item")).toHaveCount(5);
  expect(await heights()).toEqual([416, 304]);
});

test("侧栏组件外框、内部排版和服务入口可见可用", async ({ page }) => {
  await fixture(page);
  await page.setViewportSize({ width: 1480, height: 1360 });
  await page.goto("./");
  await expect(page.locator(".campus-event")).toHaveCount(4);
  await expect(page.getByRole("navigation", { name: "常用入口", exact: true }).getByRole("link")).toHaveCount(6);
  await expect(page.getByRole("region", { name: "校园日历", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "集市新上架", exact: true })).toBeVisible();
  await expect(page.locator(".sidebar-boards")).toHaveCSS("border-top-width", "1px");
  await expect(page.locator(".sidebar-boards")).toHaveCSS("border-top-left-radius", "16px");
  expect(await page.locator(".sidebar-board, .campus-hot-item, .home-quick a").evaluateAll(elements => elements.every(el => el.getBoundingClientRect().height >= 44))).toBe(true);
  expect(await page.locator(".home-quick a").evaluateAll(elements => elements.every(el => el.scrollWidth <= el.clientWidth))).toBe(true);
  await page.screenshot({ path: ".codex-captures/ui-sidebars/home-final.png" });
  await page.locator(".right-rail").screenshot({ path: ".codex-captures/ui-sidebars/right-rail-final.png" });
  const service = page.getByRole("navigation", { name: "常用入口", exact: true }).getByRole("link", { name: "课表", exact: true });
  await service.focus();
  await expect(service).toHaveCSS("outline-width", "2px");
  await service.press("Enter");
  await expect(page).toHaveURL(/schedule$/);
});

test("帖子独立边界、内容对齐、图片比例和全文入口在深浅与窄宽屏一致", async ({ page }) => {
  const { posts, errors } = await fixture(page);
  posts[1].content = "这是用于验证摘要截断和全文入口的校园日常。".repeat(24);
  for (const theme of ["light", "dark"]) {
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    for (const width of [320, 390, 1480]) {
      await page.setViewportSize({ width, height: 1200 });
      for (const route of ["./", "community"]) {
        await page.goto(route);
        const cards = page.locator(".dashboard-feed .feed-card, .community-feed .feed-card");
        await expect(cards).toHaveCount(3);
        await expect(cards.first()).toHaveCSS("border-top-width", "1px");
        const geometry = await cards.evaluateAll(elements => elements.map((card, index) => {
          const bounds = card.getBoundingClientRect();
          const summary = card.querySelector(".post-summary")!.getBoundingClientRect();
          const author = card.querySelector(".post-author")!.getBoundingClientRect();
          const toolbar = card.querySelector(".post-toolbar")!.getBoundingClientRect();
          const picture = card.querySelector(".media-gallery")?.getBoundingClientRect();
          const readMore = card.querySelector(".post-read-more")?.getBoundingClientRect();
          const previous = index ? elements[index - 1].getBoundingClientRect() : null;
          return {
            border: getComputedStyle(card).borderBottomWidth,
            radius: getComputedStyle(card).borderRadius,
            gap: previous ? bounds.top - previous.bottom : 16,
            aligned: Math.abs(author.left - summary.left) < 1 && Math.abs(summary.left - toolbar.left) < 1,
            mediaFits: !picture || picture.width <= 560 && picture.left >= bounds.left && picture.right <= bounds.right,
            readMoreFits: !readMore || readMore.top >= card.querySelector(".post-body")!.getBoundingClientRect().bottom && readMore.bottom <= summary.bottom,
            actionsFit: [...card.querySelectorAll(".post-interaction")].every(action => {
              const box = action.getBoundingClientRect();
              return box.height >= 44 && box.left >= toolbar.left && box.right <= toolbar.right;
            }),
          };
        }));
        for (const card of geometry) {
          expect(card.border).toBe("1px");
          expect(card.radius).toBe(width <= 760 && route === "./" ? "12px" : "16px");
          expect(card.gap).toBeGreaterThanOrEqual(width <= 760 && route === "./" ? 6 : 16);
          expect(card.aligned && card.mediaFits && card.readMoreFits && card.actionsFit).toBe(true);
        }
        await expect(cards.first().getByText("查看全文", { exact: false })).toBeVisible();
        expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
        if (route === "./" && width !== 320) {
          await page.screenshot({ path: `.codex-captures/feed-cards/${theme}-${width}.png`, fullPage: false });
        }
      }
    }
  }
  await page.locator(".post-read-more").first().click();
  await expect(page).toHaveURL(/post\/811$/);
  await expect(page.locator(".post-detail-page")).toContainText(posts[1].content);
  expect(errors).toEqual([]);
});
