import { describe, expect, it } from "vitest";
import { userLevel } from "./user-level";

describe("与 Android App 一致的经验等级", () => {
  it.each([
    [-1, 1], [0, 1], [49, 1], [50, 2], [149, 2], [150, 3], [499, 3],
    [500, 4], [999, 4], [1000, 5], [2499, 5], [2500, 6], [4999, 6],
    [5000, 7], [5432, 7], [7999, 7], [8000, 8], [100000, 8],
  ])("经验 %i 对应 Lv.%i", (exp, level) => {
    expect(userLevel({ exp })).toBe(level);
  });

  it("优先用真实经验计算，包括零经验，不采用陈旧等级", () => {
    expect(userLevel({ exp: 5432, level: 1 })).toBe(7);
    expect(userLevel({ exp: 0, level: 7 })).toBe(1);
  });

  it("兼容仅有等级的旧资料和帖子，同时对缺失或无效值安全回退", () => {
    expect(userLevel({ level: 6 })).toBe(6);
    expect(userLevel(undefined, 4)).toBe(4);
    expect(userLevel({ exp: null, level: 3 })).toBe(3);
    expect(userLevel({ exp: NaN, level: 2 })).toBe(2);
    expect(userLevel({ level: 20 })).toBe(8);
    for (const value of [undefined, null, -1, 0, NaN, Infinity, 2.5, "7"]) {
      expect(userLevel({ level: value })).toBe(1);
    }
  });
});
