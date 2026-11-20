import { test, expect, type Page } from "@playwright/test";
import { measureTextContrast } from "./visual-contrast";

test.use({ timezoneId: "Asia/Taipei" });

async function fixture(page: Page) {
  await page.clock.setFixedTime(new Date("2026-11-16T12:00:00+08:00"));
  const posts = [
    { id: 811, title: "自行车怎么又消失了 😡", content: "刚找回来的自行车又不见了，今天在图书馆附近有同学看到吗？\n一起留意身边的小事，也记得给自己的车上好锁。", author: { id: 7, nickname: "晨光熹微", level: 2, followers_count: 12 }, like_count: 24, reply_count: 8 },
    { id: 812, title: "求帮帮 😭", content: "我们小组的结课作业，还差几份问卷。\n有空的同学帮忙填一下，先谢谢大家！🙏", author: { id: 8, nickname: "翔子cry", level: 5, followers_count: 26 }, like_count: 6, reply_count: 3 },
  ].map(post => ({ ...post, board_id: 1, author_id: post.author.id, created_at: "2026-11-16T10:40:00+08:00", images: [] }));
  const articles = [
    { id: 90, title: "关于组织参加“复旦社杯”沈阳理工大学第三届英语科技海报大赛的通知", publish_date: "2026-11-16", author_department: "创新创业学院 外国语学院" },
    { id: 91, title: "2026-2027-1经济管理学院重修考试和期末考试安排（13周）", publish_date: "2026-11-16", author_department: "教务管理科" },
    { id: 92, title: "2026-2027-1第13周实验、课程设计等实践环节日程", publish_date: "2026-11-14", author_department: "实践教学科" },
    { id: 93, title: "关于举办校园学术交流活动的通知", publish_date: "", author_department: "校园服务中心" },
  ];
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("**/api/**", route => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/user/profile") return route.fulfill({ json: { id: 991, nickname: "纯合子", exp: 5432, role: "user", total_likes_received: 133, followers_count: 22, following_count: 1 } });
    if (url.pathname === "/api/posts") return route.fulfill({ json: { posts: url.searchParams.get("board") === "2" ? [] : posts, has_more: false } });
    if (url.pathname === "/api/campus/articles") return route.fulfill({ json: { items: articles } });
    if (url.pathname === "/api/water/sections") return route.fulfill({ json: { sections: [{ id: 1, slug: "study", title: "课程学习", post_count: 28 }, { id: 3, slug: "daily", title: "校园生活", post_count: 540 }] } });
    return route.fulfill({ json: { items: [] } });
  });
  return { posts, errors };
}

for (const theme of ["light", "dark"]) {
  test(`组件在${theme}主题下保持日期、来源和操作区域可读`, async ({ page }) => {
    const { errors } = await fixture(page);
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await page.setViewportSize({ width: 1480, height: 1120 });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto("./");
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(2);
    await expect(page.locator(".campus-event.is-today")).toHaveCount(2);
    await expect(page.locator(".campus-event.is-today .event-new")).toHaveText(["今日", "今日"]);
    await expect(page.locator(".campus-event time").first()).toHaveAttribute("datetime", "2026-11-16");
    await expect(page.locator(".campus-event").last()).toContainText("校园");
    await expect(page.locator(".profile-level")).toHaveAccessibleName("等级 7");
    await expect(page.locator(".author-level").first()).toHaveAccessibleName("等级 2");
    const geometry = await page.locator(".campus-event").evaluateAll(items => items.map(item => {
      const row = item.getBoundingClientRect();
      const title = item.querySelector("b")!.getBoundingClientRect();
      const source = item.querySelector(".event-source")!.getBoundingClientRect();
      const date = item.querySelector(".event-date")!.getBoundingClientRect();
      return title.bottom <= source.top && row.bottom - source.bottom >= 10 && date.right < title.left && source.right <= row.right;
    }));
    expect(geometry.every(Boolean)).toBe(true);
    const more = page.locator(".home-feed-more");
    await more.focus();
    await expect(more).toHaveCSS("outline-width", "2px");
    const follow = page.locator(".dashboard-feed .author-follow").first();
    await follow.focus();
    await expect(follow).toHaveCSS("outline-width", "2px");
    await follow.blur();
    await page.screenshot({ path: `.codex-captures/component-finish/home-${theme}.png` });
    await page.locator(".dashboard-feed .feed-card").first().screenshot({ path: `.codex-captures/component-finish/post-${theme}.png` });
    await page.locator(".dashboard-feed").screenshot({ path: `.codex-captures/component-finish/feed-${theme}.png` });
    await page.locator(".campus-events-card").screenshot({ path: `.codex-captures/component-finish/notices-${theme}.png` });
    // 通过用户的外观入口换色，检查这套共享控件能在已有主题上继续使用。
    await page.getByRole("button", { name: "外观设置", exact: true }).click();
    await page.getByRole("button", { name: "松石青", exact: true }).click();
    await page.getByRole("button", { name: "关闭外观设置", exact: true }).click();
    const contrast = await page.locator(".level-badge, .follow-control, .post-interaction, .post-action-count, .home-feed-more, .event-copy b, .event-source, .event-month, .event-day, .event-new").evaluateAll(measureTextContrast);
    expect(contrast.filter(item => item.ratio < 4.5)).toEqual([]);
    await page.screenshot({ path: `.codex-captures/component-finish/teal-${theme}.png` });
    expect(errors).toEqual([]);
  });
}

