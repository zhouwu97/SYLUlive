import fs from "node:fs";
import zlib from "node:zlib";
import { test, expect, type Page } from "@playwright/test";

const SEA_ID = "11111111-2222-4333-8444-555555555555";
const SAKURA_ID = "22222222-3333-4444-8555-666666666666";

const ONE_PIXEL_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

const themeQaDir = process.env.THEME_UI_QA_DIR;

async function captureThemeUi(page: Page, name: string) {
  if (!themeQaDir) return;
  await page.locator(".theme-artwork img").evaluateAll((images) =>
    Promise.all(images.map((image) => (image as HTMLImageElement).decode())),
  );
  await page.screenshot({ path: `${themeQaDir}/${name}.png`, animations: "disabled" });
}

/** 在内存中拼出合法 ZIP（Deflate 方法 8），不向仓库提交任何二进制夹具。 */
function createZipBuffer(files: Record<string, Buffer>): Buffer {
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let offset = 0;
  const entries = Object.entries(files);

  for (const [name, raw] of entries) {
    const nameBuf = Buffer.from(name, "utf8");
    const compressed = zlib.deflateRawSync(raw);
    const crc = zlib.crc32(raw) >>> 0;

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(8, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(0, 12);
    localHeader.writeUInt32LE(crc, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(raw.length, 22);
    localHeader.writeUInt16LE(nameBuf.length, 26);
    localHeader.writeUInt16LE(0, 28);

    localParts.push(localHeader, nameBuf, compressed);

    const cdHeader = Buffer.alloc(46);
    cdHeader.writeUInt32LE(0x02014b50, 0);
    cdHeader.writeUInt16LE(20, 4);
    cdHeader.writeUInt16LE(20, 6);
    cdHeader.writeUInt16LE(0, 8);
    cdHeader.writeUInt16LE(8, 10);
    cdHeader.writeUInt16LE(0, 12);
    cdHeader.writeUInt16LE(0, 14);
    cdHeader.writeUInt32LE(crc, 16);
    cdHeader.writeUInt32LE(compressed.length, 20);
    cdHeader.writeUInt32LE(raw.length, 24);
    cdHeader.writeUInt16LE(nameBuf.length, 28);
    cdHeader.writeUInt16LE(0, 30);
    cdHeader.writeUInt16LE(0, 32);
    cdHeader.writeUInt16LE(0, 34);
    cdHeader.writeUInt16LE(0, 36);
    cdHeader.writeUInt32LE(0, 38);
    cdHeader.writeUInt32LE(offset, 42);

    centralParts.push(cdHeader, nameBuf);
    offset += localHeader.length + nameBuf.length + compressed.length;
  }

  const cdBuf = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...localParts, cdBuf, eocd]);
}

// 复用仓库既有跟踪字体字节，避免提交新二进制夹具且保证真实浏览器 FontFace 解析通过
const MINIMAL_TTF = fs.readFileSync(
  new URL("../src/assets/fonts/noto-color-emoji-v2.051.woff2", import.meta.url),
);

