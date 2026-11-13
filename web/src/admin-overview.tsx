import { query, rows, time, useApi, ApiError, type Entity } from "./api";
import { Empty, Head, Icon } from "./ui";
import { useAuth } from "./auth";
import { greeting, waitLevel, waitText } from "./admin-time";
import { reportReasonLabel, reportTargetLabel } from "./report-labels";

// 与各模块页面使用完全相同的请求地址，工作台、侧栏数量和模块页共享同一份缓存。
export const adminSources = {
  ticketStats: "/api/admin/feedback/tickets/stats",
  pendingTickets: query("/api/admin/feedback/tickets", { status_filter: "pending", page: 1, limit: 20 }),
  pendingReports: "/api/reports?status=pending",
  papers: "/api/admin/exam-papers",
  canteens: "/api/canteens/pending",
  teachers: "/api/teachers/pending",
  awards: "/api/admin/competition-awards/verifications",
  metrics: query("/api/admin/ai/metrics", { days: 7, page: 1, limit: 50 }),
  integrations: "/api/admin/integrations?state=active&page=1",
  logs: query("/api/super/admin_logs", { page: 1, limit: 50 }),
};

/** 侧栏与工作台共用的待办数量；读取失败时为 undefined，不显示成 0。 */
export function useAdminCounts() {
  const role = useAuth().user?.role;
  const stats = useApi(adminSources.ticketStats);
  const reports = useApi(adminSources.pendingReports);
  const papers = useApi(adminSources.papers);
  const canteens = useApi(adminSources.canteens);
  const teachers = useApi(adminSources.teachers);
  const awards = useApi(role === "super_admin" ? adminSources.awards : null);
  const integrations = useApi(adminSources.integrations);
  const len = (q: { data?: unknown; error: Error | null }, ...keys: string[]) => (q.data !== undefined && !q.error ? rows(q.data, ...keys).length : undefined);
  const pendingTickets = !stats.error && stats.data ? Number(stats.data.pending_count) || 0 : undefined;
  return {
    feedback: pendingTickets,
    unviewed: !stats.error && stats.data ? Number(stats.data.unviewed_count) || 0 : undefined,
    reports: len(reports, "reports"),
    papers: len(papers, "papers"),
    canteens: len(canteens, "canteens"),
    teachers: len(teachers, "teachers"),
    awards: role === "super_admin" ? len(awards, "verifications") : undefined,
    // 助手授权接口缺失（线上后端版本落后）时侧栏打一个提醒点。
    integrationsDown: integrations.error instanceof ApiError ? integrations.error.status === 404 : false,
  };
}

type Todo = { kind: string; tone: string; title: string; sub: string; since: string; tab: string; extra?: Record<string, string> };

