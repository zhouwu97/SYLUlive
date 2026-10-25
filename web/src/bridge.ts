import {
  BRIDGE_CHANNEL,
  PROTOCOL_VERSION,
  type BridgeOperation,
  type BridgeResponse,
} from "@sylulive/academic-contracts";
export function bridge<T = unknown>(
  operation: BridgeOperation,
  payload: Record<string, unknown> = {},
  signal?: AbortSignal,
): Promise<T> {
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () =>
        finish(
          new Error(
            operation === "hello"
              ? "未检测到教务助手，请先安装并刷新页面"
              : "本地请求超时，请检查学校登录状态",
          ),
        ),
      operation === "hello" ? 1800 : 60000,
    );
    function finish(error?: Error, result?: unknown) {
      clearTimeout(timer);
      window.removeEventListener("message", receive);
      signal?.removeEventListener("abort", cancel);
      error ? reject(error) : resolve(result as T);
    }
    function receive(e: MessageEvent) {
      const d = e.data as BridgeResponse;
      if (
        e.source !== window ||
        e.origin !== location.origin ||
        d?.channel !== BRIDGE_CHANNEL ||
        d.direction !== "response" ||
        d.version !== PROTOCOL_VERSION ||
        d.id !== id
      )
        return;
      finish(
        d.ok ? undefined : new Error(d.error?.message || "教务助手未完成请求"),
        d.result,
      );
    }
    function cancel() {
      window.postMessage(
        {
          channel: BRIDGE_CHANNEL,
          direction: "request",
          version: 1,
          id: crypto.randomUUID(),
          operation: "cancel",
          payload: { requestId: id },
        },
        location.origin,
      );
      finish(new Error("请求已取消"));
    }
    window.addEventListener("message", receive);
    signal?.addEventListener("abort", cancel, { once: true });
    if (signal?.aborted) {
      cancel();
      return;
    }
    window.postMessage(
      {
        channel: BRIDGE_CHANNEL,
        direction: "request",
        version: PROTOCOL_VERSION,
        id,
        operation,
        payload,
      },
      location.origin,
    );
  });
}
