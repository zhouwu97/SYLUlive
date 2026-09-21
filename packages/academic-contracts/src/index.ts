export const PROTOCOL_VERSION = 1;
export const BRIDGE_CHANNEL = "sylulive-academic-v1";
export const providers = [
  "undergraduate",
  "graduate",
  "erke",
  "physical",
] as const;
export type AcademicProvider = (typeof providers)[number];
export type AcademicDataset =
  "courses" | "grades" | "requirements" | "situation" | "erke" | "physical";
export interface Course {
  id: string;
  name: string;
  teacher: string;
  room: string;
  day: number;
  periods: number[];
  weeks: number[];
}
export interface Grade {
  id: string;
  name: string;
  credit: number;
  score: string;
  gpa: number | null;
  nature: string;
  term: string;
}
export interface Exam {
  id: string;
  name: string;
  startTime: string;
  endTime: string;
  room: string;
  semester: string;
}
export interface AcademicTerm {
  year: string;
  semester: string;
  providerTermId?: string;
}
export interface AcademicCapabilities {
  provider: AcademicProvider;
  datasets: AcademicDataset[];
}
export interface AcademicConnection {
  appUserId: number;
  provider: AcademicProvider;
  studentId: string;
  displayName: string;
  state: "connected" | "expired";
  epoch: string;
  connectedAt: string;
}
export interface AcademicSnapshot {
  version: 1;
  provider: AcademicProvider;
  studentId: string;
  dataset: AcademicDataset;
  term: AcademicTerm;
  fetchedAt: string;
  parserVersion: 1;
  data: unknown;
}
export type BridgeOperation =
  | "hello"
  | "connect"
  | "confirm"
  | "session"
  | "query"
  | "disconnect"
  | "cancel"
  | "persistence"
  | "cache"
  | "reminders"
  | "window";
