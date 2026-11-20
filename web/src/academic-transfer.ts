import type { AcademicTerm, Course, Exam, Grade } from "@sylulive/academic-contracts";

/**
 * 手机 App 扫码同步：网页出码，App 扫码后把本机教务资料加密上传，本页取回解密。
 *
 * 临时公钥只放在二维码里，不经过服务器；服务器拿到的只有密文，
 * 因此即使中转被读取也无法还原课表、成绩等个人资料。
 * 协议常量与 App 端 `academic_transfer_crypto.dart` 必须逐字一致。
 */
export const TRANSFER_PROTOCOL = "sylulive-academic-transfer-v1";
export const TRANSFER_SCAN_PATH = "/web/app-scan";

const encoder = new TextEncoder();

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]*$/.test(value)) throw new Error("编码不正确");
  const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export interface TransferKeys {
  /** 不可导出，只存在于本页内存；关闭弹窗即丢弃。 */
  privateKey: CryptoKey;
  /** P-256 未压缩公钥（65 字节）的 base64url，写进二维码交给 App。 */
  publicKey: string;
}

export async function createTransferKeys(): Promise<TransferKeys> {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { privateKey: pair.privateKey, publicKey: toBase64Url(raw) };
}

/** 参数放在 # 之后：别的扫码工具打开这个地址时，公钥也不会随请求发给服务器。 */
export function transferQrText(origin: string, sessionId: string, publicKey: string): string {
  return `${origin}${TRANSFER_SCAN_PATH}#v=1&s=${sessionId}&k=${publicKey}`;
}

export interface TransferEnvelope {
  app_public_key: string;
  nonce: string;
  ciphertext: string;
}

export class TransferError extends Error {}

export async function decryptTransfer(privateKey: CryptoKey, sessionId: string, envelope: TransferEnvelope): Promise<string> {
  try {
    const appKey = await crypto.subtle.importKey("raw", fromBase64Url(envelope.app_public_key), { name: "ECDH", namedCurve: "P-256" }, false, []);
    const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: appKey }, privateKey, 256);
    const material = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
    // 会话 ID 同时进入 HKDF 盐和 GCM 附加数据：密文被挪到另一张码下会直接认证失败。
    const key = await crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: encoder.encode(sessionId), info: encoder.encode(TRANSFER_PROTOCOL) },
      material,
      { name: "AES-GCM", length: 256 },
      false,
      ["decrypt"],
    );
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64Url(envelope.nonce), additionalData: encoder.encode(`${TRANSFER_PROTOCOL}|${sessionId}`) },
      key,
      fromBase64Url(envelope.ciphertext),
    );
    return new TextDecoder("utf-8", { fatal: true }).decode(plain);
  } catch {
    throw new TransferError("无法解密手机发来的资料，请重新生成二维码后再扫一次。");
  }
}

export type TransferScheduleKind = "current" | "term" | "archive";
export interface TransferSchedule {
  id: string;
  kind: TransferScheduleKind;
  label: string;
  /** undergraduate / graduate；未知来源为空串。 */
  provider: string;
  term: AcademicTerm | null;
  termStart: string;
  fetchedAt: string;
  courses: Course[];
}
export interface TransferErkeCategory { code: string; name: string; required: number; earned: number }
export interface TransferErkeActivity { item: string; score: string; date: string; category: string }
export interface TransferErke {
  fetchedAt: string;
  requiredTotal: number | null;
  earnedTotal: number | null;
  graduationGap: number | null;
  conclusion: string;
  categories: TransferErkeCategory[];
  activities: TransferErkeActivity[];
}
export interface TransferPhysicalScore { name: string; result: string; grade: string; score: number | null }
export interface TransferPhysicalYear { year: string; totalScore: number | null; totalGrade: string; scores: TransferPhysicalScore[] }
export interface TransferPhysical { fetchedAt: string; years: TransferPhysicalYear[] }
export interface TransferPayload {
  generatedAt: string;
  schedules: TransferSchedule[];
  grades: Grade[] | null;
  gradesFetchedAt: string;
  exams: Exam[] | null;
  erke: TransferErke | null;
  physical: TransferPhysical | null;
  /** 因字段不合法被丢弃的条目数，用于在结果里如实提示。 */
  skipped: number;
}

