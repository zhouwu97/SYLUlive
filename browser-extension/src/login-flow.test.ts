import { afterEach, expect, it, vi } from "vitest";
import { assertFlowOwner, cancelLoginFlows, readLoginFlow, writeLoginFlow, isAssistantTab, type LoginFlow } from "./login-flow";
const flow: LoginFlow = { flowId: "00000000-0000-4000-8000-000000000001", state: "awaiting_login", origin: "https://sylulive.online", appUserId: 7, provider: "erke", returnTabId: 3, assistantTabId: 4, expiresAt: Date.now() + 60_000 };
afterEach(() => vi.unstubAllGlobals());
it('Chrome 省略扩展标签 URL 时使用绑定页心跳，已导航和过期心跳不能继续',()=>{
  const expected='chrome-extension://test/assistant.html';
  expect(isAssistantTab({...flow,lastSeen:1000},{},expected,2000)).toBe(true);
  expect(isAssistantTab({...flow,lastSeen:1000},{},expected,32000)).toBe(false);
  expect(isAssistantTab(flow,{url:'about:blank',pendingUrl:expected},expected)).toBe(true);
  expect(isAssistantTab(flow,{url:flow.origin+'/web/grades'},expected)).toBe(false);
});
it("登录回跳只接受原站点、账号、标签页和系统", () => {
  expect(() => assertFlowOwner(flow, flow.origin, 7, 3, "erke")).not.toThrow();
  for (const args of [["https://other.example", 7, 3, "erke"], [flow.origin, 8, 3, "erke"], [flow.origin, 7, 4, "erke"], [flow.origin, 7, 3, "undergraduate"]] as const)
    expect(() => assertFlowOwner(flow, args[0], args[1], args[2], args[3])).toThrow("账号或连接页面已改变");
});
it("新连接取消旧任务，过期和伪造 ID 不能完成登录", async () => {
  let stored: Record<string, unknown> = {};
  vi.stubGlobal("chrome", { storage: { session: {
    get: vi.fn(async () => ({ ...stored })), set: vi.fn(async (data) => { stored = { ...stored, ...data }; }),
    remove: vi.fn(async (key) => { delete stored[key]; }),
  } } });
  await writeLoginFlow(flow);
  await expect(readLoginFlow(flow.flowId)).resolves.toMatchObject({ state: "awaiting_login" });
  await cancelLoginFlows(flow.origin, "undergraduate");
  await expect(readLoginFlow(flow.flowId)).resolves.toBeDefined();
  await cancelLoginFlows(flow.origin, "erke", 8);
  await expect(readLoginFlow(flow.flowId)).resolves.toBeDefined();
  await cancelLoginFlows(flow.origin, "erke");
  await expect(readLoginFlow(flow.flowId)).rejects.toThrow("取消或过期");
  await writeLoginFlow({ ...flow, expiresAt: 0 });
  await expect(readLoginFlow(flow.flowId)).rejects.toThrow("取消或过期");
  await expect(readLoginFlow("../../other")).rejects.toThrow("登录任务无效");
});
