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