type Raw = Record<string, unknown>;
const isRecord = (value: unknown): value is Raw => !!value && typeof value === "object" && !Array.isArray(value);
const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);
const text = (value: unknown, max = 200): string => (typeof value === "string" || typeof value === "number" ? String(value).trim().slice(0, max) : "");
const numberOrNull = (value: unknown): number | null => {
  const parsed = typeof value === "number" ? value : typeof value === "string" && value.trim() !== "" ? Number(value) : NaN;
  return Number.isFinite(parsed) ? parsed : null;
};
const isoTime = (value: unknown): string => (typeof value === "string" && Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : "");
const integers = (value: unknown, min: number, max: number): number[] =>
  [...new Set(list(value).filter((item): item is number => Number.isInteger(item) && (item as number) >= min && (item as number) <= max))].sort((a, b) => a - b);

function parseCourse(value: unknown, seen: Set<string>, fallback: string): Course | null {
  if (!isRecord(value)) return null;
  const name = text(value.name), day = value.day;
  const periods = integers(value.periods, 1, 20), weeks = integers(value.weeks, 1, 60);
  if (!name || !Number.isInteger(day) || (day as number) < 1 || (day as number) > 7 || !periods.length || !weeks.length) return null;
  // 本地调整按课程 id 对应；同一份课表里 id 重复时补序号，避免后一门覆盖前一门。
  let id = text(value.id, 160) || fallback;
  for (let suffix = 2; seen.has(id); suffix += 1) id = `${text(value.id, 160) || fallback}#${suffix}`;
  seen.add(id);
  return { id, name, teacher: text(value.teacher), room: text(value.room), day: day as number, periods, weeks };
}

function parseTerm(value: unknown): AcademicTerm | null {
  if (!isRecord(value)) return null;
  const year = text(value.year, 9).slice(0, 4), semester = text(value.semester, 4);
  return /^\d{4}$/.test(year) && ["3", "12", "16"].includes(semester) ? { year, semester } : null;
}

/**
 * 解析并重建手机发来的资料：只保留已知字段并逐项校验，
 * 多余字段（包括误带的账号、凭据）不会进入页面状态。单条不合法的记录被跳过而不是让整次同步失败。
 */
