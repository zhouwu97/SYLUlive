import { test, expect, type Page } from "@playwright/test";

const svg = (width: number, height: number, label: string) => `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><rect width="${width}" height="${height}" fill="#edf3ff"/><rect x="20" y="20" width="${width - 40}" height="150" rx="12" fill="#3867f5"/><text x="40" y="105" fill="white" font-family="sans-serif" font-size="38">${label}</text><path d="M40 240h${width - 80}m-${width - 80} 80h${width - 80}m-${width - 80} 80h${width - 80}" stroke="#69717e" stroke-width="14"/><rect x="40" y="${height - 160}" width="${width - 80}" height="120" fill="#a2bad6"/></svg>`;

async function mediaFixture(page: Page) {
  const post = { id: 920, board_id: 1, title: "校园图片与长图验收", content: "清楚展示照片主体与长截图顶部内容，完整内容可以在详情或原图中查看。", author_id: 7, author: { id: 7, nickname: "图片测试同学", avatar: "/uploads/media-avatar.svg" }, images: [
    { id: 1, file: { width: 600, height: 1800 }, thumb_url: "/uploads/media-thumb.svg", medium_url: "/uploads/media-medium.svg", viewer_url: "/uploads/media-viewer.svg", origin_url: "/uploads/media-origin.svg" },
    { id: 2, file: { width: 600, height: 800 }, medium_url: "/uploads/media-photo.svg", origin_url: "/uploads/media-photo.svg" },
  ] };
  let mediumFailed = false, viewerFailed = false;
  const requests: string[] = [];
  await page.route("**/uploads/media-*.svg", route => {
    const path = new URL(route.request().url()).pathname;
    requests.push(path);
    if ((mediumFailed && path.endsWith("medium.svg")) || (viewerFailed && path.endsWith("viewer.svg"))) return route.fulfill({ status: 503, body: "unavailable" });
    const portrait = ["medium", "viewer", "origin"].some(variant => path.endsWith(`${variant}.svg`));
    return route.fulfill({ contentType: "image/svg+xml", body: svg(600, portrait ? 1800 : path.endsWith("photo.svg") ? 800 : 600, portrait ? "TOP / CAMPUS GUIDE" : "CAMPUS PHOTO") });
  });
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 3, nickname: "资源测试同学", avatar: "https://sylulive.online/uploads/media-avatar.svg", role: "user" } });
    if (path === "/api/posts") return route.fulfill({ json: { posts: [post], has_more: false } });
    if (path === "/api/posts/920") return route.fulfill({ json: { post } });
    if (path === "/api/water/sections") return route.fulfill({ json: { sections: [{ id: 1, slug: "study", title: "课程学习", avatar_url: "/uploads/media-section.svg", icon_key: "menu_book" }] } });
    return route.fulfill({ json: { items: [] } });
  });
  return { post, requests, failMedium: (value: boolean) => { mediumFailed = value; }, failViewer: (value: boolean) => { viewerFailed = value; } };
}

test("用户头像与板块图标读取服务端资源，损坏时回退且新头像可以恢复", async ({ page }) => {
  await mediaFixture(page);
  await page.goto("./");
  for (const selector of [".top-actions .avatar img", ".profile-rail-avatar img", ".composer-avatar img", ".feed-card .post-avatar img", ".board-avatar img"]) {
    await expect(page.locator(selector).first()).toHaveJSProperty("complete", true);
    expect(await page.locator(selector).first().evaluate((img: HTMLImageElement) => img.naturalWidth)).toBeGreaterThan(0);
  }
  await expect(page.locator(".profile-rail-avatar img")).toHaveAttribute("src", "/uploads/media-avatar.svg");
  await expect(page.locator(".board-avatar img")).toHaveAttribute("src", "/uploads/media-section.svg");
  await page.route("**/uploads/media-avatar.svg", route => route.fulfill({ status: 404, body: "missing" }));
  await page.reload();
  await expect(page.locator(".profile-rail-avatar .server-avatar-fallback")).toHaveText("资");
  await page.route("**/api/user/profile", route => route.fulfill({ json: { id: 4, nickname: "新的校园同学", avatar: "/uploads/media-new-avatar.svg", role: "user" } }));
  await page.reload();
  await expect(page.locator(".profile-rail-avatar img")).toHaveAttribute("src", "/uploads/media-new-avatar.svg");
  await expect(page.locator(".profile-rail-avatar img")).toHaveJSProperty("complete", true);
});

