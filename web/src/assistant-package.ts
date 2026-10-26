export type AssistantChannel = "production" | "development";
export type AssistantPackage = {
  channel: AssistantChannel;
  extensionVersion: string;
  fileName: string;
  bytes: number;
  sha256: string;
  builtAt: string;
  sites: string[];
};
export type AssistantAvailability =
  | "ok"
  | "wrong-channel"
  | "host-not-covered"
  | "unavailable";

const versionShape = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
const hashShape = /^[0-9a-f]{64}$/;
// fileName 会拼进下载 URL，因此只允许安全字符，且必须排除 "." 与 ".."。
const fileNameShape = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const maxBytes = 20 * 1024 * 1024;

export function parseAssistantPackage(value: unknown): AssistantPackage | null {
  if (!value || typeof value !== "object") return null;
  const pkg = value as Record<string, unknown>;
  if (pkg.channel !== "production" && pkg.channel !== "development") return null;
  if (typeof pkg.extensionVersion !== "string" || !versionShape.test(pkg.extensionVersion))
    return null;
  if (
    typeof pkg.fileName !== "string" ||
    !fileNameShape.test(pkg.fileName) ||
    pkg.fileName.includes("..")
  )
    return null;
  if (
    typeof pkg.bytes !== "number" ||
    !Number.isFinite(pkg.bytes) ||
    pkg.bytes <= 0 ||
    pkg.bytes > maxBytes
  )
    return null;
  if (typeof pkg.sha256 !== "string" || !hashShape.test(pkg.sha256)) return null;
  if (typeof pkg.builtAt !== "string" || Number.isNaN(Date.parse(pkg.builtAt))) return null;
  if (!Array.isArray(pkg.sites) || !pkg.sites.every((site) => typeof site === "string"))
    return null;
  return {
    channel: pkg.channel,
    extensionVersion: pkg.extensionVersion,
    fileName: pkg.fileName,
    bytes: pkg.bytes,
    sha256: pkg.sha256,
    builtAt: pkg.builtAt,
    sites: pkg.sites as string[],
  };
}

export function channelForHostname(hostname: string): AssistantChannel {
  return ["localhost", "127.0.0.1", "[::1]", "::1"].includes(hostname)
    ? "development"
    : "production";
}

function patternCovers(pattern: string, site: URL): boolean {
  const match = /^(https?):\/\/([^/]*)\/?\*$/.exec(pattern);
  if (!match) return false;
  return (
    match[1] === site.protocol.slice(0, -1) &&
    match[2].toLowerCase() === site.host.toLowerCase()
  );
}

export function assistantAvailability(
  pkg: AssistantPackage | null,
  { origin }: { origin: string },
): AssistantAvailability {
  if (!pkg) return "unavailable";
  let site: URL;
  try {
    site = new URL(origin);
  } catch {
    return "unavailable";
  }
  // 装一个不授权本站的包，握手永远不通，比通道标签不符更直接。
  if (!pkg.sites.some((pattern) => patternCovers(pattern, site))) return "host-not-covered";
  return pkg.channel === channelForHostname(site.hostname) ? "ok" : "wrong-channel";
}

export function extensionsPageForUserAgent(userAgent: string): string {
  return /\bEdg[\/]/i.test(userAgent) ? "edge://extensions" : "chrome://extensions";
}

export function buildInstallSteps(extensionsPage: string): string[] {
  return [
    "下载教务助手安装包（zip）。",
    "解压到固定位置，解压后不要移动、重命名或删除 sylulive-assistant 目录。",
    `在浏览器地址栏输入 ${extensionsPage} 并回车。`,
    "打开「开发者模式」开关。",
    "点「加载已解压的扩展程序」，选择 sylulive-assistant 目录。",
    "回到本页点「重新检测」，助手连上后即可继续，不必刷新页面。",
  ];
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  return kb < 1024 ? `${kb.toFixed(0)} KB` : `${(kb / 1024).toFixed(1)} MB`;
}

export function shortHash(hash: string): string {
  return hash.length <= 20 ? hash : `${hash.slice(0, 8)}…${hash.slice(-8)}`;
}
