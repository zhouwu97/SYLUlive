import { describe, expect, it } from "vitest";
import type { AcademicSnapshot } from "@sylulive/academic-contracts";
import { makePersonalUpload } from "./integration-personal-sync";

const base: AcademicSnapshot = {
  version: 1, provider: "undergraduate", studentId: "not-to-upload", dataset: "grades",
  term: { year: "2026", semester: "3" }, fetchedAt: "2026-11-01T00:00:00Z", parserVersion: 1,
  data: [{ id: "internal-id", name: "合成课程", score: "优秀", credit: 2, gpa: null, nature: "选修", term: "school-term", password: "never-forward" }],
};
describe("个人资料最小同步", () => {
  it("只投影当前学期课程字段，不传学校账号、原始记录或凭据", () => {
    const payload = makePersonalUpload(base);
    expect(payload).toEqual({ consent: true, fetched_at: base.fetchedAt, year: "2026", semester: 3, grades: [{ course_name: "合成课程", score: "优秀", credits: 2, course_nature: "选修" }] });
    expect(JSON.stringify(payload)).not.toMatch(/not-to-upload|internal-id|password|never-forward|school-term/);
  });
  it("二课只同步毕业总量和分类缺口，不编造学年或活动", () => {
    const payload = makePersonalUpload({ ...base, provider: "erke", dataset: "erke", data: { earned: 8, required: 10, categories: [{ name: "志愿公益", earned: 1, required: 4 }], cookie: "not-to-upload" } });
    expect(payload).toMatchObject({ schema_version: 2, graduation: { graduation_gap: 3, unmet_categories: [{ name: "志愿公益", gap: 3 }] }, yearly: {}, recent_activities: [] });
    expect(JSON.stringify(payload)).not.toMatch(/cookie|not-to-upload/);
  });
  it("错误类型不能当作已经同步", () => {
    expect(() => makePersonalUpload({ ...base, data: {} })).toThrow();
    expect(() => makePersonalUpload({ ...base, dataset: "physical" })).toThrow();
  });
  it("分类缺口与合计按学校百分位精度同步，不暴露浮点减法尾差", () => {
    const payload = makePersonalUpload({ ...base, provider: "erke", dataset: "erke", data: {
      earned: 100, required: 100, categories: [
        { name: "合成分类 A", earned: 0.1, required: 0.3 },
        { name: "合成分类 B", earned: 0.1, required: 0.2 },
      ],
    } });
    expect(payload.graduation).toEqual({ earned_total: 100, required_total: 100, graduation_gap: 0.3,
      unmet_categories: [{ name: "合成分类 A", gap: 0.2 }, { name: "合成分类 B", gap: 0.1 }] });
  });
});