test("双图保持既定外框，长图展示顶部内容，预览与原图保留完整比例", async ({ page }) => {
  const state = await mediaFixture(page);
  await page.setViewportSize({ width: 1480, height: 1120 });
  await page.goto("community");
  const gallery = page.locator(".community-feed .media-gallery");
  await expect(gallery.locator("img").first()).toHaveAttribute("src", "/uploads/media-medium.svg");
  await expect(gallery.locator(".media-long-label")).toBeVisible();
  const readPreview = () => gallery.locator(".media-tile").first().evaluate(el => {
    const frame = el.getBoundingClientRect(), image = el.querySelector("img")!;
    return { width: frame.width, height: frame.height, fit: getComputedStyle(image).objectFit, position: getComputedStyle(image).objectPosition };
  });
  // 登录资料恢复会重挂载帖子；断言使用轮询成功的同一次真实布局采样。
  let preview = await readPreview();
  await expect.poll(async () => {
    preview = await readPreview();
    return preview.width > 240 && preview.height > 240;
  }).toBe(true);
  expect(preview.width).toBeGreaterThan(240);
  expect(preview.height).toBeGreaterThan(240);
  expect(preview.fit).toBe("cover");
  expect(preview.position).toBe("50% 0%");
  expect(state.requests).not.toContain("/uploads/media-thumb.svg");
  await gallery.locator("img").evaluateAll(async images => { await Promise.all(images.map(img => (img as HTMLImageElement).decode())); });
  await page.screenshot({ path: ".codex-captures/desktop-white-blue/post-media-preview.png" });
  await gallery.getByRole("button").first().click();
  const lightbox = page.getByRole("dialog", { name: "图片预览" });
  await expect(lightbox.getByRole("link", { name: "打开原图", exact: true })).toHaveAttribute("href", "/uploads/media-origin.svg");
  await expect(lightbox.locator(".media-lightbox-stage img")).toHaveAttribute("src", "/uploads/media-viewer.svg");
  const fullImage = await lightbox.locator(".media-lightbox-stage img").evaluate(async (img: HTMLImageElement) => {
    await img.decode();
    const box = img.getBoundingClientRect();
    return { ratio: box.height / box.width, natural: img.naturalHeight / img.naturalWidth };
  });
  expect(fullImage.ratio).toBeCloseTo(fullImage.natural, 1);
  await page.keyboard.press("ArrowRight");
  await expect(lightbox.locator(".media-lightbox-stage img")).toHaveAttribute("src", "/uploads/media-photo.svg");
  await page.keyboard.press("Escape");
  await page.goto("post/920");
  await expect(page.locator(".post-detail-gallery .media-tile img").first()).toHaveJSProperty("complete", true);
  await page.locator(".post-detail-gallery img").evaluateAll(async images => { await Promise.all(images.map(img => (img as HTMLImageElement).decode())); });
  const detail = await page.locator(".post-detail-gallery .media-tile").first().evaluate(el => ({ height: el.getBoundingClientRect().height, fit: getComputedStyle(el.querySelector("img")!).objectFit, position: getComputedStyle(el.querySelector("img")!).objectPosition }));
  expect(detail.height).toBe(300);
  expect(detail.fit).toBe("cover");
  expect(detail.position).toBe("50% 0%");
  await page.screenshot({ path: ".codex-captures/desktop-ratio-fix/post-media-detail.png" });
});

