import { describe, it, expect } from "vitest";
import {
  parseBackup,
  mergeCourses,
  courseConflicts,
  gradeStats,
  isBridgeRequest,
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
