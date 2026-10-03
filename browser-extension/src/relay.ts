import { isBridgeRequest, BRIDGE_CHANNEL } from "@sylulive/academic-contracts";

if (window === window.top) {
  // manifest 注入与扩展主动补注入共用同一个隔离世界，用标记保证只监听一次。
  const marker = "__syluliveAssistantRelay";
  const relayId = `${chrome.runtime.id}:${chrome.runtime.getManifest().version}`;
  const scoped = window as unknown as { [marker]?: string };
  if (scoped[marker] !== relayId) {
    scoped[marker] = relayId;
    window.addEventListener("message", async (event) => {
      if (
        event.source !== window ||
        event.origin !== location.origin ||
        !isBridgeRequest(event.data)
      )
        return;
      const req = event.data;
      try {
        const response = await chrome.runtime.sendMessage(req);
        window.postMessage(response, location.origin);
      } catch {
        // 扩展重新加载后旧隔离世界已失效，此时保持沉默，让新注入的 relay 应答，
        // 避免失效的 relay 抢先回「不可用」把可用状态误判成失败。
        if (!chrome.runtime?.id) return;
        window.postMessage(
          {
            channel: BRIDGE_CHANNEL,
            direction: "response",
            version: 1,
            id: req.id,
            ok: false,
            error: {
              code: "extension_unavailable",
              message: "教务助手已更新或不可用，请刷新页面",
            },
          },
          location.origin,
        );
      }
    });
  }
}
