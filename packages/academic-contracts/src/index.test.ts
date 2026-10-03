import { describe, it, expect } from "vitest";
import {
  parseBackup,
  mergeCourses,
  courseConflicts,
  gradeStats,
  isBridgeRequest,
  defaultAcademicTerm,
  BridgeFailure,
  bridgeErrorCode,
  isBridgeErrorCode,
  type AcademicBackup,
  type Course,
} from "./index";
const course: Course = {
  id: "school:1",
  name: "课程",
  teacher: "老师",
  room: "A1",
  day: 1,
  periods: [1, 2],
  weeks: [1, 3],
};
const backup: AcademicBackup = {
  version: 1,
  term: { year: "2026", semester: "3" },
  termStart: "2026-09-07",
  courses: [course],
  grades: [],
  exams: [],
  overrides: {},
};
describe("本地资料边界", () => {
  it("刷新学校课表保留手动修改和删除", () => {
    const modified = { ...course, room: "B2" };
    expect(
      mergeCourses([{ ...course, room: "C3" }], { "school:1": modified })[0]
        .room,
    ).toBe("B2");
    expect(mergeCourses([course], { "school:1": null })).toEqual([]);
  });
  it("单双周不同不会误报冲突", () => {
    expect(
      courseConflicts(course, { ...course, id: "other", weeks: [2, 4] }),
    ).toBe(false);
    expect(
      courseConflicts(course, { ...course, id: "other", weeks: [3] }),
    ).toBe(true);
  });
  it("拒绝非法周次及逆序考试时间", () => {
    expect(() =>
      parseBackup(
        JSON.stringify({ ...backup, courses: [{ ...course, weeks: [0] }] }),
      ),
    ).toThrow();
    expect(() =>
      parseBackup(
        JSON.stringify({
          ...backup,
          exams: [
            {
              id: "1",
              name: "考试",
              startTime: "2026-09-20T12:00",
              endTime: "2026-09-20T11:00",
            },
          ],
        }),
      ),
    ).toThrow();
  });
  it("导入丢弃凭据和未知字段", () => {
    const parsed = parseBackup(
      JSON.stringify({
        ...backup,
        password: "private",
        courses: [{ ...course, cookie: "private" }],
      }),
    );
    expect(JSON.stringify(parsed)).not.toContain("private");
  });
  it("兼容 App 导出的课程块数组", () => {
    const parsed = parseBackup(JSON.stringify([{
      id: 12,
      course_code: "CS101",
      name: "程序设计",
      teacher: "张老师",
      location: "明德楼 101",
      weekday: 2,
      start_section: 3,
      end_section: 4,
      weeks: [1, 3, 5],
      source: "school",
    }]));
    expect(parsed.courses).toHaveLength(1);
    expect(parsed.courses[0]).toMatchObject({ id: "12", day: 2, periods: [3, 4], weeks: [1, 3, 5] });
    expect(JSON.stringify(parsed)).not.toContain("source");
  });
  it("没有成绩时不产生虚假零绩点", () => {
    expect(gradeStats([])).toEqual({ average: null, gpa: null, credits: 0 });
  });
  it("桥接拒绝脚本执行和任意请求命令", () => {
    expect(
      isBridgeRequest({
        channel: "sylulive-academic-v1",
        direction: "request",
        version: 1,
        id: "1",
        operation: "fetch",
        payload: { url: "https://example.com" },
      }),
    ).toBe(false);
  });
});
describe("默认学年学期", () => {
  const at = (year: number, month: number, day: number) =>
    defaultAcademicTerm(new Date(year, month - 1, day));
  it("秋季学期归属开学当年的学年", () => {
    expect(at(2026, 9, 7)).toEqual({ year: "2026", semester: "3" });
    expect(at(2026, 12, 31)).toEqual({ year: "2026", semester: "3" });
  });
  it("一月仍在上一年的秋季学期内", () => {
    expect(at(2027, 1, 1)).toEqual({ year: "2026", semester: "3" });
    expect(at(2027, 1, 31)).toEqual({ year: "2026", semester: "3" });
  });
  it("二月到八月是上一学年的春季学期", () => {
    expect(at(2027, 2, 1)).toEqual({ year: "2026", semester: "12" });
    expect(at(2027, 8, 31)).toEqual({ year: "2026", semester: "12" });
  });
});
describe("桥接失败码", () => {
  it("保留码位不丢消息", () => {
    const failure = new BridgeFailure("authorization_required", "请在助手页面授予学校域名权限");
    expect(failure).toBeInstanceOf(Error);
    expect(failure.message).toBe("请在助手页面授予学校域名权限");
    expect(bridgeErrorCode(failure)).toBe("authorization_required");
    expect(bridgeErrorCode(new Error("普通异常"))).toBeUndefined();
  });
  it("旧版扩展的未知码收窄为失败而不是猜一个分类", () => {
    expect(isBridgeErrorCode("academic_failed")).toBe(false);
    expect(isBridgeErrorCode("identity_changed")).toBe(true);
  });
});