export function AdminOverview({ open }: { open: (tab: string, extra?: Record<string, string>) => void }) {
  const auth = useAuth();
  const superAdmin = auth.user?.role === "super_admin";
  const counts = useAdminCounts();
  const stats = useApi(adminSources.ticketStats);
  const tickets = useApi(adminSources.pendingTickets);
  const reports = useApi(adminSources.pendingReports);
  const papers = useApi(adminSources.papers);
  const canteens = useApi(adminSources.canteens);
  const teachers = useApi(adminSources.teachers);
  const metrics = useApi(adminSources.metrics);
  const integrations = useApi(adminSources.integrations);
  const logs = useApi(superAdmin ? adminSources.logs : null);
  const sources = [stats, tickets, reports, papers, canteens, teachers, metrics, integrations, ...(superAdmin ? [logs] : [])];

  const todo: Todo[] = [
    ...rows(tickets.data, "tickets").map(t => ({ kind: "工单", tone: "danger", title: t.title, sub: `${t.ticket_no || ""}${t.user?.nickname ? ` · ${t.user.nickname}` : ""}`, since: t.created_at, tab: "feedback", extra: { ticket: String(t.id) } })),
    ...rows(reports.data, "reports").map(r => ({ kind: "举报", tone: "warn", title: `${reportReasonLabel(r.reason_code, r.reason)} · ${reportTargetLabel(r.target_type)} #${r.target_id}`, sub: r.reporter?.nickname ? `${r.reporter.nickname} 举报` : "", since: r.created_at, tab: "reports" })),
    ...rows(papers.data, "papers").map(x => reviewTodo("试卷审核", "papers", x)),
    ...rows(canteens.data, "canteens").map(x => reviewTodo("食堂审核", "canteens", x)),
    ...rows(teachers.data, "teachers").map(x => reviewTodo("教师审核", "teachers", x)),
  ].sort((a, b) => (Date.parse(a.since) || 0) - (Date.parse(b.since) || 0));
  const loadingQueue = [tickets, reports, papers, canteens, teachers].some(q => q.isPending);
  const failedQueue = [tickets, reports, papers, canteens, teachers].filter(q => q.error).length;
  const late = todo.filter(x => waitLevel(x.since) === "late").length;
  const oldestTicket = rows(tickets.data, "tickets").map(t => t.created_at).sort()[0];
  const lateReports = rows(reports.data, "reports").filter(r => waitLevel(r.created_at) === "late").length;
  const reviewTotal = [counts.papers, counts.canteens, counts.teachers].every(n => n !== undefined) ? (counts.papers || 0) + (counts.canteens || 0) + (counts.teachers || 0) : undefined;
  const m = metrics.data as Entity | undefined;
  const p95 = Number(m?.latency_ms?.p95 || 0);

  return (
    <>
      <Head level={2} title={`${greeting()}，${auth.user?.nickname || "管理员"}`} description={
        loadingQueue ? "正在汇总待办…" : todo.length ? `有 ${todo.length} 项等你处理${late ? `，其中 ${late} 项已超过 3 天` : ""}。` : failedQueue ? "部分待办读取失败，数量可能不完整。" : "待办都处理完了。"
      }><button className="btn" disabled={sources.some(q => q.isFetching)} onClick={() => { sources.forEach(q => void q.refetch()); }}>刷新工作台</button></Head>
      <div className="admin-kpis">
        <Kpi label="待受理工单" value={counts.feedback} icon="feedback" tone="danger" sub={stats.error ? "读取失败，请刷新重试" : counts.feedback === undefined ? "读取中" : oldestTicket ? `最久等待 ${waitText(oldestTicket)}` : counts.feedback ? "进入工单查看" : "没有待受理工单"} onClick={() => open("feedback")} />
        <Kpi label="待处理举报" value={counts.reports} icon="info" tone="warn" sub={reports.error ? "读取失败，请刷新重试" : counts.reports === undefined ? "读取中" : lateReports ? `${lateReports} 条超过 3 天` : "没有积压"} onClick={() => open("reports")} />
        <Kpi label="待审核" value={reviewTotal} icon="file" tone="violet" sub={`试卷 ${counts.papers ?? "—"} · 食堂 ${counts.canteens ?? "—"} · 教师 ${counts.teachers ?? "—"}`} onClick={() => open(counts.canteens ? "canteens" : counts.papers ? "papers" : "teachers")} quiet />
        <Kpi label="AI 成功率" value={m ? `${((Number(m.success_rate) || 0) * 100).toFixed(1)}%` : undefined} icon="trending" tone="success" sub={m ? `近 7 天 ${Number(m.requests || 0).toLocaleString("zh-CN")} 次请求` : metrics.error ? "读取失败" : "读取中"} onClick={() => open("metrics")} quiet />
      </div>
      <div className="admin-dash">
        <section className="panel admin-card" aria-labelledby="admin-queue-title">
          <div className="admin-card-head"><h3 id="admin-queue-title">处理队列</h3><span>按等待时间排序，最久的在前</span></div>
          {loadingQueue && !todo.length ? <div className="loading-state" role="status">正在加载…</div>
            : todo.length ? <ol className="admin-queue">{todo.slice(0, 10).map((x, i) => {
              const level = waitLevel(x.since);
              return (
                <li key={`${x.tab}-${i}`}>
                  <span className={`tag ${x.tone}`}>{x.kind}</span>
                  <span className="admin-queue-copy"><b>{x.title}</b>{x.sub && <small>{x.sub}</small>}</span>
                  {waitText(x.since) && <span className={`admin-wait ${level}`}><Icon name="clock" size={14} />等待 {waitText(x.since)}</span>}
                  <button className="btn sm" onClick={() => open(x.tab, x.extra)}>去处理</button>
                </li>
              );
            })}</ol>
            : <Empty icon="check" title={failedQueue ? "部分待办读取失败" : "队列已清空"} description={failedQueue ? "稍后刷新，或直接进入对应模块查看。" : "新的工单、举报和审核提交会按等待时间排在这里。"} />}
          {todo.length > 10 && <p className="admin-card-foot">还有 {todo.length - 10} 项，进入对应模块查看全部。</p>}
        </section>
        <div className="admin-dash-side">
          <section className="panel admin-card" aria-labelledby="admin-health-title">
            <div className="admin-card-head"><h3 id="admin-health-title">系统状态</h3><span>只列需要关注的项</span></div>
            <ul className="admin-health">
              {integrations.error instanceof ApiError && integrations.error.status === 404
                ? <Health tone="bad" title="助手授权接口未部署" text="/api/admin/integrations 返回 404，线上后端版本落后于 Web。" />
                : integrations.error ? <Health tone="warn" title="助手授权状态读取失败" text="稍后刷新重试。" />
                : integrations.data ? <Health tone="ok" title="助手授权接口正常" text={`${Number(integrations.data.total || 0)} 个有效授权，个人查询${integrations.data.personal_data_enabled ? "已开放" : "未开放"}。`} />
                : <Health tone="" title="正在检查助手授权接口…" text="" />}
              {m && (p95 >= 10000
                ? <Health tone="warn" title={`AI P95 耗时 ${(p95 / 1000).toFixed(1)} 秒`} text="偏慢，可在“AI 指标”查看各模型的请求与 Token。" />
                : <Health tone="ok" title={`AI P95 耗时 ${p95 >= 1000 ? `${(p95 / 1000).toFixed(1)} 秒` : `${p95} 毫秒`}`} text="近 7 天响应正常。" />)}
              {Number(counts.unviewed) > 0 && <Health tone="warn" title={`${counts.unviewed} 个工单还没有管理员查看`} text="在“工单”里选择“未查看”筛选。" />}
            </ul>
          </section>
          {superAdmin && (
            <section className="panel admin-card" aria-labelledby="admin-log-title">
              <div className="admin-card-head"><h3 id="admin-log-title">最近操作</h3><button className="btn ghost sm" onClick={() => open("logs")}>全部</button></div>
              {rows(logs.data, "logs").length
                ? <ul className="admin-log">{rows(logs.data, "logs").slice(0, 4).map(l => <li key={l.id}><span>{[l.admin_name, l.action].filter(Boolean).join(" · ")}</span><time dateTime={l.created_at}>{time(l.created_at)}</time></li>)}</ul>
                : <p className="admin-card-foot">{logs.isPending ? "正在加载…" : logs.error ? "操作日志读取失败" : "暂无操作记录"}</p>}
            </section>
          )}
        </div>
      </div>
    </>
  );
}

