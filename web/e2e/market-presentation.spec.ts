import { test, expect, type Page } from "@playwright/test";

async function setupMarket(page: Page) {
  const image = (id: number, width: number, height: number) => ({ id, thumb_url: `/uploads/market-test-${id}.svg`, origin_url: `/uploads/market-test-${id}.svg`, width, height });
  const base = { board_id: 2, type: "marketplace_sell", content: "校园闲置", author_id: 7, author: { id: 7, nickname: "测试校友" }, created_at: "2026-10-08T10:30:00+08:00", status: "normal", price: 88, reply_count: 3, images: [image(1, 600, 900)] };
  const state = {
    mode: "filled", requests: [] as URL[], writes: [] as string[], errors: [] as string[],
    posts: [
      { ...base, id: 675, title: "竖图商品：大学英语教材和学习资料" },
      { ...base, id: 676, title: "横图商品：自行车", images: [image(2, 900, 400)] },
      { ...base, id: 677, title: "图片损坏也能进入详情", images: [image(3, 500, 500)] },
      { ...base, id: 678, title: "无图片商品", images: [] },
      { ...base, id: 679, title: "已售商品", status: "sold" },
    ],
  };
  page.on("pageerror", (error) => state.errors.push(error.message));
  await page.route("**/uploads/market-test-*.svg", (route) => route.request().url().endsWith("3.svg")
    ? route.fulfill({ status: 503, body: "" })
    : route.fulfill({ contentType: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900"><rect width="600" height="900" fill="#d8eee9"/></svg>' }));
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    if (route.request().method() !== "GET") state.writes.push(url.pathname);
    if (["/api/user/profile", "/api/refresh"].includes(url.pathname)) return route.fulfill({ status: 401, json: { message: "未登录" } });
    if (url.pathname === "/api/posts") {
      state.requests.push(url);
      if (state.mode === "slow") await new Promise((resolve) => setTimeout(resolve, 600));
      if (state.mode === "error") return route.fulfill({ status: 503, json: { message: "集市暂时不可用" } });
      return route.fulfill({ json: { posts: state.mode === "empty" ? [] : state.posts, has_more: false } });
    }
    if (/^\/api\/posts\/\d+$/.test(url.pathname)) return route.fulfill({ json: { post: state.posts.find((post) => String(post.id) === url.pathname.split("/").at(-1)) } });
    return route.fulfill({ json: { items: [] } });
  });
  return state;
}

test("集市筛选使用真实参数，进入详情并返回保留筛选；游客发布先登录", async ({ page }) => {
  const state = await setupMarket(page);
  await page.goto("market");
  await expect(page.locator(".market-card")).toHaveCount(5);
  expect(state.requests.at(-1)?.searchParams.get("sort")).toBe("time");
  expect(state.requests.at(-1)?.searchParams.get("board")).toBe("2");
  await page.getByRole("button", { name: "求购", exact: true }).click();
  await expect(page.getByRole("button", { name: "求购", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.getByLabel("搜索内容").fill("教材");
  await page.getByRole("button", { name: "搜索", exact: true }).click();
  await expect(page).toHaveURL(/q=/);
  await expect.poll(() => state.requests.at(-1)?.searchParams.get("q")).toBe("教材");
  await expect(page.getByLabel("搜索内容")).toHaveValue("教材");
  await page.getByLabel("价格排序").selectOption("price");
  await expect(page).toHaveURL(/sort=price/);
  await expect.poll(() => state.requests.at(-1)?.searchParams.get("sort")).toBe("price");
  await expect(page.getByLabel("价格排序")).toHaveValue("price");
  await page.getByLabel("仅看未售").click();
  await expect(page.getByLabel("仅看未售")).toBeChecked();
  await expect.poll(() => state.requests.at(-1)?.searchParams.get("status")).toBe("normal");
  const params = state.requests.at(-1)!.searchParams;
  expect(params.get("type")).toBe("marketplace_buy");
  expect(params.get("q")).toBe("教材");
  expect(params.get("sort")).toBe("price");
  await page.locator(".market-card").first().click();
  await expect(page.getByRole("heading", { name: "竖图商品：大学英语教材和学习资料" })).toBeVisible();
  await expect(page.locator(".post-market-price")).toContainText("88");
  expect(await page.locator(".post-market-summary").evaluate((el) => el.getBoundingClientRect().bottom <= document.querySelector(".post-detail-gallery")!.getBoundingClientRect().top)).toBe(true);
  await page.getByRole("button", { name: "返回列表" }).click();
  await expect(page.getByLabel("搜索内容")).toHaveValue("教材");
  await expect(page.getByLabel("仅看未售")).toBeChecked();
  await expect(page.getByRole("button", { name: "求购", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "发布闲置", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园" })).toBeVisible();
  expect(state.writes.filter((path) => path !== "/api/refresh")).toEqual([]);
  expect(state.errors).toEqual([]);
});

test("商品图不覆盖标题价格，窄屏无横向溢出，损坏与无图片有可读占位", async ({ page }) => {
  const state = await setupMarket(page);
  await page.goto("market");
  await expect(page.locator(".market-card")).toHaveCount(5);
  await expect(page.getByText("图片暂不可用")).toBeVisible();
  await expect(page.getByText("暂无图片", { exact: true })).toBeVisible();
  for (const width of [1900, 1440, 1040, 860, 390, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    await expect.poll(() => page.locator(".market-img").first().evaluate((el) => Math.abs(el.getBoundingClientRect().width - el.getBoundingClientRect().height))).toBeLessThan(2);
    const geometry = await page.evaluate(() => ({
      overflow: document.documentElement.scrollWidth > innerWidth,
      cards: Array.from(document.querySelectorAll(".market-card")).map((card) => {
        const picture = card.querySelector(".market-img")!.getBoundingClientRect();
        const title = card.querySelector("h3")!.getBoundingClientRect();
        const price = card.querySelector(".price")!.getBoundingClientRect();
        const img = card.querySelector(".market-img img")?.getBoundingClientRect();
        return { titleBelow: title.top >= picture.bottom, priceBelow: price.top >= title.bottom, imageInside: !img || img.bottom <= picture.bottom + 1 };
      }),
    }));
    expect(geometry.overflow, `${width}px overflow`).toBe(false);
    expect(geometry.cards.every((card) => card.titleBelow && card.priceBelow && card.imageInside), `${width}px image overlap`).toBe(true);
  }
  await page.locator(".market-card").filter({ hasText: "图片损坏也能进入详情" }).click();
  await expect(page.getByRole("heading", { name: "图片损坏也能进入详情" })).toBeVisible();
  expect(state.errors).toEqual([]);
});

test("集市加载、失败重试与空态保留筛选", async ({ page }) => {
  const state = await setupMarket(page);
  state.mode = "slow";
  await page.goto("market?q=教材");
  await expect(page.getByText("正在加载…", { exact: true })).toBeVisible();
  await expect(page.locator(".market-card")).toHaveCount(5);
  state.mode = "error";
  await page.getByLabel("价格排序").selectOption("price_desc");
  await expect(page.getByText("集市暂时不可用", { exact: true })).toBeVisible();
  await expect(page.getByLabel("搜索内容")).toHaveValue("教材");
  state.mode = "empty";
  await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.getByText("没有找到闲置", { exact: true })).toBeVisible();
  await expect(page.getByText("试试调整搜索词或筛选条件。", { exact: true })).toBeVisible();
  expect(state.errors).toEqual([]);
});

test("进入集市导航收成图标，离开与浏览器返回恢复，快速切换和减少动态效果不残留", async ({ page }) => {
  await setupMarket(page);
  await page.goto("community");
  const sidebar = page.getByLabel("主导航");
  const sidebarWidth = () => sidebar.evaluate((el) => el.getBoundingClientRect().width);
  await expect.poll(sidebarWidth).toBe(208);
  await sidebar.evaluate((el) => {
    (window as any).__navWidths = [];
    el.addEventListener("transitionrun", () => {
      const start = performance.now();
      const measure = () => {
        (window as any).__navWidths.push(el.getBoundingClientRect().width);
        if (performance.now() - start < 250) requestAnimationFrame(measure);
      };
      requestAnimationFrame(measure);
    }, { once: true });
  });
  await sidebar.getByRole("link", { name: "二手集市", exact: true }).click();
  await expect.poll(sidebarWidth).toBe(64);
  expect(await page.evaluate(() => (window as any).__navWidths.some((width: number) => width > 64 && width < 208))).toBe(true);
  await expect(sidebar.getByRole("link", { name: "校园社区", exact: true })).toHaveAttribute("title", "校园社区");
  await sidebar.getByRole("link", { name: "校园社区", exact: true }).click();
  await expect.poll(sidebarWidth).toBe(208);
  await page.goBack();
  await expect.poll(sidebarWidth).toBe(64);
  await page.goForward();
  await expect.poll(sidebarWidth).toBe(208);
  await sidebar.getByRole("link", { name: "二手集市", exact: true }).press("Enter");
  await expect(page.locator(".app-shell")).toHaveClass(/market-shell/);
  expect(await sidebar.evaluate((el) => getComputedStyle(el).transitionProperty)).toBe("none");
  await sidebar.getByRole("link", { name: "校园社区", exact: true }).click();
  await expect.poll(sidebarWidth).toBe(208);
  await sidebar.getByRole("link", { name: "二手集市", exact: true }).click();
  await sidebar.getByRole("link", { name: "校园工作台", exact: true }).click();
  await expect.poll(sidebarWidth).toBe(208);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await sidebar.getByRole("link", { name: "二手集市", exact: true }).click();
  await expect(page).toHaveURL(/\/market$/);
  await expect(page.locator(".app-shell")).toHaveClass(/market-shell/);
  expect(await sidebarWidth()).toBe(64);
  expect(await sidebar.evaluate((el) => getComputedStyle(el).transitionProperty)).toBe("none");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "打开导航" }).click();
  await expect(sidebar.getByRole("link", { name: "校园社区", exact: true })).toBeVisible();
  await expect(sidebar.locator(".nav-text").filter({ hasText: "校园社区" })).toBeVisible();
  await sidebar.getByRole("link", { name: "校园社区", exact: true }).click();
  await expect(page.getByRole("button", { name: "打开导航" })).toHaveAttribute("aria-expanded", "false");
});

test("集市深色和 130% 文字保持商品信息可读", async ({ page }) => {
  await setupMarket(page);
  await page.addInitScript(() => localStorage.setItem("sylulive-theme", "dark"));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("market");
  await expect(page.locator(".market-card")).toHaveCount(5);
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.evaluate(() => {
    const sizes = Array.from(document.body.querySelectorAll<HTMLElement>("*"))
      .map((el) => ({ el, font: parseFloat(getComputedStyle(el).fontSize) }));
    sizes.forEach(({ el, font }) => { el.style.fontSize = `${font * 1.3}px`; });
  });
  expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
  expect(await page.locator(".market-card").evaluateAll((cards) => cards.every((card) => card.querySelector(".price")!.getBoundingClientRect().top >= card.querySelector("h3")!.getBoundingClientRect().bottom))).toBe(true);
  await page.screenshot({ path: "artifacts/web-social-redesign-2026-10-09/market-mobile-dark-large-text.png" });
});

type ShellFrame = { route: string; width: number; x: number; icons: number[]; brand: number; opacity: number; overflow: boolean; columns: string; cardWidth: number; bg: string };

async function recordShell(page: Page, reverse = false) {
  await page.evaluate((reverse) => {
    const frames: ShellFrame[] = [];
    const sample = () => {
      const workspace = document.querySelector(".workspace")!;
      const card = document.querySelector(".market-card");
      const grid = document.querySelector(".market-grid");
      frames.push({
        route: location.pathname,
        width: document.querySelector(".sidebar")!.getBoundingClientRect().width,
        x: workspace.getBoundingClientRect().left,
        icons: Array.from(document.querySelectorAll(".sidebar .nav-icon")).map((el) => el.getBoundingClientRect().top),
        brand: document.querySelector(".brand")!.getBoundingClientRect().left,
        opacity: Number(getComputedStyle(document.querySelector(".page")!).opacity),
        overflow: document.documentElement.scrollWidth > innerWidth,
        columns: grid ? getComputedStyle(grid).gridTemplateColumns : "",
        cardWidth: card?.getBoundingClientRect().width ?? 0,
        bg: getComputedStyle(document.querySelector(".app-shell")!).backgroundColor,
      });
    };
    (window as any).__shellFrames = frames;
    (window as any).__shellDone = false;
    document.addEventListener("click", () => {
      sample();
      const start = performance.now();
      if (reverse) setTimeout(() => document.querySelector<HTMLAnchorElement>('.sidebar a[href="/web/community"]')!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, detail: 1 })), 55);
      const tick = () => {
        sample();
        if (performance.now() - start < 420) requestAnimationFrame(tick);
        else (window as any).__shellDone = true;
      };
      requestAnimationFrame(tick);
    }, { capture: true, once: true });
  }, reverse);
}

async function shellFrames(page: Page): Promise<ShellFrame[]> {
  await expect.poll(() => page.evaluate(() => (window as any).__shellDone)).toBe(true);
  return page.evaluate(() => (window as any).__shellFrames);
}

test("公共外壳一致，收展逐帧没有图标跳位、透明闪屏、网格换列或横向溢出", async ({ page }) => {
  await setupMarket(page);
  for (const width of [1440, 1040, 820]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("community");
    await expect(page.getByRole("heading", { name: "校园社区", exact: true })).toBeVisible();
    await recordShell(page);
    await page.getByLabel("主导航").getByRole("link", { name: "二手集市", exact: true }).click();
    const frames = await shellFrames(page);
    expect(frames.every((frame) => frame.icons.every((top, i) => Math.abs(top - frames[0].icons[i]) < 1))).toBe(true);
    expect(frames.every((frame) => frame.brand === frames[0].brand && frame.bg === frames[0].bg && frame.opacity === 1 && !frame.overflow)).toBe(true);
    const products = frames.filter((frame) => frame.cardWidth > 0);
    expect(products.length).toBeGreaterThan(2);
    expect(new Set(products.map((frame) => frame.columns)).size).toBe(1);
    expect(Math.max(...products.map((frame) => frame.cardWidth)) - Math.min(...products.map((frame) => frame.cardWidth))).toBeLessThan(1);
    if (width > 860) {
      expect(frames.filter((frame) => frame.x < frames[0].x - 1 && frame.x > frames.at(-1)!.x + 1).length).toBeGreaterThan(2);
      expect(Math.max(...frames.slice(1).map((frame, i) => Math.abs(frame.x - frames[i].x)))).toBeLessThan(80);
    }
    await recordShell(page);
    await page.getByLabel("主导航").getByRole("link", { name: "校园工作台", exact: true }).click();
    const expanded = await shellFrames(page);
    expect(expanded.every((frame) => frame.icons.every((top, i) => Math.abs(top - expanded[0].icons[i]) < 1) && frame.bg === frames[0].bg && !frame.overflow)).toBe(true);
    expect(await page.locator(".today-card").evaluate((el) => ({ image: getComputedStyle(el).backgroundImage, shadow: getComputedStyle(el).boxShadow }))).toEqual({ image: "none", shadow: "none" });
  }
});

test("过渡中途反向沿当前位置继续，缩放、键盘与减少动态效果不会留下位移", async ({ page }) => {
  const state = await setupMarket(page);
  state.mode = "slow";
  await page.goto("community");
  await recordShell(page, true);
  await page.getByLabel("主导航").getByRole("link", { name: "二手集市", exact: true }).click();
  const frames = await shellFrames(page);
  expect(frames.some((frame) => frame.route.endsWith("/market"))).toBe(true);
  expect(frames.at(-1)!.route).toMatch(/\/community$/);
  expect(Math.max(...frames.slice(1).map((frame, i) => Math.abs(frame.x - frames[i].x)))).toBeLessThan(80);
  expect(frames.at(-1)!.x).toBe(frames[0].x);
  expect(await page.locator(".workspace").evaluate((el) => el.getAnimations().length)).toBe(0);
  await page.getByLabel("主导航").getByRole("link", { name: "二手集市", exact: true }).press("Enter");
  expect(await page.locator(".workspace").evaluate((el) => el.getAnimations().length)).toBe(0);
  expect(await page.locator(".sidebar .nav-text").first().evaluate((el) => getComputedStyle(el).transitionProperty)).toBe("none");
  await page.getByLabel("主导航").getByRole("link", { name: "校园社区", exact: true }).click();
  await page.setViewportSize({ width: 820, height: 900 });
  expect(await page.locator(".workspace").evaluate((el) => getComputedStyle(el).transform)).toBe("none");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByLabel("主导航").getByRole("link", { name: "二手集市", exact: true }).click();
  expect(await page.locator(".workspace").evaluate((el) => el.getAnimations().length)).toBe(0);
  expect(await page.locator(".sidebar .nav-text").first().evaluate((el) => getComputedStyle(el).transitionProperty)).toBe("none");
  expect(state.errors).toEqual([]);
});
