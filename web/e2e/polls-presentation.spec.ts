import { test, expect, type Page } from "@playwright/test";

async function fixture(page: Page, guest = false) {
  const state = { guest, account: 991, requests: [] as number[][], queries: [] as string[], completed: 0, fail: false, hold: Promise.resolve() };
  const posts = [
    { id: 901, title: "网页端 UI 投票", content: "希望网页端 UI 怎么设计？一起选出更适合校园的样子。", poll_meta: {
      effective_status: "active", selection_mode: "multiple", max_choices: 2, can_vote: true, can_change: false, has_voted: false,
      participant_count: 14, ends_at: "2027-11-06T07:31:04+08:00", results_visible: true,
      options: ["淡色分区，保留清晰的内容层级", "直接淡色打底，让阅读更轻松", "整体淡色渐变", "其他想法，可以在评论区聊聊"].map((text, index) => ({ id: index + 1, text, vote_count: [13, 1, 0, 0][index], is_chosen: false })),
    } },
    { id: 902, title: "你更喜欢在哪里自习？", content: "选择一个你常去的地方。", poll_meta: {
      effective_status: "active", selection_mode: "single", max_choices: 1, can_vote: true, can_change: true, has_voted: true,
      participant_count: 20, ends_at: "2027-11-22T17:46:00+08:00", results_visible: true,
      options: [{ id: 11, text: "图书馆", vote_count: 15, is_chosen: true }, { id: 12, text: "空教室", vote_count: 5, is_chosen: false }],
    } },
    { id: 903, title: "沈理最适合的生活费？", content: "这场投票已经结束，来看看同学们的选择。", poll_meta: {
      effective_status: "closed", selection_mode: "single", max_choices: 1, can_vote: false, can_change: false, has_voted: false,
      participant_count: 62, ends_at: "2026-09-18T15:14:26+08:00", results_visible: true,
      options: ["1000 以下", "1000–2000", "2000–3000", "3000 以上"].map((text, index) => ({ id: 21 + index, text, vote_count: [4, 44, 13, 1][index], is_chosen: false })),
    } },
    { id: 904, title: "下一次校园活动，想去哪里？", content: "结果将在结束后公开。", poll_meta: {
      effective_status: "active", selection_mode: "single", max_choices: 1, can_vote: true, can_change: false, has_voted: false,
      participant_count: 8, ends_at: "2027-11-22T17:46:00+08:00", results_visible: false, results_visibility: "after_end",
      options: [{ id: 31, text: "校园徒步", vote_count: 7, is_chosen: false }, { id: 32, text: "读书分享会", vote_count: 1, is_chosen: false }],
    } },
  ].map(post => ({ ...post, author: { id: 7, nickname: "投票测试同学" }, created_at: "2026-11-03T10:00:00+08:00", images: post.id === 901 ? [{ id: 1, origin_url: "/uploads/poll-fixture.svg", width: 600, height: 300 }] : [], poll_meta: { ...post.poll_meta, id: post.id + 10000 } }));
  await page.route("**/uploads/poll-fixture.svg", route => route.fulfill({ contentType: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="300"><rect width="600" height="300" fill="#f2f5fa"/><rect x="30" y="30" width="250" height="240" rx="16" fill="white" stroke="#dce1e9"/><rect x="310" y="30" width="260" height="240" rx="16" fill="white" stroke="#dce1e9"/><path d="M60 90h190M60 140h150M60 190h170M340 90h190M340 140h150M340 190h170" stroke="#dce1e9" stroke-width="10" stroke-linecap="round"/></svg>' }));
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/user/profile") return state.guest ? route.fulfill({ status: 401, json: { message: "未登录" } }) : route.fulfill({ json: { id: state.account, nickname: "校园测试同学", role: "user" } });
    if (path === "/api/refresh") return route.fulfill({ status: 401, json: {} });
    if (path === "/api/polls") { state.queries.push(new URL(route.request().url()).search); return route.fulfill({ json: { posts } }); }
    if (path.endsWith("/ballot")) {
      const ids = route.request().postDataJSON().option_ids as number[];
      state.requests.push(ids);
      await state.hold;
      if (state.fail) return route.fulfill({ status: 503, json: { message: "投票服务暂不可用" } });
      const poll = posts.find(post => path.includes(`/${post.poll_meta.id}/`))!.poll_meta;
      poll.has_voted = true;
      poll.can_change = true;
      poll.options.forEach(option => { option.is_chosen = ids.includes(option.id); });
      await route.fulfill({ json: {} });
      state.completed += 1;
      return;
    }
    if (path === "/api/team/recruitments") return route.fulfill({ json: { recruitments: [{ id: 71, title: "一起准备数学建模比赛", description: "寻找愿意一起学习、讨论的队友，周末可以在图书馆碰面。", status: "recruiting", remaining_count: 2, roles: ["编程", "论文写作"], deadline: "2027-11-22T17:46:00+08:00" }] } });
    if (path === "/api/team/recruitments/71") return route.fulfill({ json: { recruitment: { id: 71, description: "一起准备比赛", status: "recruiting", can_apply: false } } });
    return route.fulfill({ json: { items: [] } });
  });
  return { state, posts, errors };
}

test("投票整行选择、限选、回显、等待与失败重试", async ({ page }) => {
  const { state, errors } = await fixture(page);
  await page.goto("polls");
  await expect(page.locator(".poll-feed .poll-card")).toHaveCount(4);
  await expect(page.locator(".poll-author-copy").first()).toContainText("投票测试同学");
  await expect(page.locator(".poll-media img")).toBeVisible();
  const card = page.getByRole("article", { name: "网页端 UI 投票", exact: true });
  await expect(card.getByRole("button", { name: "选择后提交", exact: true })).toBeDisabled();
  await card.locator(".poll-choice-text").nth(0).click();
  await card.locator(".poll-choice-text").nth(1).click();
  await expect(card.getByRole("checkbox").nth(2)).toBeDisabled();
  await expect(card).toContainText("已选 2/2 项");
  await card.getByRole("checkbox").nth(0).uncheck();
  await expect(card.getByRole("checkbox").nth(2)).toBeEnabled();
  await card.getByRole("checkbox").nth(2).check();
  let release = () => {};
  state.hold = new Promise<void>(resolve => { release = resolve; });
  state.fail = true;
  await card.getByRole("button", { name: "提交选择", exact: true }).click();
  await expect(card.getByRole("button", { name: "提交中…" })).toBeDisabled();
  await expect(card.getByRole("checkbox").nth(1)).toBeDisabled();
  expect(state.requests).toEqual([[2, 3]]);
  release();
  await expect(card.getByRole("alert")).toContainText("投票服务暂不可用");
  await expect(card.getByRole("checkbox").nth(1)).toBeChecked();
  state.fail = false;
  await card.getByRole("button", { name: "重试投票" }).click();
  await expect(card.getByRole("button", { name: "已提交选择" })).toBeDisabled();
  expect(state.requests).toEqual([[2, 3], [2, 3]]);
  const saved = page.getByRole("article", { name: "你更喜欢在哪里自习？", exact: true });
  await expect(saved.getByRole("radio", { name: "图书馆", exact: true })).toBeChecked();
  await saved.getByRole("radio", { name: "空教室", exact: true }).check();
  await saved.getByRole("button", { name: "确认修改" }).click();
  await expect(saved.getByRole("button", { name: "已提交选择" })).toBeDisabled();
  expect(state.requests[2]).toEqual([12]);
  await expect(page.getByRole("article", { name: "沈理最适合的生活费？", exact: true }).getByRole("button", { name: "投票已结束" })).toBeDisabled();
  await expect(page.getByRole("article", { name: "下一次校园活动，想去哪里？", exact: true }).locator(".poll-result")).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("游客登录、键盘标签切换、组队详情与搜索空态", async ({ page }) => {
  await fixture(page, true);
  await page.goto("polls");
  const card = page.getByRole("article", { name: "网页端 UI 投票", exact: true });
  await expect(card.getByRole("checkbox").first()).toBeDisabled();
  await card.getByRole("button", { name: "登录参与" }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(card.getByRole("button", { name: "登录参与" })).toBeFocused();
  await page.getByRole("tab", { name: "校园投票" }).focus();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("tab", { name: "组队广场" })).toBeFocused();
  await expect(page.getByRole("tab", { name: "组队广场" })).toHaveAttribute("aria-selected", "true");
  await expect(page.locator(".team-card")).toContainText("招募中");
  await page.getByRole("button", { name: "查看组队" }).click();
  await expect(page.getByRole("dialog")).toContainText("一起准备比赛");
  await page.keyboard.press("Escape");
  await page.getByRole("tab", { name: "组队广场" }).press("Home");
  await expect(page.getByRole("tab", { name: "校园投票" })).toBeFocused();
  await page.getByRole("button", { name: "搜索功能", exact: true }).click();
  await page.getByRole("textbox", { name: "搜索功能", exact: true }).fill("没有这个入口");
  await expect(page.getByRole("dialog")).toContainText("没有找到相关功能");
  await page.getByRole("button", { name: "清空搜索" }).click();
  await expect(page.getByRole("button", { name: "课表", exact: true })).toBeVisible();
});

test("投票列表加载、失败重试与空态", async ({ page }) => {
  await fixture(page);
  let release = () => {}, failed = true;
  const hold = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/polls?**", async route => {
    await hold;
    return failed ? route.fulfill({ status: 503, json: { message: "测试连接失败" } }) : route.fulfill({ json: { posts: [] } });
  });
  await page.goto("polls");
  await expect(page.locator(".polls-page").getByRole("status")).toContainText("正在加载");
  release();
  await expect(page.locator(".polls-page")).toContainText("加载未完成");
  failed = false;
  await page.locator(".polls-page").getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.locator(".polls-page")).toContainText("还没有校园投票");
});

