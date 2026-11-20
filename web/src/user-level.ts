type LevelSource = { exp?: unknown; level?: unknown } | null | undefined;

// 与 client/lib/models/user.dart 保持一致，服务端提供经验值，由客户端计算等级。
const levelThresholds = [0, 50, 150, 500, 1000, 2500, 5000, 8000];

export function userLevel(user: LevelSource, fallbackLevel?: unknown): number {
  const exp = user?.exp;
  if (typeof exp === "number" && Number.isFinite(exp)) {
    return Math.max(1, levelThresholds.filter(threshold => exp >= threshold).length);
  }
  const level = user?.level ?? fallbackLevel;
  return typeof level === "number" && Number.isInteger(level) && level >= 1
    ? Math.min(level, levelThresholds.length)
    : 1;
}

// 过滤控制字符、零宽占位及盲文/谚文/高棉填充符，同时保留合法复合 Emoji 中的 ZWJ 与变体选择符。
const INVISIBLE_NAME_CHARS = /[\u0000-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180E\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u206F\u2800\u3164\uFEFF\uFFA0]/g;

export function displayName(value: unknown, fallback = "校园同学"): string {
  if (typeof value !== "string") return fallback;
  const cleaned = value.replace(INVISIBLE_NAME_CHARS, "").trim();
  if (!cleaned || !cleaned.replace(/[\s\u200D\uFE00-\uFE0F]/g, "")) return fallback;
  return cleaned;
}

export function userHref(targetId: unknown, selfId?: unknown, nickname?: unknown): string | null {
  const id = Number(targetId);
  if (!Number.isInteger(id) || id <= 0) return null;
  if (typeof nickname === "string" && nickname.trim() === "已注销用户") return null;
  return Number(selfId) === id ? "/profile" : `/user/${id}`;
}
