import { beforeEach, describe, expect, it } from "vitest";
import { clearDismissed, dismissalFor, feedSourceOf, markDismissed, resetDismissalsForTest } from "./feed-feedback";

describe("feed-feedback", () => {
  beforeEach(() => resetDismissalsForTest());

  it("只接受服务端允许的来源，热门等其他入口按推荐记录", () => {
    expect(feedSourceOf("time")).toBe("time");
    expect(feedSourceOf("following")).toBe("following");
    expect(feedSourceOf("featured")).toBe("featured");
    expect(feedSourceOf("hot")).toBe("all");
    expect(feedSourceOf(undefined)).toBe("all");
  });

  it("不感兴趣只把被标记的帖子换成撤销条", () => {
    markDismissed(3, { kind: "post", postId: 10 });
    expect(dismissalFor(3, 10, 7)).toMatchObject({ mode: "placeholder" });
    expect(dismissalFor(3, 11, 7)).toEqual({ mode: "visible" });
    clearDismissed(3, { kind: "post", postId: 10 });
    expect(dismissalFor(3, 10, 7)).toEqual({ mode: "visible" });
  });

  it("不看 TA 在原帖留撤销条，同作者其他帖子直接隐藏", () => {
    markDismissed(3, { kind: "author", authorId: 7, postId: 10, authorName: "林同学" });
    expect(dismissalFor(3, 10, 7)).toMatchObject({ mode: "placeholder" });
    expect(dismissalFor(3, 12, 7)).toEqual({ mode: "hidden" });
    expect(dismissalFor(3, 13, 8)).toEqual({ mode: "visible" });
  });

  it("账号切换或未登录时不沿用上一个账号的本地标记", () => {
    markDismissed(3, { kind: "post", postId: 10 });
    expect(dismissalFor(4, 10, 7)).toEqual({ mode: "visible" });
    expect(dismissalFor(null, 10, 7)).toEqual({ mode: "visible" });
    markDismissed(4, { kind: "post", postId: 20 });
    expect(dismissalFor(4, 10, 7)).toEqual({ mode: "visible" });
    expect(dismissalFor(3, 20, 7)).toEqual({ mode: "visible" });
  });
});
