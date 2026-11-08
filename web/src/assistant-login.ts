import { assistantLoginMessages, bridgeErrorCode, type AcademicProvider, type AssistantLoginFlow } from "@sylulive/academic-contracts";
import { bridge } from "./bridge";

export async function waitForSchoolLogin(provider: AcademicProvider, signal: AbortSignal, onProgress?: (message: string) => void, recoverSiteSession?: () => Promise<void>): Promise<boolean> {
  const flow = await bridge<Partial<AssistantLoginFlow>>("connect", { provider }, signal);
  // 旧助手仅返回 awaiting_login，保留原来的手动返回、重试入口。
  if (!flow.flowId) return false;
  let ready = false;
  let phase: string | undefined;
  try {
    const deadline = Date.now() + 5 * 60_000;
    while (!signal.aborted && Date.now() < deadline) {
      let result: AssistantLoginFlow;
      try { result = await bridge<AssistantLoginFlow>("loginStatus", { provider, flowId: flow.flowId }, signal); }
      catch (error) {
        if (!recoverSiteSession || signal.aborted || bridgeErrorCode(error) !== "site_login_required") throw error;
        await recoverSiteSession();
        result = await bridge<AssistantLoginFlow>("loginStatus", { provider, flowId: flow.flowId }, signal);
      }
      if (result.state === "ready") { ready = true; return true; }
      if (result.state === "cancelled") throw new Error("本次学校登录已取消，原资料已保留。");
      if (result.phase && result.phase !== phase && Object.hasOwn(assistantLoginMessages, result.phase)) {
        phase = result.phase;
        onProgress?.(assistantLoginMessages[result.phase]);
      }
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => { signal.removeEventListener("abort", abort); resolve(); }, 1000);
        function abort() { clearTimeout(timer); reject(new Error("请求已取消")); }
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) { signal.removeEventListener("abort", abort); abort(); }
      });
    }
    throw new Error("登录等待已超时或取消，原资料已保留，请重新连接。");
  } finally {
    // 取消只按任务 nonce 和原标签绑定，不依赖可能已经失效的本站 Cookie。
    if (!ready) await bridge("cancel", { flowId: flow.flowId }, AbortSignal.timeout(2000)).catch(() => undefined);
  }
}
