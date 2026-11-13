import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { entity, query, rows, time, useApi, write, errorText, type Entity } from "./api";
import { Empty, Head, Pagination, QueryState, Tabs, useUI } from "./ui";
import { uploadIDs } from "./community";
import {
  attachmentAccept,
  attachmentHelp,
  initialAttachmentIDs,
  isInternalMessage,
  messageAttachmentIDs,
  messageSenderLabel,
  ticketAttachmentLimits,
  TicketAttachments,
} from "./attachments";
import { adminTicketFilters, states, StatusTag, ticketTypes } from "./feedback";
import { waitLevel, waitText } from "./admin-time";

// 常用回复：点选后填入输入框，仍可修改；不会自动发送。
export const replyTemplates: [string, string][] = [
  ["已收到", "已收到你的反馈，我们正在排查，有进展会第一时间在这里回复你。"],
  ["请补充信息", "麻烦补充一下：使用的 App 版本（我的 → 设置 → 关于）、手机型号，以及出现问题时的截图，方便我们定位。"],
  ["已修复", "这个问题已经在新版本修复，更新到最新版后如果还有问题，直接在这里回复我们。"],
  ["暂无法复现", "我们按你的步骤暂时没能复现，能否录一段屏幕或补充具体的操作时间？"],
];

const PAGE_SIZE = 20;

/** 桌面端工单工作区：左侧列表、右侧详情同屏处理；手机端仍走列表 → 详情页，对照 App。 */
export function AdminTickets() {
  const [params, setParams] = useSearchParams();
  // 默认只看待受理；“全部”在地址里记为 all，避免空值被当成默认筛选。
  const filter = params.get("status") || "pending";
  const page = Number(params.get("page")) || 1;
  const search = params.get("q") || "";
  const q = useApi(query("/api/admin/feedback/tickets", { status_filter: filter === "all" ? "" : filter, search, page, limit: PAGE_SIZE }));
  const stats = useApi("/api/admin/feedback/tickets/stats");
  const list = rows(q.data, "tickets");
  const chosen = params.get("ticket");
  // 没有显式选中时默认打开列表第一条，详情区不留空。
  const current = chosen && list.some(t => String(t.id) === chosen) ? chosen : chosen || (list[0] ? String(list[0].id) : "");
  const listRef = useRef<HTMLDivElement>(null);

  const update = (patch: Record<string, string>) => {
    const next = new URLSearchParams(params);
    next.set("tab", "feedback");
    Object.entries(patch).forEach(([k, v]) => (v ? next.set(k, v) : next.delete(k)));
    setParams(next);
  };
  const counts: Record<string, unknown> = {
    pending: stats.data?.pending_count,
    waiting_user: stats.data?.waiting_user_count,
    testing: stats.data?.testing_count,
    unviewed: stats.data?.unviewed_count,
  };

  // J / K 在列表里上下切换，R 跳到回复框；输入框里、按住修饰键或弹窗打开时不响应。
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const target = e.target instanceof Element ? e.target : null;
      if (e.ctrlKey || e.metaKey || e.altKey || target?.closest("input, textarea, select, [contenteditable], .overlay")) return;
      const k = e.key.toLowerCase();
      if (k === "r") {
        const box = document.getElementById("admin-reply");
        if (box) { e.preventDefault(); box.focus(); }
        return;
      }
      if (k !== "j" && k !== "k") return;
      const i = list.findIndex(t => String(t.id) === current);
      const next = list[Math.min(list.length - 1, Math.max(0, i + (k === "j" ? 1 : -1)))];
      if (!next) return;
      e.preventDefault();
      update({ ticket: String(next.id) });
      requestAnimationFrame(() => listRef.current?.querySelector<HTMLElement>(`[data-ticket="${next.id}"]`)?.focus());
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  });

  return (
    <>
      <Head level={2} title="工单" description="处理用户反馈的问题与建议，回复、内部备注和状态变更都会留下记录">
        <span className="admin-hints" aria-hidden="true"><kbd>J</kbd><kbd>K</kbd>切换<kbd>R</kbd>回复</span>
        <button className="btn" disabled={q.isFetching} onClick={() => { void q.refetch(); void stats.refetch(); }}>刷新</button>
      </Head>
      <div className="admin-toolbar">
        <Tabs
          tabs={adminTicketFilters.map(([v, l]) => [v, counts[v] != null ? `${l} ${counts[v]}` : l] as [string, string])}
          value={filter === "all" ? "" : filter}
          onChange={status => update({ status: status || "all", page: "", ticket: "" })}
        />
        <form className="admin-search" role="search" onSubmit={e => { e.preventDefault(); update({ q: String(new FormData(e.currentTarget).get("q") || "").trim(), page: "", ticket: "" }); }}>
          <input name="q" defaultValue={search} placeholder="单号、标题或描述" aria-label="搜索工单" />
          <button className="btn">搜索</button>
        </form>
      </div>
      <div className="admin-split">
        <div className="admin-split-list">
          <div className="panel admin-ticket-list" ref={listRef} aria-busy={q.isFetching}>
            <QueryState query={q}>
              {list.map(t => {
                const level = t.status === "pending" ? waitLevel(t.created_at) : "";
                return (
                  <button
                    type="button"
                    key={t.id}
                    data-ticket={t.id}
                    className="admin-ticket-row"
                    aria-current={String(t.id) === current ? "true" : undefined}
                    onClick={() => update({ ticket: String(t.id) })}
                  >
                    <span className="admin-ticket-top">
                      {t.admin_viewed === false && <span className="admin-unviewed" title="还没有管理员查看" aria-label="未查看" />}
                      <b>{t.title}</b>
                      <StatusTag status={t.status} />
                    </span>
                    <span className="admin-ticket-snippet">{t.latest_reply_snippet || t.description}</span>
                    <span className="admin-ticket-meta">
                      <span className="mono">{t.ticket_no}</span>
                      <span>
                        {level && <em className={`admin-wait ${level}`}>等待 {waitText(t.created_at)}</em>}
                        <time dateTime={t.updated_at}>{time(t.updated_at)}</time>
                      </span>
                    </span>
                  </button>
                );
              })}
              {!list.length && <Empty title={search ? "没有找到匹配的工单" : filter === "pending" ? "没有待受理的工单" : "这里没有工单"} description={search ? "换个关键词，或清空搜索查看全部。" : undefined} />}
            </QueryState>
          </div>
          <Pagination page={page} hasMore={Boolean(q.data?.has_more)} onChange={p => update({ page: String(p), ticket: "" })} />
        </div>
        {current ? <AdminTicketPane key={current} id={current} /> : <section className="panel admin-ticket-pane"><Empty title="选择一个工单" description="左侧列表里的工单会在这里打开。" /></section>}
      </div>
    </>
  );
}