test("长图元数据与异步加载不会撑高图片组件", async ({ page }) => {
  const state = await mediaFixture(page);
  state.post.images[0].file.height = 9000;
  let release = () => {};
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/uploads/media-viewer.svg", async route => { await pending; await route.fulfill({ contentType: "image/svg+xml", body: svg(600, 9000, "LONG CAMPUS GUIDE") }); });
  await page.goto("post/920");
  const first = page.locator(".post-detail-gallery .media-tile").first();
  await expect(page.locator(".profile-rail-card")).toContainText("资源测试同学");
  await expect(first).toBeVisible();
  await expect(first).toHaveCSS("height", "300px");
  release();
  await first.locator("img").evaluate(async (img: HTMLImageElement) => { await img.decode(); });
  expect(await first.evaluate(el => el.getBoundingClientRect().height)).toBe(300);
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await first.evaluate(el => el.getBoundingClientRect().height)).toBe(200);
});

test("服务端嵌套宽高在单图加载前预留尺寸，不会先塌缩再撑开", async ({ page }) => {
  const state = await mediaFixture(page);
  state.post.images.splice(1);
  let release = () => {};
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/uploads/media-medium.svg", async route => { await pending; await route.fulfill({ contentType: "image/svg+xml", body: svg(600, 1800, "LONG CAMPUS GUIDE") }); });
  await page.goto("community");
  await expect(page.locator(".profile-rail-card")).toContainText("资源测试同学");
  const tile = page.locator(".community-feed .media-tile").first();
  await expect(tile.locator("img")).toHaveAttribute("width", "600");
  await expect(tile.locator("img")).toHaveAttribute("height", "1800");
  const before = await tile.evaluate(el => ({ width: el.getBoundingClientRect().width, height: el.getBoundingClientRect().height }));
  expect(before).toEqual({ width: 320, height: 320 });
  release();
  await tile.locator("img").evaluate(async (img: HTMLImageElement) => { await img.decode(); });
  const after = await tile.evaluate(el => ({ width: el.getBoundingClientRect().width, height: el.getBoundingClientRect().height }));
  expect(after).toEqual(before);
});

