import { describe, expect, it } from "vitest";
import { ticketListHREF, ticketRowHREF } from "./feedback";

// 管理端工单列表不是独立路由，而是 /admin 的 feedback 标签页；
// 详情页又是另一条路由，筛选条件必须由地址自己带上，否则返回必然丢状态。
describe("工单列表与详情的地址传递", () => {
  it("进详情时把列表筛选条件带在地址上", () => {
    expect(ticketRowHREF(true, 12, "?status=pending&page=2")).toBe(
      "/admin/feedback/12?status=pending&page=2",
    );
    expect(ticketRowHREF(false, 12, "?status=resolved&page=3")).toBe(
      "/feedback/12?status=resolved&page=3",
    );
    expect(ticketRowHREF(false, 12, "")).toBe("/feedback/12");
  });

  it("返回列表时落回带筛选的管理端标签页", () => {
    expect(ticketListHREF(true, "?status=pending&page=2")).toBe(
      "/admin?status=pending&page=2&tab=feedback",
    );
    // 没有筛选参数时也要显式选中工单标签，不能停在默认的其它队列上。
    expect(ticketListHREF(true, "")).toBe("/admin?tab=feedback");
    expect(ticketListHREF(false, "?status=pending&page=2")).toBe(
      "/feedback?status=pending&page=2",
    );
  });

  it("详情地址上的 tab 参数不会把返回地址指向不存在的路由", () => {
    // 通知里跳来的地址可能带 tab，返回时以列表地址为准重新拼一次：
    // tab 保留在原位，且无论输入如何都只会落到 /admin 这条真实路由。
    expect(ticketListHREF(true, "?tab=feedback&page=4")).toBe(
      "/admin?tab=feedback&page=4",
    );
    expect(ticketListHREF(true, "?tab=logs&page=4")).toBe(
      "/admin?tab=feedback&page=4",
    );
  });
});