export interface BridgeRequest {
  channel: typeof BRIDGE_CHANNEL;
  direction: "request";
  version: 1;
  id: string;
  operation: BridgeOperation;
  payload: Record<string, unknown>;
}
export interface BridgeResponse {
  channel: typeof BRIDGE_CHANNEL;
  direction: "response";
  version: 1;
  id: string;
  ok: boolean;
  result?: unknown;
  error?: { code: string; message: string };
}
export const capabilities: AcademicCapabilities[] = [
  {
    provider: "undergraduate",
    datasets: ["courses", "grades", "requirements", "situation"],
  },
  { provider: "graduate", datasets: ["courses"] },
  { provider: "erke", datasets: ["erke"] },
  { provider: "physical", datasets: ["physical"] },
];
const operations: BridgeOperation[] = [
  "hello",
  "connect",
  "confirm",
  "session",
  "query",
  "disconnect",
  "cancel",
  "persistence",
  "cache",
  "reminders",
  "window",
];
export function isBridgeRequest(value: unknown): value is BridgeRequest {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return (
    v.channel === BRIDGE_CHANNEL &&
    v.direction === "request" &&
    v.version === 1 &&
    typeof v.id === "string" &&
    v.id.length <= 80 &&
    operations.includes(v.operation as BridgeOperation) &&
    !!v.payload &&
    typeof v.payload === "object" &&
    !Array.isArray(v.payload)
  );
}
export function isProvider(value: unknown): value is AcademicProvider {
  return providers.includes(value as AcademicProvider);
}
export function teachingWeek(start: string, now = new Date()): number {
  const d = new Date(`${start}T00:00:00+08:00`);
  if (!Number.isFinite(d.getTime())) return 1;
  return Math.floor((now.getTime() - d.getTime()) / 604800000) + 1;
}
export function courseConflicts(a: Course, b: Course): boolean {
  return (
    a.id !== b.id &&
    a.day === b.day &&
    a.periods.some((x) => b.periods.includes(x)) &&
    a.weeks.some((x) => b.weeks.includes(x))
  );
}
export function mergeCourses(
  base: Course[],
  overrides: Record<string, Course | null>,
): Course[] {
  const result = new Map(base.map((c) => [c.id, c]));
  Object.entries(overrides).forEach(([id, c]) =>
    c === null ? result.delete(id) : result.set(id, c),
  );
  return [...result.values()];
}
export function gradeStats(grades: Grade[]) {
  const numeric = grades.filter(
    (g) =>
      g.score.trim() !== "" && Number.isFinite(Number(g.score)) && g.credit > 0,
  );
  const withGpa = grades.filter(
    (g) => g.gpa !== null && Number.isFinite(g.gpa) && g.credit > 0,
  );
  const weighted = (items: Grade[], value: (g: Grade) => number) =>
    items.length
      ? items.reduce((s, g) => s + g.credit * value(g), 0) /
        items.reduce((s, g) => s + g.credit, 0)
      : null;
  return {
    average: weighted(numeric, (g) => Number(g.score)),
    gpa: weighted(withGpa, (g) => g.gpa!),
    credits: grades
      .filter(
        (g) =>
          Number(g.score) >= 60 ||
          ["优秀", "良好", "中等", "及格", "合格", "通过"].includes(g.score),
      )
      .reduce((s, g) => s + g.credit, 0),
  };
}
export interface AcademicBackup {
  version: 1;
  term: AcademicTerm;
  termStart: string;
  courses: Course[];
  overrides: Record<string, Course | null>;
  grades: Grade[];
  exams: Exam[];
}
export function parseBackup(text: string): AcademicBackup {
  if (text.length > 5 * 1024 * 1024) throw new Error("资料文件不能超过 5 MB");
  const parsed = JSON.parse(text) as AcademicBackup | Record<string, unknown>[];
  // App 端课表存档历史上直接导出 CourseBlock 数组，Web 端需要兼容该格式。
  // 转换只读取排课字段，不把 App 的展示状态、账号或凭据带入 Web 数据。
  if (Array.isArray(parsed)) {
    const courses = parsed.map((item, index) => legacyCourse(item, index));
    if (!courses.length) throw new Error("课表数据为空或格式不正确");
    const now = new Date();
    return {
      version: 1,
      term: { year: String(now.getFullYear()), semester: "3" },
      termStart: `${now.getFullYear()}-01-01`,
      courses,
      overrides: {},
      grades: [],
      exams: [],
    };
  }
  const v = parsed;
  if (
    !v ||
    typeof v !== "object" ||
    v.version !== 1 ||
    !v.term ||
    !/^\d{4}$/.test(v.term.year) ||
    !["3", "12", "16"].includes(v.term.semester) ||
    !/^\d{4}-\d{2}-\d{2}$/.test(v.termStart) ||
    !Array.isArray(v.courses) ||
    !Array.isArray(v.grades) ||
    !Array.isArray(v.exams) ||
    !v.overrides ||
    typeof v.overrides !== "object" ||
    Array.isArray(v.overrides)
  )
    throw new Error("资料格式不正确");
  const courses = [
    ...v.courses,
    ...Object.values(v.overrides).filter((c): c is Course => c !== null),
  ];
  if (
    courses.length > 2000 ||
    courses.some(
      (c) =>
        !c ||
        typeof c.id !== "string" ||
        typeof c.name !== "string" ||
        c.name.length > 200 ||
        !Number.isInteger(c.day) ||
        c.day < 1 ||
        c.day > 7 ||
        !Array.isArray(c.periods) ||
        !c.periods.length ||
        c.periods.some((n) => !Number.isInteger(n) || n < 1 || n > 20) ||
        !Array.isArray(c.weeks) ||
        !c.weeks.length ||
        c.weeks.some((n) => !Number.isInteger(n) || n < 1 || n > 60),
    )
  )
    throw new Error("课程字段不正确");
  if (
    v.grades.length > 5000 ||
    v.grades.some(
      (g) =>
        !g ||
        typeof g.name !== "string" ||
        typeof g.score !== "string" ||
        !Number.isFinite(g.credit) ||
        g.credit < 0 ||
        (g.gpa !== null && !Number.isFinite(g.gpa)),
    )
  )
    throw new Error("成绩字段不正确");
  if (
    v.exams.some(
      (e) =>
        !e ||
        typeof e.id !== "string" ||
        typeof e.name !== "string" ||
        !Number.isFinite(Date.parse(e.startTime)) ||
        !Number.isFinite(Date.parse(e.endTime)) ||
        Date.parse(e.endTime) <= Date.parse(e.startTime),
    )
  )
    throw new Error("考试字段不正确");
  // 显式重建对象，导入文件中的额外凭据字段不会进入存储。
  return {
    version: 1,
    term: { year: String(v.term.year), semester: String(v.term.semester) },
    termStart: v.termStart,
    courses: v.courses.map(cleanCourse),
    overrides: Object.fromEntries(
      Object.entries(v.overrides).map(([id, c]) => [id, c && cleanCourse(c)]),
    ),
    grades: v.grades.map((g) => ({
      id: String(g.id),
      name: g.name,
      credit: g.credit,
      score: g.score,
      gpa: g.gpa,
      nature: String(g.nature || ""),
      term: String(g.term || ""),
    })),
    exams: v.exams.map((e) => ({
      id: e.id,
      name: e.name,
      startTime: e.startTime,
      endTime: e.endTime,
      room: String(e.room || ""),
      semester: String(e.semester || ""),
    })),
  };
}
function legacyCourse(value: Record<string, unknown>, index: number): Course {
  const day = Number(value.weekday ?? value.day);
  const start = Number(value.start_section ?? value.startSection);
  const end = Number(value.end_section ?? value.endSection ?? start);
  const weeks = Array.isArray(value.weeks)
    ? value.weeks.map(Number).filter((n) => Number.isInteger(n) && n > 0 && n <= 60)
    : [];
  if (!Number.isInteger(day) || day < 1 || day > 7 || !Number.isInteger(start) || start < 1 || start > 20 || !Number.isInteger(end) || end < start || end > 20 || !weeks.length)
    throw new Error(`第 ${index + 1} 条课程字段不正确`);
  return {
    id: String(value.id ?? value.course_key ?? `imported:${index}`),
    name: String(value.name ?? value.custom_name ?? "").trim(),
    teacher: String(value.teacher ?? ""),
    room: String(value.location ?? value.room ?? ""),
    day,
    periods: Array.from({ length: end - start + 1 }, (_, offset) => start + offset),
    weeks,
  };
}
function cleanCourse(c: Course): Course {
  return {
    id: c.id,
    name: c.name,
    room: String(c.room || ""),
    teacher: String(c.teacher || ""),
    day: c.day,
    periods: c.periods,
    weeks: c.weeks,
  };
}
