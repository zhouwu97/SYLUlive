import { describe, expect, it } from "vitest";
import { canteenGovernanceReasons, reportHandlePayload, reportNote, reportPreview, reportReasonLabel, reportSnapshot, reportTargetHref, reportTargetLabel } from "./report-labels";

// 管理端举报列表原先直接显示 porn / spam 等原因码；这里固定中文映射和快照摘要规则。
describe("举报展示标签", () => {
  it("原因码转中文，旧数据把码存进自由文本时也能识别", () => {
    expect(reportReasonLabel("porn", "porn")).toBe("色情低俗");
    expect(reportReasonLabel("", "spam")).toBe("垃圾广告");
    expect(reportReasonLabel("unknown", "自己写的原因")).toBe("自己写的原因");
    expect(reportReasonLabel("", "")).toBe("未注明原因");
  });

  it("只在举报人写了额外说明时展示说明", () => {
    expect(reportNote("porn", "porn")).toBe("");
    expect(reportNote("", "fake")).toBe("");
    expect(reportNote("spam", "一直发广告")).toBe("一直发广告");
  });

  it("快照兼容 JSON 字符串和损坏数据", () => {
    expect(reportSnapshot('{"title":"帖子"}')).toEqual({ title: "帖子" });
    expect(reportSnapshot("{坏数据")).toBeNull();
    expect(reportSnapshot("")).toBeNull();
  });

  it("摘要包含标题、评分、正文和图片数", () => {
    expect(reportPreview("post", { title: "周末去哪", content: "正文" })).toBe("周末去哪 · 正文");
    expect(reportPreview("canteen_dish_review", { overall_score: 1, comment: "难吃", image_file_ids: [1, 2] })).toBe("评分：1 · 难吃 · [含 2 张图片]");
    expect(reportPreview("post", null)).toBe("");
  });

  it("只有帖子和带帖子编号的评论能打开原内容", () => {
    expect(reportTargetLabel("reply")).toBe("评论");
    expect(reportTargetLabel("whatever")).toBe("内容");
    expect(reportTargetHref("post", 8, null)).toBe("/post/8");
    expect(reportTargetHref("reply", 30, { post_id: 8 })).toBe("/post/8");
    expect(reportTargetHref("reply", 30, null)).toBe("");
    expect(reportTargetHref("canteen_review", 3, null)).toBe("");
  });

  // 服务端确认违规要求 delete_reason，食堂内容还要求 confirmed_reason_code；
  // 旧 Web 只发 result 和 action=warn，确认违规必然被拒（governance_reason_required）。
  describe("举报处理请求体", () => {
    const base = { result: "  ", governanceReason: "", confirmedReasonCode: "" };
    it("忽略只带备注", () => {
      expect(reportHandlePayload("post", { ...base, status: "ignored", result: " 不成立 " })).toEqual({ status: "ignored", result: "不成立" });
    });
    it("确认违规必须有治理原因，并写入 delete_reason，不再强制 warn", () => {
      expect(() => reportHandlePayload("post", { ...base, status: "handled", governanceReason: "  " })).toThrow("治理原因");
      const body = reportHandlePayload("reply", { ...base, status: "handled", governanceReason: " 辱骂 " });
      expect(body).toEqual({ status: "handled", result: "", delete_reason: "辱骂" });
      expect(body).not.toHaveProperty("action");
    });
    it("食堂内容必须选择该类型允许的确认原因", () => {
      const handled = { ...base, status: "handled" as const, governanceReason: "盗图" };
      expect(() => reportHandlePayload("canteen_dish_photo", handled)).toThrow("确认原因");
      expect(() => reportHandlePayload("canteen_dish_photo", { ...handled, confirmedReasonCode: "fake_dish" })).toThrow("确认原因");
      expect(reportHandlePayload("canteen_dish_photo", { ...handled, confirmedReasonCode: "stolen_photo" }))
        .toEqual({ status: "handled", result: "", delete_reason: "盗图", confirmed_reason_code: "stolen_photo" });
    });
    it("确认原因范围与服务端一致", () => {
      expect(canteenGovernanceReasons("canteen_dish_review").map(([c]) => c)).toContain("fake_dish");
      expect(canteenGovernanceReasons("canteen_review").map(([c]) => c)).not.toContain("fake_dish");
      expect(canteenGovernanceReasons("post")).toEqual([]);
    });
  });
});
