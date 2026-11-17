import { useEffect, useSyncExternalStore } from "react";

export const MOBILE_THEME_STORAGE_KEY = "sylulive-theme-pack-v1";
const MAX_UNCOMPRESSED_BYTES = 96 * 1024 * 1024;

export interface WallpaperAdjustments {
  brightness?: number;
  contrast?: number;
  saturation?: number;
}

export interface WallpaperSlotConfig {
  portrait: string;
  landscape?: string;
  fit?: "cover" | "contain";
  focalX?: number;
  focalY?: number;
  blur?: number;
  scrim?: number;
  adjustments?: WallpaperAdjustments;
}

export interface SavedVariantMeta {
  tokens: Record<string, string>;
  wallpapers?: Partial<Record<"global" | "home" | "schedule" | "me", WallpaperSlotConfig>>;
}

export interface SavedFontMeta {
  name: string;
  regular: string;
  bold?: string;
  license: string;
}

export interface SavedMobileThemeMeta {
  familyId: string;
  version: number;
  name: string;
  authorName: string;
  packageUrl: string;
  light: SavedVariantMeta;
  dark: SavedVariantMeta;
  font?: SavedFontMeta | null;
}

export interface ActiveWallpaperRenderState {
  objectUrl: string;
  fit: "cover" | "contain";
  focalX: number;
  focalY: number;
  scrim: number;
  cssFilter: string;
}

export interface MobileThemeRuntimeSnapshot {
  saved: SavedMobileThemeMeta | null;
  wallpaper: ActiveWallpaperRenderState | null;
  loading: boolean;
  applyingFamilyId: string | null;
  resourceError: string | null;
  storageWarning: string | null;
}

export interface CatalogThemeAuthor {
  id: number;
  nickname: string;
  avatarUrl?: string;
}

export interface CatalogThemeItem {
  familyId: string;
  version: number;
  name: string;
  description: string;
  license: string;
  author: CatalogThemeAuthor;
  tags: string[];
  source: "official" | "community";
  previewLight: string;
  previewDark: string;
  packageUrl: string;
  packageSize: number;
  packageSha256: string;
  minAppVersion: string;
  downloads: number;
  updatedAt: string;
}

const ALL_TOKEN_CSS_VARS = [
  "--theme-primary",
  "--theme-on-primary",
  "--theme-primary-container",
  "--theme-on-primary-container",
  "--theme-background",
  "--theme-surface",
  "--theme-surface-elevated",
  "--theme-surface-muted",
  "--theme-card",
  "--theme-card-border",
  "--theme-text-primary",
  "--theme-text-secondary",
  "--theme-text-tertiary",
  "--theme-text-disabled",
  "--theme-divider",
  "--theme-outline",
  "--theme-input-fill",
  "--theme-input-fill-focused",
  "--theme-search-fill",
  "--theme-tag-background",
  "--theme-tag-text",
  "--theme-nav-background",
  "--theme-nav-selected",
  "--theme-nav-unselected",
  "--theme-app-bar-background",
  "--theme-app-bar-foreground",
  "--theme-bubble-incoming",
  "--theme-bubble-incoming-text",
  "--theme-bubble-outgoing",
  "--theme-bubble-outgoing-text",
  "--theme-feed-section-surface",
  "--theme-feed-featured-surface",
  "--theme-feed-featured-text",
  "--theme-course-card-text",
  "--theme-timetable-grid",
  "--theme-timetable-today",
];

function tokenKeyToCssVar(key: string): string {
  return `--theme-${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;
}

/** 将契约中的 #RRGGBB 或 Flutter #AARRGGBB 转为标准 CSS 颜色值。 */
export function contractHexToCss(hex: string): string | null {
  const trimmed = String(hex || "").trim();
  if (/^#[0-9a-fA-F]{6}$/.test(trimmed)) return trimmed;
  if (/^#[0-9a-fA-F]{8}$/.test(trimmed)) {
    return `#${trimmed.slice(3)}${trimmed.slice(1, 3)}`;
  }
  return null;
}

