import fs from "node:fs";
import zlib from "node:zlib";
import { test, expect, type Page } from "@playwright/test";

const SEA_ID = "11111111-2222-4333-8444-555555555555";
const SAKURA_ID = "22222222-3333-4444-8555-666666666666";

const ONE_PIXEL_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

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
    ...(opts.withFont ? { "fonts/regular.ttf": MINIMAL_TTF } : {}),
  });
}

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
    holdSeaPackage: null as (() => void) | null,
    errors: [] as string[],
  };
  page.on("pageerror", (err) => state.errors.push(err.message));

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
      return route.fulfill({ json: { items: [seaItem, sakuraItem] } });
    }
    if (url.pathname === `/api/themes/${SEA_ID}`) {
      return route.fulfill({ json: seaItem });
    }
    if (url.pathname === `/api/themes/${SAKURA_ID}`) {
      return route.fulfill({ json: sakuraItem });
    }
    if (url.pathname.endsWith("/preview/light") || url.pathname.endsWith("/preview/dark")) {
      return route.fulfill({
        status: 200,
        contentType: "image/png",
        body: ONE_PIXEL_PNG,
      });
    }
    if (url.pathname === `/api/themes/${SEA_ID}/versions/1/package`) {
      if (state.failPackage) {
        return route.abort("internetdisconnected");
      }
      if (state.holdSeaPackage) {
        await new Promise<void>((resolve) => {
          state.holdSeaPackage = resolve;
        });
        state.holdSeaPackage = null;
      }
      return route.fulfill({
        status: 200,
        contentType: "application/vnd.sylulive.theme+zip",
        headers: { "Cache-Control": "no-store" },
        body: SEA_ZIP,
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

  // 切换到 390×844 手机视口并记录应用前默认颜色
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  const dock = page.getByRole("navigation", { name: "底部导航" });
  await dock.getByRole("link", { name: "首页", exact: true }).click();
  await expect(dock.getByRole("link", { name: "首页", exact: true })).toHaveAttribute("aria-current", "page");
  await expect(page.locator(".mobile-app-feed .feed-card").first()).toBeVisible();
  const mobileDefaultColors = {
    cardBg: await page.locator(".mobile-app-feed .feed-card").first().evaluate((el) => getComputedStyle(el).backgroundColor),
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    navBg: await page.locator(".mobile-bottom-nav").evaluate((el) => getComputedStyle(el).backgroundColor),
    navActiveColor: await dock.getByRole("link", { name: "首页", exact: true }).evaluate((el) => getComputedStyle(el).color),
  };

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

  // 切回 390×844：验证释放旧 object URL 与恢复默认回到原值
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`theme/${SEA_ID}`);
  await page.getByRole("button", { name: "恢复默认", exact: true }).click();
  const revokedAfterReset = await page.evaluate(
    () => ((window as unknown as Record<string, any>).__revokedUrls as string[]).length,
  );
  expect(revokedAfterReset).toBeGreaterThan(0);

  await page.goto("./");
  await dock.getByRole("link", { name: "首页", exact: true }).click();
  await expect(page.locator(".mobile-app-feed .feed-card").first()).toBeVisible();
  const restoredColors = {
    cardBg: await page.locator(".mobile-app-feed .feed-card").first().evaluate((el) => getComputedStyle(el).backgroundColor),
    bodyColor: await page.locator("body").evaluate((el) => getComputedStyle(el).color),
    navBg: await page.locator(".mobile-bottom-nav").evaluate((el) => getComputedStyle(el).backgroundColor),
    navActiveColor: await dock.getByRole("link", { name: "首页", exact: true }).evaluate((el) => getComputedStyle(el).color),
  };
  expect(restoredColors).toEqual(mobileDefaultColors);

  // 竞态验证：先点海盐蓝（挂起包下载），立即切换到樱粉并应用，随后放行海盐蓝旧响应 -> 樱粉保持生效不被覆盖
  state.holdSeaPackage = () => {};
  await page.goto(`theme/${SEA_ID}`);
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await page.goto(`theme/${SAKURA_ID}`);
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.getByRole("button", { name: "已在网页上应用", exact: true })).toBeVisible();
  if (state.holdSeaPackage) (state.holdSeaPackage as () => void)();
  await page.waitForTimeout(80);

  await page.goto("./");
  const sakuraCardBg = await page
    .locator(".mobile-app-feed .feed-card")
    .first()
    .evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(sakuraCardBg).toBe("rgb(255, 240, 243)"); // 樱粉 #FFF0F3，未被迟到的海盐蓝覆盖

  // localStorage 写入抛错时：当前会话仍生效并展示存储受限提示
  await page.goto(`theme/${SEA_ID}`);
  await page.evaluate(() => {
    Storage.prototype.setItem = () => {
      throw new DOMException("QuotaExceededError", "QuotaExceededError");
    };
  });
  await page.getByRole("button", { name: "在网页上应用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("浏览器本地存储不可用或空间已满");

  expect(state.errors).toEqual([]);
});
