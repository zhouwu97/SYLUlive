import { useState, type ReactNode } from "react";
import { asset } from "./api";
import { displayName } from "./user-level";

// 失败只绑定当前 URL，服务端更新头像或切换账号后立即尝试新资源。
export function ServerAvatar({ src, name, fallback }: { src?: unknown; name: string; fallback?: ReactNode }) {
  const url = asset(src);
  const label = displayName(name, "同");
  const [failed, setFailed] = useState<string>();
  return url && failed !== url
    ? <img key={url} className="server-avatar" src={url} alt={`${label}的头像`} decoding="async" onError={() => setFailed(url)} />
    : <span className="server-avatar-fallback" role="img" aria-label={`${label}的头像`}>{fallback || Array.from(label)[0] || "同"}</span>;
}
