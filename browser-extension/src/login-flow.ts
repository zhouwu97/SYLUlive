import { BridgeFailure, type AcademicProvider, type AssistantLoginFlow } from "@sylulive/academic-contracts";

export type LoginFlow = AssistantLoginFlow & {
  origin: string;
  appUserId: number;
  provider: AcademicProvider;
  returnTabId: number;
  assistantTabId?: number;
  expiresAt: number;
  requestId?: string;
  lastSeen?: number;
};
export const loginFlowTtl = 5 * 60_000;
export function isAssistantTab(flow: LoginFlow, tab: {url?: string; pendingUrl?: string}, expectedUrl: string, now = Date.now()) {
  if (tab.url === expectedUrl || tab.pendingUrl === expectedUrl) return true;
  if (tab.url !== undefined || tab.pendingUrl !== undefined) return false;
  // 没有 tabs 权限时，Chrome 对扩展页面省略 URL。使用绑定助手页的心跳，
  // 不为判断一个标签是否存活扩大到读取全部浏览记录的权限。
  return now - (flow.lastSeen ?? flow.expiresAt - loginFlowTtl) < 30_000;
}
const key = (id: string) => `login-flow:${id}`;
export async function readLoginFlow(id: unknown, allowInactive = false): Promise<LoginFlow> {
  if (typeof id !== "string" || !/^[\da-f-]{36}$/i.test(id))
    throw new BridgeFailure("invalid_argument", "登录任务无效，请重新发起连接");
  const flow = (await chrome.storage.session.get(key(id)))[key(id)] as LoginFlow | undefined;
  if (!flow || (!allowInactive && (flow.expiresAt < Date.now() || flow.state === "cancelled")))
    throw new BridgeFailure("connection_stale", "登录任务已取消或过期，请重新连接");
  return flow;
}
export async function writeLoginFlow(flow: LoginFlow) {
  await chrome.storage.session.set({ [key(flow.flowId)]: flow });
}
export async function cancelLoginFlows(origin: string, provider: AcademicProvider, appUserId?: number) {
  const stored = await chrome.storage.session.get(null);
  for (const [id, value] of Object.entries(stored)) {
    if (!id.startsWith("login-flow:")) continue;
    const flow = value as LoginFlow;
    if (flow.expiresAt < Date.now()) await chrome.storage.session.remove(id);
    else if (flow.origin === origin && flow.provider === provider && (appUserId === undefined || flow.appUserId === appUserId))
      await writeLoginFlow({ ...flow, state: "cancelled" });
  }
}
export function assertFlowOwner(flow: LoginFlow, origin: string, appUserId: number, tabId: number, provider: AcademicProvider) {
  if (flow.origin !== origin || flow.appUserId !== appUserId || flow.returnTabId !== tabId || flow.provider !== provider)
    throw new BridgeFailure("connection_stale", "账号或连接页面已改变，请重新连接");
}