function reviewTodo(kind: string, tab: string, x: Entity): Todo {
  return { kind, tone: "violet", title: x.title || x.name || x.course_name || `#${x.id}`, sub: x.uploader?.nickname || x.submitter?.nickname || x.user?.nickname || "", since: x.created_at, tab };
}

function Kpi({ label, value, sub, icon, tone, onClick, quiet }: { label: string; value: string | number | undefined; sub: string; icon: string; tone: string; onClick: () => void; quiet?: boolean }) {
  const alert = !quiet && typeof value === "number" && value > 0;
  return (
    <button type="button" className={`admin-kpi tone-${tone}`} onClick={onClick}>
      <span className="admin-kpi-top"><span>{label}</span><span className="admin-kpi-icon"><Icon name={icon} size={18} /></span></span>
      <b>{value ?? "—"}</b>
      <small className={alert ? "is-alert" : ""}>{sub}</small>
    </button>
  );
}

function Health({ tone, title, text }: { tone: string; title: string; text: string }) {
  return (
    <li className={`admin-health-row ${tone}`}>
      <Icon name={tone === "ok" ? "check" : tone === "bad" || tone === "warn" ? "info" : "clock"} size={18} />
      <span><b>{title}</b>{text && <small>{text}</small>}</span>
    </li>
  );
}
