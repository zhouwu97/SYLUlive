import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { bridgeErrorCode } from "@sylulive/academic-contracts";
import { identity } from "./school";

// 只保留学校顶部栏的结构；账号为合成值，不使用真实学校资料。
const topPage = (accounts = ["2099000001"]) => `<html><body>
  <a href="ExitWindows.aspx">退出系统</a>
  <div style="background-image:url(FrameImages/EmailBJ.jpg)">
    ${accounts.map((id) => `<div>${id}</div>`).join("")}
  </div><div>2026-11-3 星期二</div>
</body></html>`;

beforeEach(() => {
  vi.stubGlobal("chrome", { tabs: { query: vi.fn().mockResolvedValue([]) } });
});
afterEach(() => vi.unstubAllGlobals());

function schoolResponse(html: string) {
  const request = vi.fn().mockResolvedValue({
    ok: true,
    status: 200,
    url: "https://webvpn.sylu.edu.cn/http/school/SyluTW/Sys/SystemForm/top.aspx",
    headers: new Headers({ "content-type": "text/html; charset=utf-8" }),
    arrayBuffer: async () => new TextEncoder().encode(html).buffer,
  });
  vi.stubGlobal("fetch", request);
  return request;
}

it("从顶部栏读取二课身份，不再要求没有学号的成绩页提供身份", async () => {
  const request = schoolResponse(topPage());
  await expect(identity("erke")).resolves.toEqual({
    studentId: "2099000001",
    displayName: "",
  });
  expect(request.mock.calls[0][0]).toMatch(/\/SystemForm\/top\.aspx$/);
  expect(request.mock.calls[0][1].credentials).toBe("include");
});

it("换号后的下一次身份核验必须读到新账号，不能缓存旧身份", async () => {
  schoolResponse(topPage());
  expect((await identity("erke")).studentId).toBe("2099000001");
  schoolResponse(topPage(["2099000002"]));
  expect((await identity("erke")).studentId).toBe("2099000002");
});

it.each([
  ["登录页", '<html><body><input name="UserNo" value="2099000001"><input type="password" name="UserPass"></body></html>'],
  ["未登录的顶部栏", topPage([])],
  ["没有退出入口的数字", "<html><body><div>2099000001</div></body></html>"],
  ["多个账号候选", topPage(["2099000001", "2099000002"])],
  ["只有成绩与学号文字", "<html><body>学号：2099000001<span id=SunCount1>50</span></body></html>"],
])("%s不能冒充已确认的二课身份", async (_label, html) => {
  schoolResponse(html);
  const error = await identity("erke").then(() => null, (e) => e);
  expect(bridgeErrorCode(error)).toBe("school_login_required");
});