export function buildWallpaperCssFilter(slot: WallpaperSlotConfig): string {
  const adj = slot.adjustments;
  const parts: string[] = [];
  if (adj) {
    const b = typeof adj.brightness === "number" ? adj.brightness : 0;
    const c = typeof adj.contrast === "number" ? adj.contrast : 100;
    const s = typeof adj.saturation === "number" ? adj.saturation : 100;
    if (b !== 0) parts.push(`brightness(${Math.max(0, 1 + b / 100).toFixed(3)})`);
    if (c !== 100) parts.push(`contrast(${Math.max(0, c / 100).toFixed(3)})`);
    if (s !== 100) parts.push(`saturate(${Math.max(0, s / 100).toFixed(3)})`);
  }
  const blur = typeof slot.blur === "number" ? slot.blur : 0;
  if (blur > 0) parts.push(`blur(${Math.min(24, blur)}px)`);
  return parts.length > 0 ? parts.join(" ") : "none";
}

function readStoredMeta(): SavedMobileThemeMeta | null {
  try {
    const raw = localStorage.getItem(MOBILE_THEME_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<SavedMobileThemeMeta>;
    if (
      !parsed ||
      typeof parsed.familyId !== "string" ||
      typeof parsed.version !== "number" ||
      typeof parsed.packageUrl !== "string" ||
      !parsed.light?.tokens ||
      !parsed.dark?.tokens
    ) {
      return null;
    }
    return parsed as SavedMobileThemeMeta;
  } catch {
    return null;
  }
}

function isDarkActive(): boolean {
  if (typeof document === "undefined") return false;
  return document.documentElement.dataset.theme === "dark";
}

function applySavedTokensToDom(saved: SavedMobileThemeMeta | null, dark: boolean) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  for (const cssVar of ALL_TOKEN_CSS_VARS) {
    root.style.removeProperty(cssVar);
  }
  if (!saved) {
    delete root.dataset.mobileTheme;
    root.style.removeProperty("--theme-font-family");
    return;
  }
  root.dataset.mobileTheme = "1";
  const variant = dark ? saved.dark : saved.light;
  const tokens = variant?.tokens || {};
  for (const [key, rawHex] of Object.entries(tokens)) {
    const cssColor = contractHexToCss(rawHex);
    if (cssColor) {
      root.style.setProperty(tokenKeyToCssVar(key), cssColor);
    }
  }
}

async function inflateRawBytes(compressed: Uint8Array): Promise<Uint8Array> {
  const ds = new DecompressionStream("deflate-raw");
  const writer = ds.writable.getWriter();
  void writer.write(compressed as unknown as BufferSource);
  void writer.close();
  const reader = ds.readable.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      total += value.byteLength;
      if (total > MAX_UNCOMPRESSED_BYTES) {
        throw new Error("主题包解压体积超出上限");
      }
      chunks.push(value);
    }
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/** 解析规范 .sltheme ZIP（仅支持标准存储 0 与 Deflate 8，信任边界限制总解压体积）。 */
export async function extractSlthemeEntries(buffer: ArrayBuffer): Promise<Map<string, Uint8Array>> {
  const bytes = new Uint8Array(buffer);
  const view = new DataView(buffer);
  const minEocdOffset = Math.max(0, bytes.byteLength - 65557);
  let eocd = -1;
  for (let pos = bytes.byteLength - 22; pos >= minEocdOffset; pos -= 1) {
    if (view.getUint32(pos, true) === 0x06054b50) {
      eocd = pos;
      break;
    }
  }
  if (eocd < 0) throw new Error("无效的主题包文件");

  const entryCount = view.getUint16(eocd + 10, true);
  const cdOffset = view.getUint32(eocd + 16, true);
  const decoder = new TextDecoder("utf-8");
  const entries = new Map<string, Uint8Array>();

  let ptr = cdOffset;
  let totalUncompressed = 0;
  for (let i = 0; i < entryCount; i += 1) {
    if (ptr + 46 > bytes.byteLength || view.getUint32(ptr, true) !== 0x02014b50) {
      throw new Error("主题包目录结构损坏");
    }
    const method = view.getUint16(ptr + 10, true);
    const compSize = view.getUint32(ptr + 20, true);
    const uncompSize = view.getUint32(ptr + 24, true);
    const nameLen = view.getUint16(ptr + 28, true);
    const extraLen = view.getUint16(ptr + 30, true);
    const commentLen = view.getUint16(ptr + 32, true);
    const localHeaderOffset = view.getUint32(ptr + 42, true);

    const name = decoder.decode(bytes.subarray(ptr + 46, ptr + 46 + nameLen));
    ptr += 46 + nameLen + extraLen + commentLen;

    if (!name || name.endsWith("/")) continue;
    totalUncompressed += uncompSize;
    if (totalUncompressed > MAX_UNCOMPRESSED_BYTES) {
      throw new Error("主题包资源总大小超出限制");
    }
    if (localHeaderOffset + 30 > bytes.byteLength || view.getUint32(localHeaderOffset, true) !== 0x04034b50) {
      throw new Error("主题包条目头损坏");
    }
    const localNameLen = view.getUint16(localHeaderOffset + 26, true);
    const localExtraLen = view.getUint16(localHeaderOffset + 28, true);
    const dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen;
    const dataEnd = dataStart + compSize;
    if (dataEnd > bytes.byteLength) throw new Error("主题包条目越界");

    const slice = bytes.subarray(dataStart, dataEnd);
    if (method === 0) {
      entries.set(name, slice.slice());
    } else if (method === 8) {
      entries.set(name, await inflateRawBytes(slice));
    } else {
      throw new Error("不支持的压缩方式");
    }
  }
  return entries;
}