test("对照 App 保留作者、附图、排序与分类，并隔离迟到的筛选请求", async ({ page }) => {
  const { posts, state } = await fixture(page);
  await page.goto("polls");
  await expect(page.locator(".poll-author-copy").first()).toContainText("投票测试同学");
  await page.locator(".poll-media button").first().click();
  await expect(page.getByRole("dialog", { name: "图片预览", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "学习", exact: true }).click();
  await expect.poll(() => state.queries.some(search => search.includes("category=study"))).toBe(true);
  let release = () => {};
  const hold = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/polls?**", async route => {
    const sort = new URL(route.request().url()).searchParams.get("sort");
    if (sort === "latest") await hold;
    await route.fulfill({ json: { posts: [{ ...posts[0], title: sort === "ending" ? "即将结束的投票" : "迟到的最新投票" }] } });
  });
  await page.getByRole("tab", { name: "最新", exact: true }).click();
  await expect(page.locator(".polls-page .loading-state")).toBeVisible();
  await page.getByRole("tab", { name: "即将结束", exact: true }).click();
  await expect(page).toHaveURL(/sort=ending/);
  await expect(page).toHaveURL(/category=study/);
  await expect(page.locator(".poll-card h3")).toHaveText("即将结束的投票");
  release();
  await expect(page.locator(".poll-card h3")).toHaveText("即将结束的投票");
});