export function parseTransferPayload(source: string): TransferPayload {
  let parsed: unknown;
  try {
    parsed = JSON.parse(source);
  } catch {
    throw new TransferError("手机发来的资料无法读取，请更新 App 后重试。");
  }
  if (!isRecord(parsed) || parsed.version !== 1)
    throw new TransferError("手机 App 与网页的同步格式不一致，请把两端都更新到最新版本。");
  let skipped = 0;
  const scheduleIds = new Set<string>();
  const schedules: TransferSchedule[] = [];
  for (const [index, item] of list(parsed.schedules).slice(0, 60).entries()) {
    if (!isRecord(item)) { skipped += 1; continue; }
    const seen = new Set<string>();
    const courses: Course[] = [];
    for (const [courseIndex, course] of list(item.courses).slice(0, 2000).entries()) {
      const next = parseCourse(course, seen, `phone:${courseIndex}`);
      if (next) courses.push(next); else skipped += 1;
    }
    let id = text(item.id, 120) || `schedule:${index}`;
    if (scheduleIds.has(id)) id = `${id}#${index}`;
    scheduleIds.add(id);
    const kind: TransferScheduleKind = item.kind === "current" || item.kind === "archive" ? item.kind : "term";
    const termStart = text(item.termStart, 10);
    schedules.push({
      id,
      kind,
      label: text(item.label, 60) || (kind === "current" ? "当前课表" : `课表 ${index + 1}`),
      provider: item.provider === "graduate" || item.provider === "undergraduate" ? item.provider : "",
      term: parseTerm(item.term),
      termStart: /^\d{4}-\d{2}-\d{2}$/.test(termStart) && Number.isFinite(Date.parse(termStart)) ? termStart : "",
      fetchedAt: isoTime(item.fetchedAt),
      courses,
    });
  }
  let grades: Grade[] | null = null, gradesFetchedAt = "";
  if (isRecord(parsed.grades)) {
    gradesFetchedAt = isoTime(parsed.grades.fetchedAt);
    grades = [];
    for (const [index, item] of list(parsed.grades.items).slice(0, 5000).entries()) {
      const name = isRecord(item) ? text(item.name) : "", credit = isRecord(item) ? numberOrNull(item.credit) : null;
      if (!isRecord(item) || !name || credit === null || credit < 0) { skipped += 1; continue; }
      grades.push({ id: text(item.id, 160) || `phone:${index}`, name, credit, score: text(item.score, 40), gpa: numberOrNull(item.gpa), nature: text(item.nature, 60), term: text(item.term, 40) });
    }
  }
  let exams: Exam[] | null = null;
  if (isRecord(parsed.exams)) {
    exams = [];
    for (const [index, item] of list(parsed.exams.items).slice(0, 500).entries()) {
      const name = isRecord(item) ? text(item.name) : "";
      const start = isRecord(item) ? isoTime(item.startTime) : "", end = isRecord(item) ? isoTime(item.endTime) : "";
      if (!isRecord(item) || !name || !start || !end || Date.parse(end) <= Date.parse(start)) { skipped += 1; continue; }
      exams.push({ id: text(item.id, 160) || `phone:${index}`, name, startTime: start, endTime: end, room: text(item.room), semester: text(item.semester, 40) });
    }
  }
  let erke: TransferErke | null = null;
  if (isRecord(parsed.erke)) {
    const source = parsed.erke;
    erke = {
      fetchedAt: isoTime(source.fetchedAt),
      requiredTotal: numberOrNull(source.requiredTotal),
      earnedTotal: numberOrNull(source.earnedTotal),
      graduationGap: numberOrNull(source.graduationGap),
      conclusion: text(source.conclusion, 120),
      categories: list(source.categories).slice(0, 40).filter(isRecord).map((item) => ({
        code: text(item.code, 12), name: text(item.name, 60), required: numberOrNull(item.required) ?? 0, earned: numberOrNull(item.earned) ?? 0,
      })).filter((item) => item.name),
      activities: list(source.activities).slice(0, 1000).filter(isRecord).map((item) => ({
        item: text(item.item), score: text(item.score, 20), date: text(item.date, 30), category: text(item.category, 60),
      })).filter((item) => item.item),
    };
  }
  let physical: TransferPhysical | null = null;
  if (isRecord(parsed.physical)) {
    physical = {
      fetchedAt: isoTime(parsed.physical.fetchedAt),
      years: list(parsed.physical.years).slice(0, 12).filter(isRecord).map((item) => ({
        year: text(item.year, 20),
        totalScore: numberOrNull(item.totalScore),
        totalGrade: text(item.totalGrade, 20),
        scores: list(item.scores).slice(0, 40).filter(isRecord).map((score) => ({
          name: text(score.name, 60), result: text(score.result, 40), grade: text(score.grade, 20), score: numberOrNull(score.score),
        })).filter((score) => score.name),
      })).filter((item) => item.year),
    };
  }
  return { generatedAt: isoTime(parsed.generatedAt) || new Date().toISOString(), schedules, grades, gradesFetchedAt, exams, erke, physical, skipped };
}

/** 优先展示手机上正在使用的那份课表；没有标记时退回第一份有课的。 */
export function preferredSchedule(schedules: TransferSchedule[]): TransferSchedule | undefined {
  return schedules.find((item) => item.kind === "current" && item.courses.length) || schedules.find((item) => item.courses.length) || schedules[0];
}

export function transferSummary(payload: TransferPayload): string[] {
  const parts: string[] = [];
  const withCourses = payload.schedules.filter((item) => item.courses.length);
  if (withCourses.length) parts.push(`课表 ${withCourses.length} 份`);
  if (payload.grades?.length) parts.push(`成绩 ${payload.grades.length} 门`);
  if (payload.exams?.length) parts.push(`考试 ${payload.exams.length} 场`);
  if (payload.erke && (payload.erke.categories.length || payload.erke.activities.length)) parts.push("二课");
  if (payload.physical?.years.length) parts.push("体测");
  return parts;
}
