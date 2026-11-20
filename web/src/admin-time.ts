// 管理端待办的等待时长：超过 1 天提醒、超过 3 天告警，工作台和工单列表共用同一套阈值。
const HOUR = 3600e3;

export type WaitLevel = "" | "warn" | "late";

export function waitLevel(since: unknown, now = Date.now()): WaitLevel {
  const t = typeof since === "string" ? Date.parse(since) : NaN;
  if (!Number.isFinite(t)) return "";
  const hours = (now - t) / HOUR;
  return hours > 72 ? "late" : hours > 24 ? "warn" : "";
}

/** “3 天”“5 小时”“12 分钟”；时间缺失或在未来时返回空串，调用方不展示。 */
export function waitText(since: unknown, now = Date.now()) {
  const t = typeof since === "string" ? Date.parse(since) : NaN;
  if (!Number.isFinite(t) || t > now) return "";
  const hours = (now - t) / HOUR;
  if (hours < 1) return `${Math.max(1, Math.round(hours * 60))} 分钟`;
  if (hours < 24) return `${Math.round(hours)} 小时`;
  return `${Math.round(hours / 24)} 天`;
}

export function greeting(now = new Date()) {
  const h = now.getHours();
  return h < 5 ? "夜深了" : h < 11 ? "早上好" : h < 13 ? "中午好" : h < 18 ? "下午好" : "晚上好";
}