function mimeForPath(entryPath: string): string {
  const lower = entryPath.toLowerCase();
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".webp")) return "image/webp";
  return "image/jpeg";
}

function routeSlotForPathname(pathname: string): "home" | "schedule" | "me" | "global" {
  if (pathname === "/" || pathname === "") return "home";
  if (pathname.startsWith("/schedule")) return "schedule";
  if (pathname.startsWith("/profile")) return "me";
  return "global";
}

// ===== 模块级单例状态与资源代数管理 =====
let snapshot: MobileThemeRuntimeSnapshot = {
  saved: null,
  wallpaper: null,
  loading: false,
  applyingFamilyId: null,
  resourceError: null,
  storageWarning: null,
};

const listeners = new Set<() => void>();
let resourceGeneration = 0;
let activeFetchAbort: AbortController | null = null;
let cachedArchiveKey = "";
let cachedArchiveEntries: Map<string, Uint8Array> | null = null;
let currentPathname = "/";
let initialized = false;
const registeredFontFamilies = new Set<string>();

function emit() {
  for (const listener of listeners) listener();
}

function setSnapshot(partial: Partial<MobileThemeRuntimeSnapshot>) {
  snapshot = { ...snapshot, ...partial };
  emit();
}

function revokeCurrentWallpaperUrl() {
  if (snapshot.wallpaper?.objectUrl) {
    try {
      URL.revokeObjectURL(snapshot.wallpaper.objectUrl);
    } catch {
      // 忽略已释放 URL
    }
  }
}

function resolveSlotConfig(
  saved: SavedMobileThemeMeta,
  dark: boolean,
  pathname: string,
): WallpaperSlotConfig | null {
  const variant = dark ? saved.dark : saved.light;
  const walls = variant?.wallpapers;
  if (!walls) return null;
  const preferred = routeSlotForPathname(pathname);
  return walls[preferred] || walls.global || null;
}

function applyWallpaperFromEntries(
  saved: SavedMobileThemeMeta,
  entries: Map<string, Uint8Array>,
  dark: boolean,
  pathname: string,
) {
  const slot = resolveSlotConfig(saved, dark, pathname);
  revokeCurrentWallpaperUrl();
  if (!slot || !slot.portrait) {
    setSnapshot({ wallpaper: null });
    return;
  }
  const cleanKey = slot.portrait.replace(/^\/+/, "");
  const imgBytes = entries.get(cleanKey) || entries.get(slot.portrait);
  if (!imgBytes) {
    setSnapshot({ wallpaper: null });
    return;
  }
  const blob = new Blob([imgBytes as unknown as BlobPart], { type: mimeForPath(cleanKey) });
  const objectUrl = URL.createObjectURL(blob);
  setSnapshot({
    wallpaper: {
      objectUrl,
      fit: slot.fit === "contain" ? "contain" : "cover",
      focalX: typeof slot.focalX === "number" ? slot.focalX : 0.5,
      focalY: typeof slot.focalY === "number" ? slot.focalY : 0.5,
      scrim: typeof slot.scrim === "number" ? Math.min(0.85, Math.max(0, slot.scrim)) : 0,
      cssFilter: buildWallpaperCssFilter(slot),
    },
  });
}

