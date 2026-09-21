import { isBridgeRequest, BRIDGE_CHANNEL } from "@sylulive/academic-contracts";
if (window === window.top) {
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
