import { useEffect, useRef, useState } from "react";
import { ApiError, captureAuthSession, useApi, write, time } from "./api";
import { Empty, QueryState } from "./ui";
import { integrationScopeLabels as labels } from "./integration-scopes";
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
  const q = useApi<{ items: Binding[]; total: number }>(
    `/api/admin/integrations?state=${encodeURIComponent(state)}&page=${page}`,
  );
  return <section className="integration-management">
    <h2>助手授权管理</h2>
    <p>各用户独立绑定自己的校园账号。这里只管理权限与审计，不提供查看他人成绩、二课正文或凭证的入口。</p>
    <p>安装名称由插件自报，其中的 QQ 号不构成经过服务端核验的 QQ 身份证明。</p>
    {notice && <p role="status">{notice}</p>}
    <div className="integration-toolbar">
      <label>授权状态 <select value={state} onChange={e => { setState(e.target.value); setPage(1); setAudit(""); }}>
        <option value="active">有效</option><option value="revoked">已撤销</option><option value="">全部</option>
      </select></label>
      <button className="btn" disabled={q.isFetching} onClick={() => void q.refetch()}>刷新列表</button>
    </div>
    <QueryState query={q}>
      <p role="status">共 {q.data?.total ?? 0} 个授权 · 第 {page} 页</p>
      <div className="panel">{(q.data?.items || []).map(b => <article className="integration-binding" key={`${b.binding_id}:${b.epoch}`}>
        <h3>{b.nickname || "未设置昵称"}</h3><p>{b.installation_name} · {b.state === "active" ? "有效" : "已撤销"}</p>
        <small>授权于 {time(b.created_at)}</small>
        <ul>{b.scopes.map(scope => <li key={scope}>{labels[scope] || scope}</li>)}</ul>
        <button className="btn" onClick={() => setAudit(audit === b.binding_id ? "" : b.binding_id)}>查看操作审计</button>
        {b.state === "active" && <PermissionEditor binding={b} changed={async () => { setNotice("授权已更新，旧凭证已失效；恢复权限须用户本人重新授权。"); await q.refetch(); }} />}
        {audit === b.binding_id && <AuditList id={b.binding_id} />}
      </article>)}{!q.data?.items.length && <Empty title="没有符合条件的助手授权" />}</div>
      <div className="integration-toolbar">
        <button className="btn" disabled={page === 1 || q.isFetching} onClick={() => { setPage(page - 1); setAudit(""); }}>上一页</button>
        <button className="btn" disabled={page * 30 >= (q.data?.total || 0) || q.isFetching} onClick={() => { setPage(page + 1); setAudit(""); }}>下一页</button>
      </div>
    </QueryState>
  </section>;
}

function PermissionEditor({ binding: b, changed }: { binding: Binding; changed: () => Promise<unknown> }) {
  const [open, setOpen] = useState(false), [scopes, setScopes] = useState(b.scopes);
  const [reason, setReason] = useState(""), [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false), [message, setMessage] = useState("");
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  async function submit(revoke: boolean) {
    const session = captureAuthSession(), current = () => mounted.current && session();
    setBusy(true); setMessage("");
    try {
      await write(`/api/admin/integrations/${encodeURIComponent(b.binding_id)}/restrict`, {
        expected_epoch: b.epoch, scopes, revoke, reason: reason.trim(),
      });
      if (current()) { setMessage("已保存，旧凭证已失效。恢复或新增权限须用户本人重新授权。"); await changed(); }
    } catch (error) {
      if (current()) setMessage(error instanceof ApiError && error.code === "binding_conflict"
        ? "授权状态已变化，请刷新列表后重新核对。"
        : error instanceof ApiError && error.code === "scope_escalation_forbidden"
          ? "管理员不能代用户增加授权，请由用户本人重新确认。"
          : "操作未完成，请刷新核实状态后重试，不要假定已经保存。");
    } finally { if (current()) setBusy(false); }
  }
  return <div className="integration-editor">
    <button className="btn" aria-expanded={open} disabled={busy} onClick={() => setOpen(!open)}>管理此授权</button>
    {open && <fieldset disabled={busy}>
      <legend>只能缩减已有权限或撤销授权</legend>
      <div className="integration-permissions">{b.scopes.map(scope => <label key={scope}>
        <input type="checkbox" checked={scopes.includes(scope)} onChange={e => setScopes(values => e.target.checked ? [...values, scope] : values.filter(v => v !== scope))} />
        {labels[scope] || scope}
      </label>)}</div>
      <label className="field">处理原因<input maxLength={240} minLength={3} value={reason} onChange={e => setReason(e.target.value)} /></label>
      <label><input type="checkbox" checked={confirmed} onChange={e => setConfirmed(e.target.checked)} />确认使旧凭证失效，用户需要重新连接并本人授权</label>
      <div className="integration-toolbar">
        <button className="btn" disabled={!confirmed || reason.trim().length < 3 || !scopes.length || scopes.length === b.scopes.length} onClick={() => void submit(false)}>保存缩减权限</button>
        <button className="btn danger" disabled={!confirmed || reason.trim().length < 3} onClick={() => void submit(true)}>撤销此授权</button>
      </div>
    </fieldset>}
    {message && <p role="status">{message}</p>}
  </div>;
}

function AuditList({ id }: { id: string }) {
  const q = useApi<{ items: Audit[] }>(`/api/admin/integrations/${encodeURIComponent(id)}/audits`);
  return <QueryState query={q}><div className="integration-audits"><h4>最近操作（最多50条）</h4>
    {(q.data?.items || []).map((row, i) => <p key={i}>{time(row.created_at)} · {events[row.event] || row.event}
      {row.actor_id ? ` · 操作账号 #${row.actor_id}` : ""}{row.reason ? ` · ${row.reason}` : ""}</p>)}
    {!q.data?.items.length && <p>暂无审计记录。</p>}
  </div></QueryState>;
}
