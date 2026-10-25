import { test, expect, type Page } from "@playwright/test";

async function visualFixture(page: Page) {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const post = { id: 675, board_id: 1, title: "视觉验收：校园学习与生活", content: "此处为受控测试数据，用于检查中文排版、真实比例图片和互动栏。", author_id: 7, author: { id: 7, nickname: "测试同学", level: 3 }, created_at: "2026-10-09T09:00:00+08:00", like_count: 4, reply_count: 1, price: 88, images: [{ id: 1, thumb_url: "/uploads/theme-fixture.svg", origin_url: "/uploads/theme-fixture.svg", width: 600, height: 900 }] };
  await page.route("**/uploads/theme-fixture.svg", (route) => route.fulfill({ contentType: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900"><rect width="600" height="900" fill="#e8ebf4"/><rect x="100" y="100" width="400" height="700" rx="15" fill="#9ba8c7"/><text x="300" y="450" text-anchor="middle" font-size="40" fill="#27314b">TEST FIXTURE</text></svg>' }));
  await page.route("**/api/**", (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/user/profile") return route.fulfill({ json: { id: 3, nickname: "视觉测试同学", role: "user" } });
    if (url.pathname === "/api/posts") return route.fulfill({ json: { posts: url.searchParams.get("board") === "2" ? Array.from({ length: 5 }, (_, i) => ({ ...post, id: 675 + i, board_id: 2, type: "marketplace_sell", title: `测试教材 ${i + 1}` })) : [post], has_more: false } });
    if (url.pathname === "/api/posts/675") return route.fulfill({ json: { post } });
    if (url.pathname === "/api/posts/675/replies") return route.fulfill({ json: { replies: [{ id: 101, author_id: 8, author: { nickname: "回复测试同学" }, content: "评论正文与操作应保持清楚可读。", created_at: post.created_at }], total: 1 } });
    if (url.pathname === "/api/water/sections") return route.fulfill({ json: { sections: [{ id: 1, slug: "study", title: "课程学习", description: "测试分区说明：课程评价、学习资料和选课建议。" }] } });
    return route.fulfill({ json: { items: [] } });
  });
  return errors;
}

test("新主题四个主页面在 320–1900px 和深浅色下可读、无重叠，保留键盘焦点", async ({ page }) => {
  const errors = await visualFixture(page);
  for (const theme of ["light", "dark"]) {
    await page.addInitScript((theme) => localStorage.setItem("sylulive-theme", theme), theme);
    for (const width of [320, 375, 414, 768, 1132, 1280, 1440, 1900]) {
      await page.setViewportSize({ width, height: width === 1280 ? 800 : 1000 });
      for (const route of ["./", "community", "post/675", "market"]) {
        await page.goto(route);
        await expect(page.locator(".post-author, .market-card").first()).toBeVisible();
        const result = await page.evaluate(() => {
          const ctx = document.createElement("canvas").getContext("2d")!;
          const luminance = (color: string) => {
            ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = color; ctx.fillRect(0, 0, 1, 1);
            const values = Array.from(ctx.getImageData(0, 0, 1, 1).data).slice(0, 3).map((c) => c / 255).map((c) => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
            return .2126 * values[0] + .7152 * values[1] + .0722 * values[2];
          };
          const contrast = Array.from(document.querySelectorAll<HTMLElement>(".page-title h1, .page-title p, .btn.primary, .market-price-row .price, .post-market-price, .post-body, .rail-item p, .post-context-copy p, .post-comment-main > p, .today-card h2, .today-card p, .today-card .btn, .today-label, .today-time, .today-side > span, .nav-item.active, .quick-copy b, .profile-rail-head p, .profile-rail-stats small, .post-interaction, .author-follow, .author-level, .market-page .filter-row select, .market-page .filter-row > label, .market-status, .market-meta time, .market-seller > span:last-child")).filter((el) => el.getClientRects().length && getComputedStyle(el).visibility !== "hidden").map((el) => {
            let surface: HTMLElement | null = el;
            while (surface && getComputedStyle(surface).backgroundColor === "rgba(0, 0, 0, 0)") surface = surface.parentElement;
            const ink = luminance(getComputedStyle(el).color), paper = luminance(getComputedStyle(surface || document.body).backgroundColor);
            return { selector: el.className || el.tagName, ratio: (Math.max(ink, paper) + .05) / (Math.min(ink, paper) + .05) };
          });
          const cards = Array.from(document.querySelectorAll(".market-card")).map((el) => ({ picture: el.querySelector(".market-img")!.getBoundingClientRect().bottom, title: el.querySelector("h3")!.getBoundingClientRect(), price: el.querySelector(".price")!.getBoundingClientRect().top }));
          for (const el of document.querySelectorAll<HTMLElement>(".filter-row input[placeholder]")) {
            const ink = luminance(getComputedStyle(el, "::placeholder").color), paper = luminance(getComputedStyle(el.closest("form")!).backgroundColor);
            contrast.push({ selector: "search placeholder", ratio: (Math.max(ink, paper) + .05) / (Math.min(ink, paper) + .05) });
          }
          const mediaOutside = Array.from(document.querySelectorAll(".community-feed .media-gallery-1 img, .post-detail-gallery.media-gallery-1 img")).some((img) => {
            const picture = img.getBoundingClientRect(), frame = img.parentElement!.getBoundingClientRect();
            return picture.left < frame.left - 1 || picture.right > frame.right + 1 || picture.top < frame.top - 1 || picture.bottom > frame.bottom + 1;
          });
          const containers = Array.from(document.querySelectorAll<HTMLElement>(".sidebar, .compact-quick .quick, .right-rail .rail-card, .market-card")).filter((el) => el.getClientRects().length && getComputedStyle(el).visibility !== "hidden");
          const unbounded = containers.filter((el) => {
            const style = getComputedStyle(el);
            return style.backgroundColor === "rgba(0, 0, 0, 0)" || style.borderTopStyle === "none" || parseFloat(style.borderTopWidth) < 1;
          }).map((el) => el.className);
          const nav = document.querySelector<HTMLElement>(".sidebar")!;
          const frame = nav.getBoundingClientRect();
          const navOutside = innerWidth > 760 && Array.from(nav.querySelectorAll(".nav-item")).some((el) => {
            const item = el.getBoundingClientRect();
            return item.left < frame.left || item.right > frame.right || item.width < 44 || item.height < 44;
          });
          const quickOutside = Array.from(document.querySelectorAll(".quick")).some((el) => {
            const button = el.getBoundingClientRect();
            return Array.from(el.querySelectorAll(".quick-copy b")).some((copy) => {
              const text = copy.getBoundingClientRect();
              return text.left < button.left || text.right > button.right || text.bottom > button.bottom;
            });
          });
          return { overflow: document.documentElement.scrollWidth > innerWidth, contrast, unbounded, navOutside, overlap: quickOutside || mediaOutside || cards.some((card) => card.picture > card.title.top || card.title.bottom > card.price) };
        });
        expect(result.overflow, `${theme} ${width} ${route}`).toBe(false);
        expect(result.overlap, `${theme} ${width} ${route}`).toBe(false);
        expect(result.unbounded, `${theme} ${width} ${route} visible widget containers`).toEqual([]);
        expect(result.navOutside, `${theme} ${width} ${route} navigation hit areas`).toBe(false);
        expect(result.contrast.filter((item) => item.ratio < 4.5), `${theme} ${width} ${route} contrast`).toEqual([]);
        if (route === "./" && width <= 760) {
          const schedule = await page.locator(".today-card").evaluate((el) => ({ text: el.querySelector(".today-copy")!.getBoundingClientRect().bottom, action: el.querySelector(".btn")!.getBoundingClientRect().top }));
          expect(schedule.action, `${theme} ${width} schedule action below complete status text`).toBeGreaterThanOrEqual(schedule.text);
        }
        if (width === 1280 && ["./", "market"].includes(route)) {
          const aboveFold = await page.locator(route === "market" ? ".market-page > .page-head, .market-page > .filter-row" : ".today-card").evaluateAll((elements) => elements.every((el) => el.getBoundingClientRect().bottom <= innerHeight));
          expect(aboveFold, `${theme} ${route} essential controls at 1280×800`).toBe(true);
        }
        if (width === 1440 || width === 375) await page.screenshot({ path: `artifacts/web-content-ui-2026-10-09/${theme}-${width}-${route === "./" ? "dashboard" : route.replace("/", "-")}.png` });
      }
      if (width === 1440 || width === 375) {
        const publish = page.getByRole("button", { name: "发布闲置", exact: true });
        await publish.click();
        const dialog = page.getByRole("dialog", { name: "发布闲置", exact: true });
        await expect(dialog).toBeVisible();
        await expect(dialog.getByRole("button", { name: "关闭", exact: true })).toBeFocused();
        await expect(dialog).toHaveCSS("opacity", "1");
        await expect(page.locator(".overlay")).toHaveCSS("opacity", "1");
        const presentation = await dialog.evaluate((el) => {
          const ctx = document.createElement("canvas").getContext("2d")!;
          const luminance = (color: string) => {
            ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = color; ctx.fillRect(0, 0, 1, 1);
            const [r, g, b] = Array.from(ctx.getImageData(0, 0, 1, 1).data).slice(0, 3).map((c) => c / 255).map((c) => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
            return .2126 * r + .7152 * g + .0722 * b;
          };
          return {
            overflow: document.documentElement.scrollWidth > innerWidth,
            controlContrast: Array.from(el.querySelectorAll<HTMLElement>("input, select, textarea, .btn.primary")).map((control) => {
              const style = getComputedStyle(control), ink = luminance(style.color), surface = luminance(style.backgroundColor);
              return (Math.max(ink, surface) + .05) / (Math.min(ink, surface) + .05);
            }),
            primaryBackground: getComputedStyle(el.querySelector(".btn.primary")!).backgroundImage,
          };
        });
        expect(presentation.overflow).toBe(false);
        expect(presentation.controlContrast.every((ratio) => ratio >= 4.5)).toBe(true);
        expect(presentation.primaryBackground).toBe("none");
        await dialog.getByLabel("物品名称", { exact: true }).focus();
        expect(await dialog.getByLabel("物品名称", { exact: true }).evaluate((el) => getComputedStyle(el).outlineWidth)).toBe("2px");
        await page.screenshot({ path: `artifacts/web-content-ui-2026-10-09/${theme}-${width}-publish-dialog.png` });
        await page.keyboard.press("Escape");
        await expect(dialog).toHaveCount(0);
        await expect(publish).toBeFocused();
      }
    }
  }
  await page.getByRole("button", { name: "发布闲置", exact: true }).focus();
  expect(await page.locator(".btn.primary").evaluate((el) => getComputedStyle(el).outlineWidth)).toBe("2px");
  expect(errors).toEqual([]);
});
