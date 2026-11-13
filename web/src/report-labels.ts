// 举报原因码、目标类型与状态的中文标签。
// 原因码表与 App 端 client/lib/utils/report_reason_label.dart 保持同一份取值，
// 两端展示同一条举报时文案必须一致；新增原因码时两处一起改。
const reasons: Record<string, string> = {
  spam: "垃圾广告",
  porn: "色情低俗",
  violence: "暴力血腥",
  fake: "虚假信息",
  privacy: "侵犯隐私",
  harassment: "人身攻击",
  fabricated: "捏造或失实",
  false: "虚假信息",
  unrelated: "与菜品无关",
  unrelated_photo: "图片与菜品无关",
  unrelated_content: "内容与目标无关",
  fake_dish: "虚假菜品",
  stolen_photo: "盗用图片",
  malicious: "恶意内容",
  malicious_repeat: "重复恶意内容",
  abuse: "辱骂或恶意内容",
  other: "其他",
};

const targets: Record<string, string> = {
  post: "帖子",
  reply: "评论",
  canteen_review: "食堂评价",
  canteen_rating: "历史食堂评价",
  canteen_dish_review: "菜品评价",
  canteen_dish_photo: "菜品实拍",
};

export const reportStatuses: Record<string, string> = {
  pending: "待处理",
  handled: "已处理",
  ignored: "已忽略",
  overturned: "申诉已撤销",
};

/** 已知原因码返回中文；未知时尝试把自由文本当作码匹配，仍不匹配就原样返回。 */
export function reportReasonLabel(code?: string, fallback?: string) {
  const c = code?.trim() || "";
  if (reasons[c]) return reasons[c];
  const f = fallback?.trim() || "";
  return reasons[f] || f || "未注明原因";
}

export function reportTargetLabel(type?: string) {
  return targets[type || ""] || "内容";
}

/** 举报人补充的自由文本；与原因码相同（旧数据只存了码）时不重复展示。 */
export function reportNote(code?: string, reason?: string) {
  const text = reason?.trim() || "";
  if (!text || text === code?.trim() || reasons[text]) return "";
  return text;
}

type Snapshot = Record<string, unknown>;
export function reportSnapshot(raw: unknown): Snapshot | null {
  if (raw && typeof raw === "object") return raw as Snapshot;
  if (typeof raw !== "string" || !raw.trim()) return null;
  try {
    const value = JSON.parse(raw);
    return value && typeof value === "object" ? (value as Snapshot) : null;
  } catch {
    return null;
  }
}

/** 被举报内容快照的可读摘要，规则与 App 举报处理页一致。 */
export function reportPreview(type: string | undefined, snapshot: Snapshot | null) {
  if (!snapshot) return "";
  const parts: string[] = [];
  const text = (v: unknown) => (typeof v === "string" ? v.trim() : v == null ? "" : String(v).trim());
  if (type === "post" && text(snapshot.title)) parts.push(text(snapshot.title));
  const score = snapshot.star ?? snapshot.overall_score;
  if (score != null && score !== "") parts.push(`评分：${score}`);
  const body = text(snapshot.content) || text(snapshot.comment);
  if (body) parts.push(body);
  const images = snapshot.image_file_ids;
  if (Array.isArray(images) && images.length) parts.push(`[含 ${images.length} 张图片]`);
  return parts.join(" · ");
}

/** 只有帖子和带 post_id 快照的评论能在 Web 打开原内容。 */
export function reportTargetHref(type: string | undefined, targetId: unknown, snapshot: Snapshot | null) {
  if (type === "post" && targetId) return `/post/${targetId}`;
  if (type === "reply" && snapshot?.post_id) return `/post/${snapshot.post_id}`;
  return "";
}

// 食堂类举报确认违规时必须由管理员另选确认原因（处罚依据不沿用举报人选择），
// 可选范围与服务端 canteenGovernanceReasonCodes 一致。
const canteenTextReasons = ["fabricated", "false", "unrelated", "unrelated_content", "spam", "abuse", "harassment", "malicious", "malicious_repeat"];
const canteenReasonCodes: Record<string, string[]> = {
  canteen_review: canteenTextReasons,
  canteen_rating: canteenTextReasons,
  canteen_dish_review: [...canteenTextReasons.slice(0, 4), "fake_dish", ...canteenTextReasons.slice(4)],
  canteen_dish_photo: ["unrelated_photo", "stolen_photo", "spam", "abuse", "harassment", "malicious", "malicious_repeat"],
};
export function canteenGovernanceReasons(type?: string): [string, string][] {
  return (canteenReasonCodes[type || ""] || []).map(code => [code, reasons[code] || code]);
}

export type ReportDecision = { status: "ignored" | "handled"; result: string; governanceReason: string; confirmedReasonCode: string };
/**
 * 生成 PUT /api/reports/:id/handle 的请求体；输入不完整时抛出可直接展示的错误。
 * 确认违规不传 action，由服务端按默认的“治理隐藏”处理（帖子保留供作者整改申诉），
 * 与 App 管理端一致；治理原因写入 delete_reason，缺失时服务端会拒绝。
 */
export function reportHandlePayload(targetType: string | undefined, d: ReportDecision) {
  const result = d.result.trim();
  if (d.status === "ignored") return { status: "ignored", result };
  const deleteReason = d.governanceReason.trim();
  if (!deleteReason) throw new Error("确认违规必须填写治理原因");
  const canteen = canteenGovernanceReasons(targetType);
  if (canteen.length && !canteen.some(([code]) => code === d.confirmedReasonCode))
    throw new Error("食堂内容确认违规必须选择确认原因");
  return {
    status: "handled", result, delete_reason: deleteReason,
    ...(canteen.length ? { confirmed_reason_code: d.confirmedReasonCode } : {}),
  };
}

// 治理原因的常用表述：点选后填入输入框，管理员仍可修改；未列出的原因码用通用表述。
const governancePresets: Record<string, string[]> = {
  porn: ["包含色情低俗内容，违反社区规则", "图片含不适宜内容"],
  spam: ["发布广告或引流信息，违反社区规则", "短时间内重复刷屏"],
  harassment: ["对他人进行人身攻击"],
  abuse: ["包含辱骂或恶意内容"],
  privacy: ["泄露他人隐私信息"],
  fake: ["内容与事实不符"],
  false: ["内容与事实不符"],
  fabricated: ["评价内容捏造或失实"],
  stolen_photo: ["图片并非本档口实拍，属于盗用他人图片"],
  unrelated_photo: ["图片与菜品无关"],
  fake_dish: ["菜品信息不实"],
};
export function governanceReasonPresets(code?: string, reason?: string) {
  const key = (code || "").trim() || (reason || "").trim();
  return governancePresets[key] || ["内容违反社区规则"];
}