function buildThemeZip(opts: {
  id: string;
  name: string;
  lightCard: string;
  lightBg: string;
  lightText: string;
  lightNavBg: string;
  lightNavSelected: string;
  lightNavUnselected: string;
  withFont?: boolean;
  fontBytesOverride?: Buffer;
}) {
  const manifest = {
    formatVersion: 1,
    minAppVersion: "1.0.0",
    id: opts.id,
    version: 1,
    name: opts.name,
    description: `${opts.name} 移动网页联调包`,
    author: "海盐作者",
    tags: ["清新", "浅色"],
    license: "CC-BY-4.0",
    preview: { light: "preview/light.png", dark: "preview/dark.png" },
    ...(opts.withFont
      ? {
          font: {
            name: "测试正文字体",
            regular: "fonts/regular.ttf",
            license: "OFL-1.1",
          },
        }
      : {}),
    light: {
      seedColor: "#2F7FD8",
      schemeVariant: "tonalSpot",
      tokens: {
        primary: "#3C6090",
        onPrimary: "#FFFFFF",
        primaryContainer: "#D5E3FF",
        onPrimaryContainer: "#001C3B",
        background: opts.lightBg,
        surface: opts.lightCard,
        surfaceElevated: opts.lightCard,
        surfaceMuted: "#EEF3FA",
        card: opts.lightCard,
        cardBorder: "#D0DBE8",
        textPrimary: opts.lightText,
        textSecondary: "#43474E",
        textTertiary: "#6E757E",
        textDisabled: "#9CA3AF",
        divider: "#DCE4EE",
        outline: "#C5D2E0",
        inputFill: "#EEF3FA",
        inputFillFocused: "#E5EEF9",
        searchFill: "#EDF2F8",
        tagBackground: "#E1ECFA",
        tagText: "#1E4E8C",
        navBackground: opts.lightNavBg,
        navSelected: opts.lightNavSelected,
        navUnselected: opts.lightNavUnselected,
        appBarBackground: opts.lightBg,
        appBarForeground: opts.lightText,
        bubbleIncoming: "#EEF3FA",
        bubbleIncomingText: opts.lightText,
        bubbleOutgoing: "#76C4FF",
        bubbleOutgoingText: opts.lightText,
        feedSectionSurface: "#E1ECFA",
        feedFeaturedSurface: "#FFF3E0",
        feedFeaturedText: "#D97706",
        courseCardText: opts.lightText,
        timetableGrid: "#0D000000",
        timetableToday: "#00000000",
      },
      coursePalette: ["#2F7FD8", "#1E9BB8", "#1AA69C", "#2E8BC0", "#3B6FD8"],
      wallpapers: {
        schedule: { portrait: "wallpapers/schedule.png", fit: "contain" },
        global: {
          portrait: "wallpapers/sea.png",
          fit: "cover",
          focalX: 0.5,
          focalY: 0.5,
          blur: 2,
          scrim: 0.12,
          adjustments: {
            brightness: 12,
            contrast: 110,
            saturation: 108,
          },
        },
      },
    },
    dark: {
      seedColor: "#2F7FD8",
      schemeVariant: "tonalSpot",
      tokens: {
        primary: "#A6C8FF",
        onPrimary: "#00315F",
        primaryContainer: "#224876",
        onPrimaryContainer: "#D5E3FF",
        background: "#111318",
        surface: "#191C22",
        surfaceElevated: "#22262E",
        surfaceMuted: "#252A33",
        card: "#191C22",
        cardBorder: "#323844",
        textPrimary: "#E2E6EE",
        textSecondary: "#B4BCC8",
        textTertiary: "#8B93A1",
        textDisabled: "#5A6270",
        divider: "#282E38",
        outline: "#38404E",
        inputFill: "#252A33",
        inputFillFocused: "#2C323D",
        searchFill: "#252A33",
        tagBackground: "#263244",
        tagText: "#A6C8FF",
        navBackground: "#CC1D222B",
        navSelected: "#A6C8FF",
        navUnselected: "#C4CBD6",
        appBarBackground: "#111318",
        appBarForeground: "#E2E6EE",
        bubbleIncoming: "#252A33",
        bubbleIncomingText: "#E2E6EE",
        bubbleOutgoing: "#80C4FC",
        bubbleOutgoingText: "#111318",
        feedSectionSurface: "#22344D",
        feedFeaturedSurface: "#3A2A18",
        feedFeaturedText: "#F2B15A",
        courseCardText: "#FFFFFF",
        timetableGrid: "#33FFFFFF",
        timetableToday: "#00000000",
      },
      coursePalette: ["#1D5696", "#15687D", "#146E66", "#1E5E85", "#284B94"],
    },
  };

  return createZipBuffer({
    "manifest.json": Buffer.from(JSON.stringify(manifest), "utf8"),
    "preview/light.png": ONE_PIXEL_PNG,
    "preview/dark.png": ONE_PIXEL_PNG,
    "wallpapers/sea.png": ONE_PIXEL_PNG,
    "wallpapers/schedule.png": ONE_PIXEL_PNG,
    ...(opts.withFont ? { "fonts/regular.ttf": opts.fontBytesOverride || MINIMAL_TTF } : {}),
  });
}

const CORRUPT_FONT_SEA_ZIP = buildThemeZip({
  id: SEA_ID,
  name: "海盐蓝",
  lightBg: "#F5F9FF",
  lightCard: "#FAFCFF",
  lightText: "#191C20",
  lightNavBg: "#D9E1ECFA",
  lightNavSelected: "#3C6090",
  lightNavUnselected: "#4A586B",
  withFont: true,
  fontBytesOverride: Buffer.from("not-a-valid-font-binary"),
});

