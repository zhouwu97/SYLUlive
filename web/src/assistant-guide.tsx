import { useEffect, useState } from "react";
import {
  assistantAvailability,
  buildInstallSteps,
  extensionsPageForUserAgent,
  formatBytes,
  parseAssistantPackage,
  shortHash,
  type AssistantPackage,
} from "./assistant-package";
import type { AssistantProbeState } from "./use-assistant-probe";
import { useUI } from "./ui";

async function loadAssistantPackage(): Promise<AssistantPackage | null> {
  try {
    const response = await fetch(`${import.meta.env.BASE_URL}assistant/assistant.json`, {
      cache: "no-store",
    });
    // 生产 nginx 的 try_files 会把缺失文件伪装成 200 + index.html，必须按内容类型判定。
    if (!response.ok || !(response.headers.get("content-type") || "").includes("json")) return null;
    return parseAssistantPackage(await response.json());
  } catch {
    return null;
  }
}

export function AssistantInstallGuide({
  state,
  onRecheck,
}: {
  state: AssistantProbeState;
  onRecheck: () => void;
}) {
  const ui = useUI();
  const [pkg, setPkg] = useState<AssistantPackage | null>(null),
    [loaded, setLoaded] = useState(false);
  useEffect(() => {
    let active = true;
    void loadAssistantPackage().then((value) => {
      if (!active) return;
      setPkg(value);
      setLoaded(true);
    });
    return () => {
      active = false;
    };
  }, []);
  if (state === "idle" || state === "ready") return null;
  if (state === "checking")
    return (
      <div className="assistant-guide">
        <p className="muted">正在检测本机教务助手…</p>
      </div>
    );
  const availability = assistantAvailability(pkg, { origin: location.origin });
  return (
    <div className="assistant-guide">
      <p className="muted">
        未检测到教务助手。浏览器不允许网页自行安装扩展，请下载后在扩展管理页加载；装好不必刷新，本页会自动复检。
      </p>
      {!loaded && <p className="muted">正在读取本站安装包信息…</p>}
      {loaded && availability === "ok" && pkg && (
        <>
          <a
            className="btn primary"
            href={`${import.meta.env.BASE_URL}assistant/${pkg.fileName}`}
            download={`sylulive-assistant-${pkg.extensionVersion}.zip`}
          >
            下载教务助手 v{pkg.extensionVersion}（{formatBytes(pkg.bytes)}）
          </a>
          <p className="tiny muted">
            SHA-256 <span className="mono">{shortHash(pkg.sha256)}</span>{" "}
            <button
              className="link-btn"
              onClick={() =>
                void ui.act(
                  () => navigator.clipboard.writeText(pkg.sha256),
                  "完整校验值已复制，可与发布记录核对",
                )
              }
            >
              复制完整校验值
            </button>
          </p>
          <ol className="assistant-steps">
            {buildInstallSteps(extensionsPageForUserAgent(navigator.userAgent)).map((step) => (
              <li key={step}>{step}</li>
            ))}
          </ol>
          <p className="tiny muted">
            解包安装的扩展身份由目录路径决定，换目录后本机已保存的教务资料不会跟过去；在扩展页把扩展从「停用」改成「启用」不会自动复检，仍需刷新一次。
          </p>
          <button className="btn" onClick={onRecheck}>
            重新检测
          </button>
        </>
      )}
      {loaded && availability !== "ok" && (
        <p className="notice-line">
          <b>本站暂无可用的教务助手安装包</b>
          <p>
            {availability === "unavailable"
              ? "安装包尚未构建或未随站点一起发布，请联系维护者获取。"
              : availability === "wrong-channel"
                ? "本站发布的安装包与当前访问地址不是同一环境，装载后无法与此页面握手。"
                : `本站安装包的授权站点不覆盖 ${location.origin}，请勿装载。`}
          </p>
        </p>
      )}
    </div>
  );
}