test("投票权限、键盘焦点、高对比与放大文字", async ({ page }) => {
  const { posts } = await fixture(page);
  posts[1].poll_meta.can_vote = false;
  posts[1].poll_meta.can_change = false;
  await page.emulateMedia({ forcedColors: "active", reducedMotion: "reduce" });
  await page.setViewportSize({ width: 390, height: 1000 });
  await page.goto("polls");
  const locked = page.getByRole("article", { name: "你更喜欢在哪里自习？", exact: true });
  await expect(locked.getByRole("radio").first()).toBeChecked();
  await expect(locked.getByRole("radio").first()).toBeDisabled();
  await expect(locked.getByRole("button", { name: "已提交，不可修改" })).toBeDisabled();
  const choice = page.locator(".poll-choice").first();
  await choice.getByRole("checkbox").focus();
  await page.keyboard.press("Space");
  await expect(choice.getByRole("checkbox")).toBeChecked();
  await expect(choice).toHaveCSS("outline-width", "2px");
  await expect(choice).toHaveCSS("border-top-width", "2px");
  await page.evaluate(() => {
    const sizes = [...document.querySelectorAll<HTMLElement>(".polls-page *")].map(el => ({ el, size: parseFloat(getComputedStyle(el).fontSize) }));
    sizes.forEach(({ el, size }) => { el.style.fontSize = `${size * 1.5}px`; });
  });
  expect(await page.locator(".poll-card").evaluateAll(cards => cards.every(card => card.scrollWidth <= card.clientWidth))).toBe(true);
  expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
});