async function applyFontFromEntries(
  saved: SavedMobileThemeMeta,
  entries: Map<string, Uint8Array>,
  gen: number,
) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  if (!saved.font?.regular) {
    root.style.removeProperty("--theme-font-family");
    return;
  }
  const familyName = `sylulive_web_theme_${saved.familyId.replace(/[^a-zA-Z0-9]/g, "_")}_${saved.version}`;
  if (!registeredFontFamilies.has(familyName) && typeof FontFace !== "undefined") {
    const regKey = saved.font.regular.replace(/^\/+/, "");
    const regBytes = entries.get(regKey);
    if (!regBytes) throw new Error("主题包字体资源缺失");
    const regFace = new FontFace(familyName, regBytes as unknown as BufferSource, { weight: "400" });
    await regFace.load();
    if (gen !== resourceGeneration) return;
    document.fonts.add(regFace);

    if (saved.font.bold) {
      const boldKey = saved.font.bold.replace(/^\/+/, "");
      const boldBytes = entries.get(boldKey);
      if (boldBytes) {
        const boldFace = new FontFace(familyName, boldBytes as unknown as BufferSource, { weight: "700" });
        await boldFace.load();
        if (gen !== resourceGeneration) return;
        document.fonts.add(boldFace);
      }
    }
    registeredFontFamilies.add(familyName);
  }
  if (gen === resourceGeneration) {
    root.style.setProperty(
      "--theme-font-family",
      `"${familyName}", Inter, "Noto Sans SC", "Microsoft YaHei", system-ui, sans-serif`,
    );
  }
}

async function hydrateArchiveResources(saved: SavedMobileThemeMeta, gen: number) {
  const archiveKey = `${saved.familyId}@${saved.version}:${saved.packageUrl}`;
  if (cachedArchiveKey === archiveKey && cachedArchiveEntries) {
    await applyFontFromEntries(saved, cachedArchiveEntries, gen);
    if (gen !== resourceGeneration) return;
    applyWallpaperFromEntries(saved, cachedArchiveEntries, isDarkActive(), currentPathname);
    setSnapshot({ loading: false, resourceError: null });
    return;
  }

  activeFetchAbort?.abort();
  const controller = new AbortController();
  activeFetchAbort = controller;
  setSnapshot({ loading: true, resourceError: null });

  try {
    const resp = await fetch(saved.packageUrl, {
      signal: controller.signal,
      credentials: "same-origin",
    });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const buf = await resp.arrayBuffer();
    if (gen !== resourceGeneration) return;

    const entries = await extractSlthemeEntries(buf);
    if (gen !== resourceGeneration) return;

    cachedArchiveKey = archiveKey;
    cachedArchiveEntries = entries;

    await applyFontFromEntries(saved, entries, gen);
    if (gen !== resourceGeneration) return;
    applyWallpaperFromEntries(saved, entries, isDarkActive(), currentPathname);
    setSnapshot({ loading: false, resourceError: null });
  } catch (err) {
    if (gen !== resourceGeneration || controller.signal.aborted) return;
    revokeCurrentWallpaperUrl();
    setSnapshot({
      wallpaper: null,
      loading: false,
      resourceError: "主题壁纸或字体暂未加载，当前已保留主题配色；联网后可点击重试。",
    });
  }
}

export function initMobileThemeRuntime() {
  if (initialized || typeof window === "undefined") return;
  initialized = true;
  const saved = readStoredMeta();
  snapshot = { ...snapshot, saved };
  applySavedTokensToDom(saved, isDarkActive());
  if (saved) {
    const gen = ++resourceGeneration;
    void hydrateArchiveResources(saved, gen);
  }
  window.addEventListener("online", () => {
    if (snapshot.saved && snapshot.resourceError) {
      retryMobileThemeResources();
    }
  });
}

export function syncMobileThemeContext(dark: boolean, pathname: string) {
  initMobileThemeRuntime();
  currentPathname = pathname;
  applySavedTokensToDom(snapshot.saved, dark);
  if (!snapshot.saved) return;
  const archiveKey = `${snapshot.saved.familyId}@${snapshot.saved.version}:${snapshot.saved.packageUrl}`;
  if (cachedArchiveKey === archiveKey && cachedArchiveEntries) {
    applyWallpaperFromEntries(snapshot.saved, cachedArchiveEntries, dark, pathname);
  }
}