const SEA_ZIP = buildThemeZip({
  id: SEA_ID,
  name: "海盐蓝",
  lightBg: "#F5F9FF",
  lightCard: "#FAFCFF",
  lightText: "#191C20",
  lightNavBg: "#D9E1ECFA", // ARGB -> rgba(225, 236, 250, 0.851)
  lightNavSelected: "#3C6090",
  lightNavUnselected: "#4A586B",
  withFont: true,
});

const SAKURA_ZIP = buildThemeZip({
  id: SAKURA_ID,
  name: "樱粉",
  lightBg: "#FFF7F8",
  lightCard: "#FFF0F3",
  lightText: "#24181B",
  lightNavBg: "#D9FCE7EC",
  lightNavSelected: "#9E3B5A",
  lightNavUnselected: "#684A53",
  withFont: false,
});

async function setupThemeApi(page: Page) {
  const state = {
    failPackage: false,
    corruptSeaFont: false,
    paginatedCatalog: false,
    holdSeaPackage: null as Promise<void> | null,
    holdPopularCatalog: null as Promise<void> | null,
    holdSakuraDetail: null as Promise<void> | null,
    seaPackageHits: 0,
    abortedCatalogUrls: [] as string[],
    errors: [] as string[],
  };
  page.on("pageerror", (err) => state.errors.push(err.message));
  page.on("requestfailed", (req) => {
    if (req.url().includes("/api/themes")) {
      state.abortedCatalogUrls.push(req.url());
    }
  });

  const seaItem = {
    familyId: SEA_ID,
    version: 1,
    name: "海盐蓝",
    description: "清爽海盐蓝白移动主题",
    license: "CC-BY-4.0",
    author: { id: 8, nickname: "海盐作者", avatarUrl: "" },
    tags: ["清新", "浅色"],
    source: "official",
    previewLight: `/api/themes/${SEA_ID}/versions/1/preview/light`,
    previewDark: `/api/themes/${SEA_ID}/versions/1/preview/dark`,
    packageUrl: `/api/themes/${SEA_ID}/versions/1/package`,
    packageSize: SEA_ZIP.length,
    packageSha256: "",
    minAppVersion: "1.0.0",
    downloads: 42,
    updatedAt: "2026-11-18T00:00:00Z",
  };

  const sakuraItem = {
    ...seaItem,
    familyId: SAKURA_ID,
    name: "樱粉",
    description: "柔和樱粉移动主题",
    previewLight: `/api/themes/${SAKURA_ID}/versions/1/preview/light`,
    previewDark: `/api/themes/${SAKURA_ID}/versions/1/preview/dark`,
    packageUrl: `/api/themes/${SAKURA_ID}/versions/1/package`,
    packageSize: SAKURA_ZIP.length,
  };

  const post = {
    id: 202,
    board_id: 1,
    author_id: 8,
    author: { id: 8, nickname: "校园测试同学" },
    title: "图书馆自习日常",
    content: "今天下午阳光很好。",
    created_at: "2026-11-18T08:00:00+08:00",
    like_count: 5,
    reply_count: 1,
  };

  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/user/profile") {
      return route.fulfill({
        json: {
          id: 7,
          role: "user",
          nickname: "界面测试同学",
          level: 6,
          credit_score: 100,
          following_count: 2,
          followers_count: 10,
        },
      });
    }
    if (url.pathname === "/api/posts" || url.pathname === "/api/posts/featured") {
      return route.fulfill({
        json: {
          pinned_posts: [],
          posts: [post],
          has_more: false,
          session_id: "theme-e2e",
          next_offset: 1,
        },
      });
    }
    if (url.pathname === "/api/themes") {
      const sort = url.searchParams.get("sort") || "latest";
      const cursor = url.searchParams.get("cursor") || "";
      if (sort === "popular" && state.holdPopularCatalog) {
        await state.holdPopularCatalog;
        return route.fulfill({ json: { items: [sakuraItem] } });
      }
      if (state.paginatedCatalog && sort === "latest") {
        if (!cursor) {
          return route.fulfill({ json: { items: [seaItem], nextCursor: "cursor-page-2" } });
        }
        if (cursor === "cursor-page-2") {
          return route.fulfill({ json: { items: [sakuraItem] } });
        }
      }
      if (sort === "official") {
        return route.fulfill({ json: { items: [seaItem] } });
      }
      return route.fulfill({ json: { items: [seaItem, sakuraItem] } });
    }
    if (url.pathname === `/api/themes/${SEA_ID}`) {
      return route.fulfill({ json: seaItem });
    }
    if (url.pathname === `/api/themes/${SAKURA_ID}`) {
      if (state.holdSakuraDetail) {
        await state.holdSakuraDetail;
      }
      return route.fulfill({ json: sakuraItem });
    }
    if (url.pathname.endsWith("/preview/light") || url.pathname.endsWith("/preview/dark")) {
      const mode = url.pathname.endsWith("/light") ? "light" : "dark";
      const preview = new URL(`../../client/build/theme-p1-qa/preview-${mode}.png`, import.meta.url);
      return route.fulfill({
        status: 200,
        contentType: "image/png",
        body: themeQaDir && fs.existsSync(preview) ? fs.readFileSync(preview) : ONE_PIXEL_PNG,
      });
    }
    if (url.pathname === `/api/themes/${SEA_ID}/versions/1/package`) {
      state.seaPackageHits += 1;
      if (state.failPackage) {
        return route.abort("internetdisconnected");
      }
      if (state.holdSeaPackage) {
        await state.holdSeaPackage;
      }
      return route.fulfill({
        status: 200,
        contentType: "application/vnd.sylulive.theme+zip",
        headers: { "Cache-Control": "public, no-cache" },
        body: state.corruptSeaFont ? CORRUPT_FONT_SEA_ZIP : SEA_ZIP,
      });
    }
    if (url.pathname === `/api/themes/${SAKURA_ID}/versions/1/package`) {
      if (state.failPackage) {
        return route.abort("internetdisconnected");
      }
      return route.fulfill({
        status: 200,
        contentType: "application/vnd.sylulive.theme+zip",
        headers: { "Cache-Control": "no-store" },
        body: SAKURA_ZIP,
      });
    }
    return route.fulfill({ json: { items: [], count: 0 } });
  });

  return state;
}