test("切换账号和离开页面时旧投票回包不回填", async ({ page }) => {
  const { state, posts } = await fixture(page);
  await page.goto("polls");
  const card = page.getByRole("article", { name: "网页端 UI 投票", exact: true });
  await card.getByRole("checkbox").first().check();
  let release = () => {};
  state.hold = new Promise<void>(resolve => { release = resolve; });
  await card.getByRole("button", { name: "提交选择", exact: true }).click();
  state.account = 992;
  await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  await expect(card.getByRole("checkbox").first()).not.toBeChecked();
  release();
  await expect.poll(() => state.completed).toBe(1);
  await expect(page.locator(".toast")).not.toContainText("投票结果已更新");
  await expect(card.getByRole("checkbox").first()).not.toBeChecked();
  // 再发一次请求后切走，完成回包不能在组队页弹出投票成功提示。
  posts[0].poll_meta.options.forEach(option => { option.is_chosen = false; });
  state.hold = new Promise<void>(resolve => { release = resolve; });
  await card.getByRole("checkbox").nth(1).check();
  await card.getByRole("button", { name: "提交选择", exact: true }).click();
  await page.getByRole("tab", { name: "组队广场" }).click();
  await expect(page.locator(".team-card")).toBeVisible();
  const response = page.waitForResponse("**/api/polls/10901/ballot");
  release();
  await response;
  await expect(page.locator(".toast")).not.toContainText("投票结果已更新");
});

for (const theme of ["light", "dark"]) {
  test(`投票组件长文本、阅读边界与真实渲染 ${theme}`, async ({ page }) => {
    const { posts, errors } = await fixture(page);
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    for (const width of [320, 390, 820, 1280, 1758]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.goto("polls");
      await expect(page.locator('.top-actions .avatar[aria-label="我的账号"]')).toHaveCount(1);
      await expect(page.locator(".poll-card")).toHaveCount(4);
      await expect(page.locator(".poll-card").first()).toHaveCSS("border-top-width", "1px");
      const layers = await page.locator(".poll-card").first().evaluate(card => {
        const surface = getComputedStyle(card);
        const heading = card.querySelector(".participation-heading")!;
        const options = card.querySelector(".poll-choices")!;
        const titleBox = heading.getBoundingClientRect(), optionsBox = options.getBoundingClientRect();
        return {
          border: surface.borderTopWidth,
          radius: surface.borderTopLeftRadius,
          fullWidthSubmit: Math.abs(card.querySelector(".poll-submit .btn")!.getBoundingClientRect().width - optionsBox.width) < 1,
          grouped: titleBox.bottom < optionsBox.top,
          resultHeight: getComputedStyle(card.querySelector(".poll-choice")!, "::before").height,
        };
      });
      expect(layers.border).toBe("1px");
      expect(layers.radius).toBe("16px");
      expect(layers.fullWidthSubmit).toBe(true);
      expect(layers.grouped).toBe(true);
      expect(layers.resultHeight).toBe("5px");
      const geometry = await page.locator(".poll-choice").evaluateAll(elements => elements.map(el => {
        const rect = el.getBoundingClientRect();
        return { height: rect.height, overflow: el.scrollWidth > el.clientWidth, outside: [...el.children].some(child => { const box = child.getBoundingClientRect(); return box.left < rect.left || box.right > rect.right; }) };
      }));
      expect(geometry.every(row => row.height >= 44 && !row.overflow && !row.outside)).toBe(true);
      expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
      if (width === 390 || width === 1758) await page.screenshot({ path: `.codex-captures/ui-refinement/polls-${theme}-${width}.png`, fullPage: true });
    }
    posts[0].title = "超长校园投票标题".repeat(15);
    posts[0].poll_meta.options[0].text = "这是用于检查长选项换行的测试文本".repeat(20);
    await page.setViewportSize({ width: 390, height: 1000 });
    await page.reload();
    await expect(page.locator(".poll-choice-text").first()).toContainText("这是用于检查");
    expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
    expect(errors).toEqual([]);
  });
}
