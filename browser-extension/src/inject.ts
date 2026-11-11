// 已打开的页面在安装、重载或重新启用扩展后补回本地握手通道。
export function planRelayInjection(hostPermissions: string[] = []): string[] {
  return [...new Set(hostPermissions)].filter((pattern) =>
    /^https?:\/\//.test(pattern),
  );
}

export async function injectExistingSiteTabs() {
  for (const pattern of planRelayInjection(chrome.runtime.getManifest().host_permissions ?? [])) {
    let tabs: chrome.tabs.Tab[] = [];
    try {
      tabs = await chrome.tabs.query({url: pattern});
    } catch {
      continue;
    }
    for (const tab of tabs) {
      if (tab.id === undefined) continue;
      try {
        await chrome.scripting.executeScript({target: {tabId: tab.id, frameIds: [0]}, files: ['relay.js']});
      } catch {
        // 浏览器内置页、无权限页等无法注入的标签页直接跳过。
      }
    }
  }
}

export function installSelfHealingInjection() {
  let pending: Promise<void> | undefined;
  const inject = () => {
    pending ??= injectExistingSiteTabs().catch(() => undefined).finally(() => { pending = undefined; });
    return pending;
  };
  chrome.runtime.onInstalled.addListener(({reason}) => {
    if (reason === 'install' || reason === 'update') void inject();
  });
  chrome.runtime.onStartup.addListener(() => { void inject(); });
  // 重新启用不会触发 onInstalled；每次 worker 启动只按 manifest 允许的域补注入。
  void inject();
}
