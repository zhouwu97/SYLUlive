import { useEffect, useId, useRef, useState } from "react";
import { ApiError, captureAuthSession, useApi, write, time } from "./api";
import { Empty, QueryState } from "./ui";
import { integrationScopeLabels as labels, integrationScopeTitles as titles } from "./integration-scopes";
import "./integration-management.css";

type Binding = {
  binding_id: string; nickname: string; installation_name: string;
  state: string; scopes: string[]; epoch: number; created_at: string;
};
type Audit = { event: string; actor_id: number; reason: string; created_at: string };
const events: Record<string, string> = {
  authorized: "本人同意授权", revoked: "授权已撤销", daily_checkin: "本人签到",
  grades_read: "读取本人成绩", erke_read: "读取本人二课",
  admin_restricted: "管理员缩减权限", admin_revoked: "管理员撤销授权",
};

export function IntegrationManagement() {
  const [state, setState] = useState("active"), [page, setPage] = useState(1);
  const [audit, setAudit] = useState("");
  const [notice, setNotice] = useState("");
  const q = useApi<{ items: Binding[]; total: number; personal_data_enabled?: boolean }>(
    `/api/admin/integrations?state=${encodeURIComponent(state)}&page=${page}`,
  );
  const known = !q.isPending && !q.error && typeof q.data?.personal_data_enabled === "boolean";
  const pages = Math.max(1, Math.ceil((q.data?.total || 0) / 30));
  useEffect(() => {
    if (q.data && !q.error && page > pages) setPage(pages);
  }, [q.data, q.error, page, pages]);
  return <section className="integration-management" aria-label="助手授权管理">
    <header className="integration-heading">
      <div><h2>助手授权管理</h2><p className="integration-muted">管理各用户的连接与权限，保留每次处理记录。</p></div>
      <span className={`integration-badge ${known && q.data?.personal_data_enabled ? "is-active" : ""}`} role="status">
        个人查询{!known ? "状态未确认" : q.data?.personal_data_enabled ? "已开放" : "未开放"}
      </span>
    </header>
    <details className="integration-help">
      <summary>管理范围与隐私说明</summary>
      <p>只能缩减已有权限或撤销授权，恢复或新增权限需用户本人重新同意。这里不提供他人成绩、二课正文或凭证。</p>
      <p>安装名称由插件自报，其中的 QQ 号不构成服务端核验的身份。个人查询未开放时，调整用户授权也不能开启服务。</p>
    </details>
    {notice && <p className="integration-feedback is-success" role="status">{notice}</p>}
    <div className="integration-toolbar">
      <label className="integration-filter">授权状态 <select value={state} onChange={e => { setState(e.target.value); setPage(1); setAudit(""); setNotice(""); }}>
        <option value="active">有效</option><option value="revoked">已撤销</option><option value="">全部</option>
      </select></label>
      <button className="btn" disabled={q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在读取…" : "刷新列表"}</button>
      {!q.isPending && !q.error && <span className="integration-count">共 {q.data?.total ?? 0} 个授权</span>}
    </div>
    <QueryState query={q}>
      <div className="panel integration-bindings" aria-busy={q.isFetching}>
        {(q.data?.items || []).map(b => <article className="integration-binding" key={`${b.binding_id}:${b.epoch}`}>
          <div className="integration-binding-heading">
            <div><h3>{b.nickname || "未设置昵称"}</h3><p className="integration-installation">{b.installation_name}</p></div>
            <span className={`integration-badge ${b.state === "active" ? "is-active" : ""}`}>{b.state === "active" ? "有效" : "已撤销"}</span>
          </div>
          <p className="integration-muted integration-date">授权于 {time(b.created_at)}</p>
          <ul className="integration-scope-tags" aria-label="已批准权限">
            {b.scopes.map(scope => <li key={scope} title={labels[scope] || scope}>{titles[scope] || scope}</li>)}
          </ul>
          <div className="integration-row-actions">
            <button className="btn" aria-expanded={audit === b.binding_id} onClick={() => setAudit(audit === b.binding_id ? "" : b.binding_id)}>查看操作审计</button>
            {b.state === "active" && <PermissionEditor binding={b} refreshing={q.isFetching} changed={async () => {
              setNotice("授权已更新，旧凭证已失效；恢复权限须用户本人重新授权。"); await q.refetch();
            }} />}
          </div>
          {audit === b.binding_id && <AuditList id={b.binding_id} />}
        </article>)}
        {!q.data?.items.length && <Empty title="没有符合条件的助手授权" description="用户完成官网授权后，连接会显示在这里。" />}
      </div>
      {pages > 1 && <nav className="integration-pagination" aria-label="授权列表分页">
        <button className="btn" disabled={page === 1 || q.isFetching} onClick={() => { setPage(page - 1); setAudit(""); }}>上一页</button>
        <span>第 {page} / {pages} 页</span>
        <button className="btn" disabled={page >= pages || q.isFetching} onClick={() => { setPage(page + 1); setAudit(""); }}>下一页</button>
      </nav>}
    </QueryState>
  </section>;
}

function PermissionEditor({ binding: b, refreshing, changed }: { binding: Binding; refreshing: boolean; changed: () => Promise<unknown> }) {
  const [open, setOpen] = useState(false), [scopes, setScopes] = useState(b.scopes);
  const [mode, setMode] = useState<"reduce" | "revoke">("reduce");
  const [reason, setReason] = useState(""), [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false), [message, setMessage] = useState("");
  const mounted = useRef(true), inFlight = useRef(false), trigger = useRef<HTMLButtonElement>(null);
  const id = useId();
  const removed = b.scopes.filter(scope => !scopes.includes(scope));
  const ready = confirmed && reason.trim().length >= 3 && (mode === "revoke" || (removed.length > 0 && scopes.length > 0));
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  function cancel() {
    setOpen(false); setScopes(b.scopes); setMode("reduce"); setReason(""); setConfirmed(false); setMessage("");
    trigger.current?.focus();
  }
  async function submit() {
    if (!ready || inFlight.current || refreshing) return;
    inFlight.current = true;
    const session = captureAuthSession(), current = () => mounted.current && session();
    setBusy(true); setMessage("");
    try {
      await write(`/api/admin/integrations/${encodeURIComponent(b.binding_id)}/restrict`, {
        expected_epoch: b.epoch, scopes, revoke: mode === "revoke", reason: reason.trim(),
      });
      if (current()) await changed();
    } catch (error) {
      if (current()) setMessage(error instanceof ApiError && error.code === "binding_conflict"
        ? "授权状态已变化，请刷新列表后重新核对。"
        : error instanceof ApiError && error.code === "scope_escalation_forbidden"
          ? "管理员不能代用户增加授权，请由用户本人重新确认。"
          : "操作未完成，请刷新核实状态后重试，不要假定已经保存。");
    } finally { inFlight.current = false; if (current()) setBusy(false); }
  }
  return <div className="integration-editor">
    <button className="btn" ref={trigger} aria-controls={id} aria-expanded={open} disabled={busy || refreshing} onClick={() => open ? cancel() : setOpen(true)}>管理此授权</button>
    {open && <form id={id} className="integration-editor-body" onSubmit={e => { e.preventDefault(); void submit(); }}>
      <fieldset disabled={busy || refreshing}>
        <legend>处理 {b.nickname || "此用户"} 的授权</legend>
        <div className="integration-mode" role="group" aria-label="处理方式">
          {([['reduce', '缩减权限'], ['revoke', '撤销连接']] as const).map(([value, text]) => <label key={value}>
            <input type="radio" name={`${id}-mode`} value={value} checked={mode === value} onChange={() => { setMode(value); setConfirmed(false); setMessage(""); }} />{text}
          </label>)}
        </div>
        {mode === "reduce" ? <>
          <p className="integration-muted">取消勾选要移除的权限；不能在这里新增权限。</p>
          <div className="integration-permissions">{b.scopes.map(scope => <label key={scope} className={!scopes.includes(scope) ? "is-removed" : ""}>
            <input type="checkbox" checked={scopes.includes(scope)} onChange={e => { setScopes(values => e.target.checked ? [...values, scope] : values.filter(v => v !== scope)); setConfirmed(false); }} />
            <span><strong>{titles[scope] || scope}</strong><small>{labels[scope] || scope}</small></span>
          </label>)}</div>
          <p className="integration-change" role="status">{!scopes.length ? "若要移除全部权限，请选择“撤销连接”。" : removed.length ? `将移除：${removed.map(scope => titles[scope] || scope).join("、")}` : "尚未选择要移除的权限。"}</p>
        </> : <p className="integration-revoke-note">将撤销这条连接的全部权限，旧凭证和待发布草稿将失效。用户需在官网重新授权才能恢复。</p>}
        <label className="field">处理原因<textarea rows={2} maxLength={240} minLength={3} value={reason} onChange={e => setReason(e.target.value)} placeholder="请填写处理原因（至少 3 个字）" required /></label>
        <label className="integration-confirm"><input type="checkbox" checked={confirmed} onChange={e => setConfirmed(e.target.checked)} />确认使旧凭证失效，用户需要重新连接并本人授权</label>
        <div className="integration-submit">
          <button className={`btn ${mode === "revoke" ? "danger" : "primary"}`} disabled={!ready || busy || refreshing} type="submit">{busy ? "正在保存…" : mode === "revoke" ? "撤销此授权" : "保存缩减权限"}</button>
          <button className="btn" type="button" disabled={busy} onClick={cancel}>取消</button>
        </div>
      </fieldset>
      {message && <p className="integration-feedback is-error" role="alert">{message}</p>}
    </form>}
  </div>;
}

function AuditList({ id }: { id: string }) {
  const q = useApi<{ items: Audit[] }>(`/api/admin/integrations/${encodeURIComponent(id)}/audits`);
  return <section className="integration-audits" aria-label="操作审计">
    <h4>最近操作</h4><p className="integration-muted">最多 50 条，不含个人资料正文或凭证。</p>
    <QueryState query={q}>
      <ol>{(q.data?.items || []).map((row, i) => <li key={i}>
        <div><strong>{events[row.event] || row.event}</strong><time dateTime={row.created_at}>{time(row.created_at)}</time></div>
        {(row.actor_id > 0 || row.reason) && <p>{row.actor_id ? `操作账号 #${row.actor_id}` : ""}{row.actor_id > 0 && row.reason ? " · " : ""}{row.reason}</p>}
      </li>)}</ol>
      {!q.data?.items.length && <p className="integration-muted">暂无审计记录。</p>}
    </QueryState>
  </section>;
}