test("单图动态始终在正文下方，收紧阅读宽度后缩放、预览与重试可用", async ({ page }) => {
  const state = await mediaFixture(page);
  state.post.images.splice(1);
  state.post.title = "100天啦";
  state.post.content = "记录一下今天的小成就！";
  for (const theme of ["light", "dark"]) {
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    for (const path of ["./", "community"]) {
      await page.setViewportSize({ width: 1480, height: 1120 });
      await page.goto(path);
      const card = page.locator(".feed-card").first();
      const image = card.locator(".media-tile img");
      await image.evaluate(async (img: HTMLImageElement) => { await img.decode(); });
      // 在同一挂载实例上改变宽度，避免只验证重新加载后的静态布局。
      for (const width of [1480, 1180, 1100, 390, 320, 1920, 1480]) {
        await page.setViewportSize({ width, height: 1120 });
        const readLayout = () => card.evaluate(el => {
          const box = el.getBoundingClientRect();
          const author = el.querySelector(".post-author")!.getBoundingClientRect();
          const summary = el.querySelector(".post-summary")!.getBoundingClientRect();
          const media = el.querySelector(".media-gallery")!.getBoundingClientRect();
          const toolbar = el.querySelector(".post-toolbar")!.getBoundingClientRect();
          return {
            width: box.width,
            stacked: summary.top >= author.bottom && media.top >= summary.bottom && toolbar.top >= media.bottom,
            aligned: Math.abs(author.left - summary.left) < 1 && Math.abs(summary.left - media.left) < 1,
            mediaGap: media.top - summary.bottom,
            mediaMargin: getComputedStyle(el.querySelector(".media-gallery")!).marginTop,
            summaryRect: { top: summary.top, bottom: summary.bottom, height: summary.height },
            mediaRect: { top: media.top, bottom: media.bottom, height: media.height },
            toolbarGap: toolbar.top - media.bottom,
            actionBounds: [...el.querySelectorAll(".post-interaction")].map(action => ({ card: box.toJSON(), action: action.getBoundingClientRect().toJSON() })),
            actionsFit: [...el.querySelectorAll(".post-interaction")].every(action => {
              const rect = action.getBoundingClientRect();
              return rect.height >= 44 && rect.left >= box.left && rect.right <= box.right;
            }),
          };
        });
        // 使用轮询成功的同一次采样，避免重挂载后再次读取到已脱离 DOM 的旧卡片。
        let layout = await readLayout();
        await expect.poll(async () => {
          layout = await readLayout();
          return layout.width > 0 && layout.stacked && layout.aligned && layout.width <= 720 && layout.actionsFit;
        }).toBe(true);
        expect(layout.stacked && layout.aligned).toBe(true);
        expect(layout.width).toBeLessThanOrEqual(720);
        expect(layout.mediaGap, JSON.stringify({ width, path, theme, layout })).toBeGreaterThanOrEqual(8);
        expect(layout.mediaGap).toBeLessThanOrEqual(12);
        expect(layout.toolbarGap).toBeLessThanOrEqual(14);
        expect(layout.actionsFit, JSON.stringify({ width, path, layout })).toBe(true);
        expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
        if (width === 390 && path === "./") await card.screenshot({ path: `.codex-captures/feed-density/${theme}-mobile-card.png` });
      }
      if (path === "./") {
        await card.scrollIntoViewIfNeeded();
        await page.screenshot({ path: `.codex-captures/feed-density/${theme}-desktop.png` });
        await card.screenshot({ path: `.codex-captures/feed-density/${theme}-card.png` });
      }
      await card.evaluate(el => { (el as HTMLElement).style.fontSize = "130%"; el.querySelectorAll<HTMLElement>("h3, p, .author-meta, .post-interaction").forEach(child => child.style.fontSize = "1.3em"); });
      expect(await card.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
      if (path === "./") await card.screenshot({ path: `.codex-captures/feed-density/${theme}-large-text-card.png` });
      await card.getByRole("button", { name: "100天啦第 1 张" }).click();
      await expect(page.getByRole("dialog", { name: "图片预览" })).toBeVisible();
      await page.keyboard.press("Escape");
    }
  }
  state.failMedium(true);
  await page.reload();
  const failed = page.locator(".feed-card .media-tile").first();
  await expect(failed).toContainText("点击重试");
  expect(await failed.evaluate(el => el.getBoundingClientRect().width)).toBe(320);
  state.failMedium(false);
  await failed.click();
  await expect(failed.locator("img")).toBeVisible();
});

test("清晰预览及原图加载失败可以重试，更新图片后不继承旧失败", async ({ page }) => {
  const state = await mediaFixture(page);
  state.failMedium(true);
  await page.goto("community");
  const first = page.locator(".community-feed .media-tile").first();
  await expect(first).toContainText("图片加载失败 · 点击重试");
  state.failMedium(false);
  await first.click();
  await expect(first.locator("img")).toBeVisible();
  state.failViewer(true);
  await first.click();
  const lightbox = page.getByRole("dialog", { name: "图片预览" });
  await expect(lightbox.getByRole("alert")).toContainText("图片加载失败");
  state.failViewer(false);
  await lightbox.getByRole("button", { name: "重试", exact: true }).click();
  await expect(lightbox.locator(".media-lightbox-stage img")).toBeVisible();
  await page.keyboard.press("Escape");
  state.post.images[0].medium_url = "/uploads/media-new.svg";
  await page.goto("community?sort=time");
  await expect(page.locator(".community-feed .media-tile img").first()).toHaveAttribute("src", "/uploads/media-new.svg");
});