export async function applyMobileThemeFromCatalog(item: CatalogThemeItem): Promise<void> {
  initMobileThemeRuntime();
  const gen = ++resourceGeneration;
  activeFetchAbort?.abort();
  const controller = new AbortController();
  activeFetchAbort = controller;
  setSnapshot({
    loading: true,
    applyingFamilyId: item.familyId,
    resourceError: null,
    storageWarning: null,
  });

  try {
    const resp = await fetch(item.packageUrl, {
      signal: controller.signal,
      credentials: "same-origin",
    });
    if (!resp.ok) throw new Error(`下载主题包失败 (${resp.status})`);
    const buf = await resp.arrayBuffer();
    if (gen !== resourceGeneration) return;

    const entries = await extractSlthemeEntries(buf);
    if (gen !== resourceGeneration) return;

    const manifestBytes = entries.get("manifest.json");
    if (!manifestBytes) throw new Error("主题包缺少 manifest.json");
    const manifest = JSON.parse(new TextDecoder("utf-8").decode(manifestBytes)) as Record<string, any>;

    const saved: SavedMobileThemeMeta = {
      familyId: item.familyId,
      version: item.version,
      name: item.name || String(manifest.name || "主题"),
      authorName: item.author?.nickname || String(manifest.author || ""),
      packageUrl: item.packageUrl,
      light: {
        tokens: (manifest.light?.tokens as Record<string, string>) || {},
        wallpapers: manifest.light?.wallpapers || undefined,
      },
      dark: {
        tokens: (manifest.dark?.tokens as Record<string, string>) || {},
        wallpapers: manifest.dark?.wallpapers || undefined,
      },
      font: manifest.font
        ? {
            name: String(manifest.font.name || ""),
            regular: String(manifest.font.regular || ""),
            bold: manifest.font.bold ? String(manifest.font.bold) : undefined,
            license: String(manifest.font.license || "OFL-1.1"),
          }
        : null,
    };

    await applyFontFromEntries(saved, entries, gen);
    if (gen !== resourceGeneration) return;

    let storageWarning: string | null = null;
    try {
      localStorage.setItem(MOBILE_THEME_STORAGE_KEY, JSON.stringify(saved));
    } catch {
      storageWarning = "浏览器本地存储不可用或空间已满，当前主题仅在本次页面会话生效。";
    }

    cachedArchiveKey = `${saved.familyId}@${saved.version}:${saved.packageUrl}`;
    cachedArchiveEntries = entries;

    applySavedTokensToDom(saved, isDarkActive());
    applyWallpaperFromEntries(saved, entries, isDarkActive(), currentPathname);
    setSnapshot({
      saved,
      loading: false,
      applyingFamilyId: null,
      resourceError: null,
      storageWarning,
    });
  } catch (err) {
    if (gen !== resourceGeneration || controller.signal.aborted) return;
    setSnapshot({
      loading: false,
      applyingFamilyId: null,
      resourceError: err instanceof Error ? err.message : "应用主题失败，请重试",
    });
    throw err;
  }
}

export function retryMobileThemeResources() {
  if (!snapshot.saved) return;
  const gen = ++resourceGeneration;
  void hydrateArchiveResources(snapshot.saved, gen);
}

export function restoreDefaultMobileTheme() {
  resourceGeneration += 1;
  activeFetchAbort?.abort();
  activeFetchAbort = null;
  revokeCurrentWallpaperUrl();
  try {
    localStorage.removeItem(MOBILE_THEME_STORAGE_KEY);
  } catch {
    // 忽略受限隐私存储异常
  }
  applySavedTokensToDom(null, isDarkActive());
  setSnapshot({
    saved: null,
    wallpaper: null,
    loading: false,
    applyingFamilyId: null,
    resourceError: null,
    storageWarning: null,
  });
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function getSnapshot() {
  return snapshot;
}

export function useMobileThemeRuntime(dark?: boolean, pathname?: string): MobileThemeRuntimeSnapshot {
  useEffect(() => {
    initMobileThemeRuntime();
    if (typeof dark === "boolean" && typeof pathname === "string") {
      syncMobileThemeContext(dark, pathname);
    }
  }, [dark, pathname]);
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}