test("移动网页主题：应用海盐蓝、首帧无闪烁恢复、离线保配色与重试、恢复默认及 1280 桌面零影响", async ({ page }) => {
  const state = await setupThemeApi(page);

  // 注入首帧绘制前探针与 objectURL 追踪
  await page.addInitScript(() => {
    const win = window as unknown as Record<string, any>;
    win.__createdUrls = [] as string[];
    win.__revokedUrls = [] as string[];
    const origCreate = URL.createObjectURL.bind(URL);
    const origRevoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (obj: Blob | MediaSource) => {
      const u = origCreate(obj);
      win.__createdUrls.push(u);
      return u;
    };
    URL.revokeObjectURL = (u: string) => {
      win.__revokedUrls.push(u);
      return origRevoke(u);
    };

    // 在首个 requestAnimationFrame 之前读取根元素同步写入的 Token
    win.__beforeFirstPaint = null;
    const captureEarly = () => {
      if (win.__beforeFirstPaint) return;
      const d = document.documentElement;
      win.__beforeFirstPaint = {
        mobileTheme: d.dataset.mobileTheme || "",
        cardVar: d.style.getPropertyValue("--theme-card").trim(),
        bgVar: d.style.getPropertyValue("--theme-background").trim(),
      };
    };
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", captureEarly, { once: true });
    } else {
      captureEarly();
    }
  });

  // 先在 1280 宽桌面视口记录原始颜色基线
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("./");
  await expect(page.getByText("界面测试同学").first()).toBeVisible();
  await expect(page.locator(".feed-card").first()).toBeVisible();
  const desktopBaseline = {
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    bodyFont: await page.locator("body").evaluate((el) => getComputedStyle(el).fontFamily),
    shellBg: await page.locator(".social-shell").evaluate((el) => getComputedStyle(el).backgroundColor),
    cardBg: await page.locator(".feed-card").first().evaluate((el) => getComputedStyle(el).backgroundColor),
  };

  // 切换到 390×844 手机视口。
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  const dock = page.getByRole("navigation", { name: "底部导航" });
  await expect(dock.getByRole("link", { name: "首页", exact: true })).toHaveAttribute("aria-current", "page");
  await expect(page.locator(".mobile-app-feed .feed-card").first()).toBeVisible();

  // 从“我 → 外观与主题”进入商城，打开 /theme/<familyId> 验证双操作按钮
  await dock.getByRole("link", { name: "我", exact: true }).click();
  await page.getByRole("link", { name: /外观与主题/ }).click();
  await expect(page.getByText("海盐蓝")).toBeVisible();

  await page.goto(`/theme/${SEA_ID}`);
  await expect(page).toHaveURL(new RegExp(`/web/theme/${SEA_ID}$`));
  const openInAppLink = page.getByRole("link", { name: "在 App 中打开", exact: true });
  await expect(openInAppLink).toHaveAttribute("href", `sylulive://theme/${SEA_ID}`);

  // 点击“在网页上应用”
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.getByRole("button", { name: "已在网页上应用", exact: true })).toBeVisible();

  // 回到首页核对卡片、正文、底栏计算颜色、壁纸 CSS filter 与自定义字体
  await page.goto("./");
  await dock.getByRole("link", { name: "首页", exact: true }).click();
  await expect(page.locator(".mobile-app-feed .feed-card").first()).toBeVisible();
  await expect(page.getByTestId("mobile-theme-wallpaper")).toBeVisible();

  const appliedSeaStyles = {
    cardBg: await page.locator(".mobile-app-feed .feed-card").first().evaluate((el) => getComputedStyle(el).backgroundColor),
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    bodyFont: await page.locator("body").evaluate((el) => getComputedStyle(el).fontFamily),
    navBg: await page.locator(".mobile-bottom-nav").evaluate((el) => getComputedStyle(el).backgroundColor),
    navActiveColor: await dock.getByRole("link", { name: "首页", exact: true }).evaluate((el) => getComputedStyle(el).color),
    navIdleColor: await dock.getByRole("link", { name: "集市", exact: true }).evaluate((el) => getComputedStyle(el).color),
    wallSrc: await page.locator(".mobile-theme-wallpaper img").evaluate((el) => (el as HTMLImageElement).src),
    wallFilter: await page.locator(".mobile-theme-wallpaper img").evaluate((el) => getComputedStyle(el).filter),
  };

  expect(appliedSeaStyles.cardBg).toBe("rgb(250, 252, 255)"); // #FAFCFF
  expect(appliedSeaStyles.bodyColor).toBe("rgb(25, 28, 32)"); // #191C20
  expect(appliedSeaStyles.navBg).toMatch(/^rgba\(225, 236, 250, 0\.85/); // #D9E1ECFA -> #E1ECFAD9
  expect(appliedSeaStyles.navActiveColor).toBe("rgb(60, 96, 144)"); // #3C6090
  expect(appliedSeaStyles.navIdleColor).toBe("rgb(74, 88, 107)"); // #4A586B
  expect(appliedSeaStyles.wallSrc).toMatch(/^blob:/);
  expect(appliedSeaStyles.wallFilter).toContain("brightness(1.12)");
  expect(appliedSeaStyles.wallFilter).toContain("contrast(1.1)");
  expect(appliedSeaStyles.wallFilter).toContain("saturate(1.08)");
  expect(appliedSeaStyles.wallFilter).toContain("blur(2px)");
  expect(appliedSeaStyles.bodyFont).toContain("sylulive_web_theme_");

  // 走站内导航，两个页面共用全局壁纸时应复用已解码的图片。
  await dock.getByRole("link", { name: "集市", exact: true }).click();
  await expect(dock.getByRole("link", { name: "集市", exact: true })).toHaveAttribute("aria-current", "page");
  const wallpaper = page.locator(".mobile-theme-wallpaper img");
  await expect(wallpaper).toHaveAttribute("src", appliedSeaStyles.wallSrc);
  await dock.getByRole("link", { name: "课表", exact: true }).click();
  await expect(wallpaper).not.toHaveAttribute("src", appliedSeaStyles.wallSrc);
  await expect(wallpaper).toHaveCSS("object-fit", "contain");
  const scheduleWallSrc = await wallpaper.getAttribute("src");
  await dock.getByRole("link", { name: "首页", exact: true }).click();
  await expect(wallpaper).toHaveAttribute("src", appliedSeaStyles.wallSrc);
  await dock.getByRole("link", { name: "课表", exact: true }).click();
  await expect(wallpaper).toHaveAttribute("src", scheduleWallSrc!);
  await dock.getByRole("link", { name: "首页", exact: true }).click();

  await page.getByRole("button", { name: "打开导航", exact: true }).click();
  const colorMode = page.getByRole("complementary", { name: "主导航" })
    .getByRole("button", { name: "切换主题", exact: true });
  await colorMode.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await colorMode.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  const drawerBackdrop = page.getByRole("button", { name: "收起导航", exact: true });
  await drawerBackdrop.click({ position: { x: 380, y: 100 } });
  await expect(drawerBackdrop).toBeHidden();

  // 刷新后验证首帧之前已同步恢复主题配色，随后壁纸出现
  await page.reload();
  const earlyPaint = await page.evaluate(
    () => (window as unknown as Record<string, any>).__beforeFirstPaint,
  );
  expect(earlyPaint).toEqual({
    mobileTheme: "1",
    cardVar: "#FAFCFF",
    bgVar: "#F5F9FF",
  });
  await expect(page.getByTestId("mobile-theme-wallpaper")).toBeVisible();

  // 断网（包获取失败且无缓存）后刷新：配色仍生效，壁纸隐藏，联网后可重试恢复壁纸
  state.failPackage = true;
  await page.reload();
  await expect(page.locator(".mobile-app-feed .feed-card").first()).toBeVisible();
  await expect(page.getByTestId("mobile-theme-wallpaper")).toHaveCount(0);
  const offlineCardBg = await page
    .locator(".mobile-app-feed .feed-card")
    .first()
    .evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(offlineCardBg).toBe("rgb(250, 252, 255)");

  await page.goto("themes");
  await expect(page.getByRole("button", { name: "重试资源", exact: true })).toBeVisible();
  state.failPackage = false;
  await page.getByRole("button", { name: "重试资源", exact: true }).click();
  await expect(page.getByTestId("mobile-theme-wallpaper")).toBeVisible();

  // 1280 宽桌面视口下颜色与字体完全不变，移动壁纸不显示
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("./");
  await expect(page.getByText("界面测试同学").first()).toBeVisible();
  await expect(page.locator(".feed-card").first()).toBeVisible();
  await expect(page.getByTestId("mobile-theme-wallpaper")).toHaveCount(0);
  const desktopAfterApply = {
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    bodyFont: await page.locator("body").evaluate((el) => getComputedStyle(el).fontFamily),
    shellBg: await page.locator(".social-shell").evaluate((el) => getComputedStyle(el).backgroundColor),
    cardBg: await page.locator(".feed-card").first().evaluate((el) => getComputedStyle(el).backgroundColor),
  };
  expect(desktopAfterApply).toEqual(desktopBaseline);

  // 切回手机视口，换一套主题后恢复首次应用的海盐蓝。
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`theme/${SAKURA_ID}`);
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.getByRole("button", { name: "已在网页上应用", exact: true })).toBeVisible();
  await page.reload();
  await expect(page.locator("html")).toHaveCSS("--theme-card", "#FFF0F3");
  const sakuraUrl = await wallpaper.getAttribute("src");

  // 下载失败期间继续使用当前主题，恢复入口可重试。
  const restore = page.getByRole("button", { name: "恢复默认", exact: true });
  state.failPackage = true;
  await restore.click();
  await expect(page.getByText(/初始主题资源未加载/)).toBeVisible();
  await expect(wallpaper).toHaveAttribute("src", sakuraUrl!);

  state.failPackage = false;
  await page.getByRole("button", { name: "重试资源", exact: true }).click();
  await expect(page.locator("html")).toHaveCSS("--theme-card", "#FAFCFF");
  await expect.poll(() => page.evaluate(() => {
    const image = document.querySelector<HTMLImageElement>(".mobile-theme-wallpaper img");
    return !!image?.complete && image.naturalWidth > 0;
  })).toBe(true);
  const revoked = await page.evaluate(
    () => (window as unknown as Record<string, any>).__revokedUrls as string[],
  );
  expect(revoked).toContain(sakuraUrl);
  await captureThemeUi(page, "restored-initial-theme");

  await page.reload();
  await expect(page.locator("html")).toHaveCSS("--theme-card", "#FAFCFF");
  await expect(page.getByTestId("mobile-theme-wallpaper")).toBeVisible();

  // localStorage 写入抛错时：当前会话仍生效并展示存储受限提示
  await page.goto(`theme/${SAKURA_ID}`);
  await page.evaluate(() => {
    Storage.prototype.setItem = () => {
      throw new DOMException("QuotaExceededError", "QuotaExceededError");
    };
  });
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("浏览器本地存储不可用或空间已满");

  expect(state.errors).toEqual([]);
});

