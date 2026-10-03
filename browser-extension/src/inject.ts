// 扩展安装或更新前就已打开的页面不会自动获得 content script，
// 装好后由扩展按站点匹配模式主动补注入 relay，页面不必刷新即可继续握手。
export function planRelayInjection(hostPermissions: string[] = []): string[] {
  return [...new Set(hostPermissions)].filter((pattern) =>
    /^https?:\/\//.test(pattern),
  );
}

export function installSelfHealingInjection() {
  chrome.runtime.onInstalled.addListener(
    async ({ reason }: { reason: string }) => {
      if (reason !== "install" && reason !== "update") return;
      for (const pattern of planRelayInjection(
        chrome.runtime.getManifest().host_permissions ?? [],
      )) {
        let tabs: chrome.tabs.Tab[] = [];
        try {
          tabs = await chrome.tabs.query({ url: pattern });
        } catch {
          continue;
        }
        for (const tab of tabs) {
          if (tab.id === undefined) continue;
          try {
            await chrome.scripting.executeScript({
              target: { tabId: tab.id, frameIds: [0] },
              files: ["relay.js"],
            });
          } catch {
            // 浏览器内置页、无权限页等无法注入的标签页直接跳过。
          }
        }
      }
    },
  );
}