test("窄桌面与大字号下长作者、计数和全部动态入口不挤出卡片", async ({ page }) => {
  const { posts, errors } = await fixture(page);
  posts[0].author.nickname = "在图书馆认真学习的同学".repeat(5);
  posts[0].like_count = 123456;
  posts[0].reply_count = 123456;
  for (const width of [640, 768, 1024, 1480]) {
    await page.setViewportSize({ width, height: 1120 });
    await page.goto("./");
    await expect(page.locator(".dashboard-feed .feed-card")).toHaveCount(2);
    await page.addStyleTag({ content: ":root { --text-caption: 18px; --text-base: 22px; --text-lg: 28px; }" });
    const layout = await page.evaluate(() => {
      const heading = document.querySelector(".home-feed-heading")!.getBoundingClientRect();
      const more = document.querySelector(".home-feed-more")!.getBoundingClientRect();
      const cardsFit = [...document.querySelectorAll(".dashboard-feed .feed-card")].every(card => {
        const box = card.getBoundingClientRect();
        return [...card.querySelectorAll(".post-interaction, .author-follow, .author-level")].every(control => {
          const rect = control.getBoundingClientRect();
          return rect.left >= box.left && rect.right <= box.right;
        });
      });
      return { fits: document.documentElement.scrollWidth <= innerWidth, cardsFit, moreFits: more.left >= heading.left && more.right <= heading.right };
    });
    expect(layout).toEqual({ fits: true, cardsFit: true, moreFits: true });
  }
  expect(errors).toEqual([]);
});

test("正文 Emoji 实际使用同源彩色字体，组合与复制内容保持原字符", async ({ page, context }) => {
  const { posts, errors } = await fixture(page);
  const text = "正文 😡😭🙏 👩🏽‍💻 🇨🇳 1️⃣ 课程2026 © ™";
  posts[0].content = text;
  const fontRequests: string[] = [];
  const fontWarnings: string[] = [];
  page.on("console", message => { if (/Failed to decode.*font|OTS parsing/i.test(message.text())) fontWarnings.push(message.text()); });
  page.on("request", request => { if (/noto-color-emoji.*\.woff/.test(request.url())) fontRequests.push(request.url()); });
  await page.goto("./");
  const body = page.locator(".dashboard-feed .post-body").first();
  await expect(body).toHaveText(text);
  await expect(body.locator(".inline-emoji")).toHaveText(["😡", "😭", "🙏", "👩🏽‍💻", "🇨🇳", "1️⃣"]);
  await page.evaluate(async () => { await document.fonts.ready; });
  const cdp = await context.newCDPSession(page);
  await cdp.send("DOM.enable");
  await cdp.send("CSS.enable");
  const { root } = await cdp.send("DOM.getDocument");
  const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector: ".post-title .inline-emoji" });
  const { fonts } = await cdp.send("CSS.getPlatformFontsForNode", { nodeId });
  const fontState = await page.locator(".post-title .inline-emoji").first().evaluate(node => ({ style: getComputedStyle(node).fontFamily, faces: [...document.fonts].map(face => ({ family: face.family, status: face.status })) }));
  expect(fonts, JSON.stringify({ fontWarnings, fontState })).toEqual(expect.arrayContaining([expect.objectContaining({ isCustomFont: true, familyName: expect.stringMatching(/Noto.*Emoji/i) })]));
  expect(fontRequests.length).toBeGreaterThan(0);
  expect(fontRequests.every(url => new URL(url).origin === new URL(page.url()).origin)).toBe(true);
  const copied = await body.evaluate(node => {
    const range = document.createRange(); range.selectNodeContents(node);
    const selection = window.getSelection()!; selection.removeAllRanges(); selection.addRange(range);
    return selection.toString();
  });
  expect(copied).toBe(text);
  await expect(body.locator("img")).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("Emoji 字体加载失败时原文继续可读，不出现图片错误占位", async ({ page }) => {
  const { posts, errors } = await fixture(page);
  await page.route(/noto-color-emoji.*\.woff2?(?:\?.*)?$/, route => route.abort("failed"));
  await page.goto("./");
  await expect(page.locator(".dashboard-feed .post-title").first()).toHaveText(posts[0].title);
  await expect(page.locator(".dashboard-feed .post-body").nth(1)).toHaveText(posts[1].content);
  await expect(page.locator(".dashboard-feed .inline-emoji")).toHaveText(["😡", "😭", "🙏"]);
  await page.evaluate(async () => { await document.fonts.ready; });
  expect(errors).toEqual([]);
});