test("移动网页主题：目录分页与筛选取消旧请求、详情按 ID 绑定、坏字体重试恢复及落地页桌面隔离", async ({ page }) => {
  const state = await setupThemeApi(page);
  state.paginatedCatalog = true;

  // 1. 记录 1280×800 桌面视口下 /web/theme/:id 落地页的默认颜色基线
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto(`theme/${SEA_ID}`);
  await expect(page.getByRole("heading", { name: "海盐蓝", exact: true })).toBeVisible();
  const landingDesktopBaseline = {
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    panelBg: await page.locator(".theme-landing-page .panel").evaluate((el) => getComputedStyle(el).backgroundColor),
    tagBg: await page.locator(".theme-landing-tags span").first().evaluate((el) => getComputedStyle(el).backgroundColor),
    tagColor: await page.locator(".theme-landing-tags span").first().evaluate((el) => getComputedStyle(el).color),
  };

  // 2. 目录分页加载更多，以及切换筛选时取消挂起的旧请求
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("themes");
  await expect(page.getByText("海盐蓝")).toBeVisible();
  await expect(page.getByText("樱粉")).toHaveCount(0);
  await page.getByRole("button", { name: "加载更多", exact: true }).click();
  await expect(page.getByText("樱粉")).toBeVisible();
  await expect(page.getByRole("button", { name: "加载更多", exact: true })).toHaveCount(0);
  await captureThemeUi(page, "web-mobile-store");

  let releasePopularCatalog!: () => void;
  state.holdPopularCatalog = new Promise<void>((r) => {
    releasePopularCatalog = r;
  });
  await page.getByRole("tab", { name: "热门", exact: true }).click();
  await expect(page.getByText("正在加载主题列表…")).toBeVisible();
  // 立即切回“最新”，旧“热门”请求应被取消且不能覆盖“最新”首页结果
  await page.getByRole("tab", { name: "最新", exact: true }).click();
  await expect(page.getByText("海盐蓝")).toBeVisible();
  state.holdPopularCatalog = null;
  releasePopularCatalog();
  await page.waitForTimeout(60);
  await expect(page.getByText("海盐蓝")).toBeVisible();
  await expect(page.getByText("樱粉")).toHaveCount(0);
  expect(state.abortedCatalogUrls.some((u) => u.includes("sort=popular"))).toBe(true);

  // 3. 详情页按 ID 绑定：在同组件内从海盐蓝导航到慢响应的樱粉，不闪现旧详情
  state.paginatedCatalog = false;
  await page.goto(`theme/${SEA_ID}`);
  await expect(page.getByRole("heading", { name: "海盐蓝", exact: true })).toBeVisible();
  let releaseSakuraDetail!: () => void;
  state.holdSakuraDetail = new Promise<void>((r) => {
    releaseSakuraDetail = r;
  });
  await page.evaluate((nextId) => {
    window.history.pushState({ idx: 2 }, "", `/web/theme/${nextId}`);
    window.dispatchEvent(new PopStateEvent("popstate", { state: { idx: 2 } }));
  }, SAKURA_ID);
  await expect(page.getByText("正在加载主题详情…")).toBeVisible();
  await expect(page.getByRole("heading", { name: "海盐蓝", exact: true })).toHaveCount(0);
  state.holdSakuraDetail = null;
  releaseSakuraDetail();
  await expect(page.getByRole("heading", { name: "樱粉", exact: true })).toBeVisible();

  // 4. 落地页主题变量仅在 ≤600px 生效：手机端应用海盐蓝后，390px 落地页标签变色，1280px 落地页完全不变
  await page.goto(`theme/${SEA_ID}`);
  await expect(page.getByRole("heading", { name: "海盐蓝", exact: true })).toBeVisible();
  await captureThemeUi(page, "web-mobile-detail");

  let releaseSeaPackage!: () => void;
  state.holdSeaPackage = new Promise<void>((resolve) => { releaseSeaPackage = resolve; });
  const seaRequest = page.waitForRequest((request) => request.url().includes(`${SEA_ID}/versions/1/package`));
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await seaRequest;
  await page.locator(".theme-back-link").click();
  await page.locator(".mobile-theme-card").filter({ hasText: "樱粉" }).click();
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.locator("html")).toHaveCSS("--theme-card", "#FFF0F3");
  state.holdSeaPackage = null;
  releaseSeaPackage();
  await expect.poll(() => state.abortedCatalogUrls.some((url) => url.includes(`${SEA_ID}/versions/1/package`))).toBe(true);
  await expect(page.locator("html")).toHaveCSS("--theme-card", "#FFF0F3");

  await page.locator(".theme-back-link").click();
  await page.locator(".mobile-theme-card").filter({ hasText: "海盐蓝" }).click();
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.getByRole("button", { name: "已在网页上应用", exact: true })).toBeVisible();
  const mobileTagStyles = {
    tagBg: await page.locator(".theme-landing-tags span").first().evaluate((el) => getComputedStyle(el).backgroundColor),
    tagColor: await page.locator(".theme-landing-tags span").first().evaluate((el) => getComputedStyle(el).color),
  };
  expect(mobileTagStyles.tagBg).toBe("rgb(225, 236, 250)"); // #E1ECFA
  expect(mobileTagStyles.tagColor).toBe("rgb(30, 78, 140)"); // #1E4E8C

  await page.setViewportSize({ width: 1280, height: 800 });
  const landingDesktopAfter = {
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    panelBg: await page.locator(".theme-landing-page .panel").evaluate((el) => getComputedStyle(el).backgroundColor),
    tagBg: await page.locator(".theme-landing-tags span").first().evaluate((el) => getComputedStyle(el).backgroundColor),
    tagColor: await page.locator(".theme-landing-tags span").first().evaluate((el) => getComputedStyle(el).color),
  };
  expect(landingDesktopAfter).toEqual(landingDesktopBaseline);
  await expect(page.getByRole("link", { name: "在 App 中打开" })).toBeVisible();
  await expect(page.getByRole("button", { name: /在网页上应用/ })).toHaveCount(0);
  await captureThemeUi(page, "web-desktop-detail");
  await page.getByRole("button", { name: "外观设置", exact: true }).click();
  await page.getByRole("dialog", { name: "外观设置" })
    .getByRole("link", { name: "主题商城" }).click();
  await expect(page.getByRole("heading", { name: "主题商城" })).toBeVisible();
  const covers = page.locator(".mobile-theme-card");
  await expect(covers).toHaveCount(2);
  expect((await covers.nth(0).boundingBox())?.y).toBe((await covers.nth(1).boundingBox())?.y);
  await captureThemeUi(page, "web-desktop-store");
  if (themeQaDir) {
    const colorMode = page.getByRole("button", { name: "切换主题", exact: true });
    await colorMode.click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    await captureThemeUi(page, "web-desktop-store-dark");
    await colorMode.click();
  }
  const searchRequest = page.waitForRequest((request) => {
    const query = new URL(request.url());
    return query.pathname === "/api/themes" && query.searchParams.get("q") === "海盐";
  });
  await page.getByRole("textbox", { name: "搜索主题" }).fill("海盐");
  await page.getByRole("button", { name: "搜索", exact: true }).click();
  await searchRequest;

  // 5. 字体重试的缓存与错误处理：刷新遇到损坏字体时不产生未捕获异常、保留配色、不注入坏字体；修复后重试重新拉包恢复字体与壁纸
  await page.setViewportSize({ width: 390, height: 844 });
  state.corruptSeaFont = true;
  await page.goto("themes");
  await page.reload();
  await expect(page.getByRole("button", { name: "重试资源", exact: true })).toBeVisible();
  const fontDuringError = await page.locator("body").evaluate((el) => getComputedStyle(el).fontFamily);
  expect(fontDuringError).not.toContain("sylulive_web_theme_");

  // 再次点击重试仍处于损坏状态时安全捕获错误，无未处理 Promise 拒绝
  const hitsBeforeBadRetry = state.seaPackageHits;
  await page.getByRole("button", { name: "重试资源", exact: true }).click();
  await expect.poll(() => state.seaPackageHits).toBeGreaterThan(hitsBeforeBadRetry);
  await expect(page.getByRole("button", { name: "重试资源", exact: true })).toBeVisible();

  // 恢复合法字体包后点击重试：清掉坏缓存重新获取并完成注册
  state.corruptSeaFont = false;
  const hitsBeforeGoodRetry = state.seaPackageHits;
  await page.getByRole("button", { name: "重试资源", exact: true }).click();
  await expect.poll(() => state.seaPackageHits).toBeGreaterThan(hitsBeforeGoodRetry);
  await expect(page.getByTestId("mobile-theme-wallpaper")).toBeVisible();
  const fontAfterRetry = await page.locator("body").evaluate((el) => getComputedStyle(el).fontFamily);
  expect(fontAfterRetry).toContain("sylulive_web_theme_");

  expect(state.errors).toEqual([]);
});