function AdminTicketPane({ id }: { id: string }) {
  const ui = useUI();
  const queryClient = useQueryClient();
  const base = "/api/admin/feedback";
  const q = useApi(`${base}/tickets/${id}`);
  const ticket = entity(q.data, "ticket");
  const messages = rows(q.data, "messages");
  const [mode, setMode] = useState<"public" | "internal">("public");
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [nextStatus, setNextStatus] = useState("");
  const [statusNote, setStatusNote] = useState("");
  const publicClosed = ticket.status === "closed" && mode === "public";
  const form = useRef<HTMLFormElement>(null);
  const extra = (
    [["复现步骤", ticket.steps_to_reproduce], ["实际结果", ticket.actual_result], ["期望结果", ticket.expected_result]] as [string, unknown][]
  ).filter(([, v]) => typeof v === "string" && v.trim());
  const facts = [
    ticket.ticket_no,
    ticketTypes[ticket.type] || ticket.type,
    ticket.user_id && `${ticket.user?.nickname || "未设置昵称"} · UID ${ticket.user_id}`,
    [ticket.app_version, ticket.build_number && `(${ticket.build_number})`].filter(Boolean).join(" "),
    [ticket.device_model, ticket.os_version].filter(Boolean).join(" · "),
    ticket.current_route,
    ticket.created_at && `提交于 ${time(ticket.created_at)}`,
  ].filter(Boolean) as string[];

  async function changeStatus(status: string, note = "", expectedStatus = ticket.status) {
    await write(`${base}/tickets/${id}/status`, { status, status_note: note, expected_status: expectedStatus }, "PATCH");
  }
  async function send(e: FormEvent<HTMLFormElement>, thenWait = false) {
    e.preventDefault();
    const formEl = e.currentTarget;
    if (busy || publicClosed) return;
    if (!text.trim()) { setError("请先输入内容"); return; }
    setBusy(true); setError("");
    let messageSent = false;
    try {
      const image_ids = await uploadIDs(new FormData(formEl), ticketAttachmentLimits);
      const result = await write(`${base}/tickets/${id}/messages`, { content: text.trim(), image_ids, visible_to_user: mode === "public" });
      messageSent = true;
      // 消息与状态是两次独立写入，消息一旦成功就不能因后续失败保留成待发送草稿。
      setText("");
      formEl.reset();
      if (thenWait) {
        // 首次公开回复会由服务端自动受理，乐观并发检查必须使用返回的新状态。
        const updated = result.ticket?.status ? result.ticket : entity((await q.refetch()).data, "ticket");
        if (!updated.status) throw new Error("未能确认当前工单状态，请刷新后重试状态更新");
        if (updated.status !== "waiting_user") await changeStatus("waiting_user", "", updated.status);
      }
      await ui.act(() => q.refetch(), mode === "internal" ? "内部备注已保存" : thenWait ? "已回复，状态改为待补充" : "回复已发送");
    } catch (err) {
      setError(messageSent ? `回复已发送，但状态未能更新：${errorText(err)}。请使用上方处理状态重试，无需重复回复。` : errorText(err));
      if (messageSent) await queryClient.invalidateQueries({ queryKey: ["api"] });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="panel admin-ticket-pane" aria-label="工单详情">
      <QueryState query={q}>
        <header className="admin-pane-head">
          <div className="admin-pane-title">
            <h3>{ticket.title || "工单详情"}</h3>
            <StatusTag status={ticket.status} />
            <Link className="btn ghost sm" to={`/admin/feedback/${id}`} title="在独立页面打开，查看完整操作记录">完整页面</Link>
          </div>
          <p className="admin-pane-facts">{facts.map(f => <span key={f}>{f}</span>)}</p>
          <form className="admin-status-form" onSubmit={async e => {
            e.preventDefault();
            if (!nextStatus || nextStatus === ticket.status) return;
            if (await ui.act(() => changeStatus(nextStatus, statusNote.trim()), "处理进度已更新")) { setNextStatus(""); setStatusNote(""); }
          }}>
            {ticket.status === "pending" && <button type="button" className="btn primary sm" onClick={() => void ui.act(() => changeStatus("accepted"), "已受理，用户会收到通知")}>受理工单</button>}
            <label>状态
              <select value={nextStatus || ticket.status || ""} onChange={e => setNextStatus(e.target.value)} aria-label="处理状态">
                {Object.entries(states).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
            {nextStatus && nextStatus !== ticket.status && <>
              <input value={statusNote} onChange={e => setStatusNote(e.target.value)} placeholder="进度说明（选填，会通知用户）" aria-label="进度说明" />
              <button className="btn sm">更新状态</button>
            </>}
          </form>
        </header>
        <div className="admin-thread thread">
          <div className="thread-message">
            <div className="message-meta"><b>{ticket.user?.nickname || "用户"} · 初始提交</b><time>{time(ticket.created_at)}</time></div>
            <div className="bubble details-text">{q.data?.initial_submission?.content || ticket.description}</div>
            {extra.length > 0 && <dl className="ticket-extra">{extra.map(([l, v]) => <div key={l}><dt>{l}</dt><dd className="details-text">{String(v)}</dd></div>)}</dl>}
            <TicketAttachments data={initialAttachmentIDs(q.data)} scope="初始提交附件" />
          </div>
          {messages.map(m => (
            <div key={m.id} className={`thread-message ${m.sender_type === "admin" ? "official" : ""} ${isInternalMessage(m) ? "internal" : ""}`}>
              <div className="message-meta"><b>{messageSenderLabel(m)}</b>{isInternalMessage(m) && <span className="tag">内部备注</span>}<time>{time(m.created_at)}</time></div>
              <div className="bubble details-text">{m.content}</div>
              <TicketAttachments data={messageAttachmentIDs(m)} scope="本条消息附件" />
            </div>
          ))}
          {!messages.length && <p className="admin-thread-empty">还没有回复{ticket.status === "pending" ? " · 用户在等待受理" : ""}</p>}
        </div>
        <form ref={form} className="admin-composer" onSubmit={e => void send(e, (e.nativeEvent as SubmitEvent).submitter?.getAttribute("name") === "wait")}>
          <div className="admin-composer-top">
            <Tabs tabs={[["public", "回复用户"], ["internal", "内部备注"]]} value={mode} onChange={v => setMode(v as "public" | "internal")} />
            {mode === "public" && !publicClosed && <div className="admin-chips" aria-label="常用回复">
              {replyTemplates.map(([label, body]) => <button type="button" className="admin-chip" disabled={busy} key={label} onClick={() => { setText(body); document.getElementById("admin-reply")?.focus(); }}>{label}</button>)}
            </div>}
          </div>
          {publicClosed ? <p className="muted" role="status">该工单已关闭，请先在上方修改处理状态，再公开回复。内部备注仍可保存。</p> : <><textarea
            id="admin-reply"
            name="content"
            value={text}
            disabled={busy}
            onChange={e => { setText(e.target.value); setError(""); }}
            onKeyDown={e => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); form.current?.requestSubmit(); } }}
            placeholder={mode === "internal" ? "只有管理员能看到，用于交接和记录排查过程" : "回复会通知用户；需要用户补充信息时用“发送并设为待补充”"}
            aria-label={mode === "internal" ? "内部备注内容" : "回复内容"}
            rows={3}
          />
          <div className="admin-composer-foot">
            <label className="admin-attach">附件图片<input type="file" name="images" multiple accept={attachmentAccept} title={attachmentHelp} /></label>
            <span className="admin-hints">Ctrl + Enter 发送</span>
            <span className="admin-composer-actions">
              {mode === "public" && ticket.status !== "waiting_user" && <button className="btn" name="wait" disabled={busy}>发送并设为待补充</button>}
              <button className="btn primary" disabled={busy}>{busy ? "正在发送…" : mode === "internal" ? "保存备注" : "发送回复"}</button>
            </span>
          </div></>}
          {error && <p className="field-error" role="alert">{error}</p>}
        </form>
      </QueryState>
    </section>
  );
}
