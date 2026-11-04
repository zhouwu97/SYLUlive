import { useEffect, useRef, useState, type FormEvent } from "react";
import { ApiError, captureAuthSession, entity, errorText, request } from "./api";
import { useAuth } from "./auth";

export function PasswordReauthentication({ onVerified, onCancel }: {
  onVerified: () => Promise<unknown>;
  onCancel: () => void;
}) {
  const auth = useAuth(),
    [password, setPassword] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [expired, setExpired] = useState(false),
    active = useRef<AbortController | null>(null),
    mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; active.current?.abort(); };
  }, []);
  function cancel() {
    active.current?.abort();
    active.current = null;
    setPassword(""); setError(""); setBusy(false);
    onCancel();
  }
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (active.current || !password || !auth.user) return;
    const controller = new AbortController(), current = captureAuthSession(), userId = auth.user.id;
    active.current = controller;
    setBusy(true); setError(""); setExpired(false);
    const submittedPassword = password;
    setPassword("");
    const valid = () => mounted.current && current() && !controller.signal.aborted;
    try {
      // 先通过普通读取静默恢复过期的访问Cookie，再核对仍是页面上的同一个账号。
      const profile = entity(await request("/api/user/profile", { signal: controller.signal }), "user", "data");
      if (!valid() || profile.id !== userId) throw new ApiError(409, "auth_session_changed", "账号已切换，请重新核对当前账号");
      await request("/api/auth/reauthenticate", {
        method: "POST", signal: controller.signal,
        body: JSON.stringify({ password: submittedPassword, expected_user_id: userId }),
      });
      if (valid()) await onVerified();
    } catch (cause) {
      if (valid()) {
        setExpired(cause instanceof ApiError && cause.status === 401);
        setError(cause instanceof ApiError && cause.status === 404
          ? "当前服务尚未支持页内密码验证，请联系维护者完成更新。"
          : errorText(cause));
      }
    } finally {
      if (active.current === controller) {
        active.current = null;
        if (mounted.current) setBusy(false);
      }
    }
  }
  return <form className="reauthentication-form" onSubmit={submit} aria-label="验证当前账号身份">
    <p>验证账号：<strong>{auth.user?.nickname}</strong>。这一步只确认身份，不会授予权限或启动机器人。</p>
    <label className="field">当前账号密码
      <input type="password" name="password" autoComplete="current-password" required maxLength={128}
        value={password} onChange={event => setPassword(event.target.value)} disabled={busy} autoFocus />
    </label>
    <p className="muted">请输入 SYLUlive 账号密码，不是学校教务密码。</p>
    <p className="muted">验证后 30 分钟内，当前登录会话的助手授权与机器人管理可连续操作，无需反复输入。权限选择会保留，批准仍需你确认。</p>
    {error && <p role="alert">{error}</p>}
    <div className="form-actions">
      <button className="btn primary" disabled={busy || !password}>{busy ? "正在验证…" : "验证并继续"}</button>
      <button className="btn" type="button" onClick={cancel}>取消验证</button>
      {expired && <button className="btn" type="button" onClick={auth.login}>登录状态已失效，重新登录</button>}
    </div>
  </form>;
}
