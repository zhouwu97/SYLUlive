import { useState } from "react";
import { Link } from "react-router-dom";
import { ApiError, asset, entity, query, rows, time, useApi, write, type Entity } from "./api";
import { useAuth } from "./auth";
import { ServerAvatar } from "./server-avatar";
import { displayName, userHref } from "./user-level";
import { Empty, Form, Head, Icon, Pagination, QueryState, Stats, useUI } from "./ui";

/* ==================== 1. 安全中心 ==================== */
export function AdminSecurityCenter() {
  const auth = useAuth(), ui = useUI();
  const isSuper = auth.user?.role === "super_admin";
  const [range, setRange] = useState("24h");
  const [view, setView] = useState<"actionable" | "all" | "blocks">("actionable");
  const [severity, setSeverity] = useState("");
  const [page, setPage] = useState(1);

  const overview = useApi(`/api/admin/security/overview?range=${range}`);
  const events = useApi(
    view !== "blocks"
      ? query("/api/admin/security/events", {
          actionable: view === "actionable" ? "true" : undefined,
          severity: severity || undefined,
          page,
          limit: 20,
        })
      : null,
  );
  const blocks = useApi(isSuper && view === "blocks" ? query("/api/super/security/blocks", { active_only: "true", page: 1, limit: 50 }) : null);
  const ov = overview.data || {};
  const eventList = rows(events.data, "items", "events");
  const blockList = rows(blocks.data, "items", "blocks");

  function openBlockForm(sourceKey = "") {
    ui.open("新增临时来源封禁", (
      <Form
        fields={[
          { name: "source_key", label: "来源指纹 (source_key)", value: sourceKey, required: true },
          { name: "scope", label: "封禁范围", value: "route", options: [["route", "指定路由前缀"], ["account", "登录与账号接口"], ["all", "全站请求（谨慎）"]] },
          { name: "route_prefix", label: "路由前缀（仅“指定路由前缀”时填写）", value: "/api/login" },
          { name: "duration_minutes", label: "封禁时长", value: "60", options: [["15", "15 分钟"], ["60", "1 小时"], ["1440", "24 小时"]] },
          { name: "reason", label: "封禁原因（必填）", type: "textarea", required: true },
        ]}
        submit="立即封禁"
        onSubmit={async (v) => {
          await write("/api/super/security/blocks", {
            source_key: String(v.source_key).trim(),
            scope: v.scope,
            route_prefix: v.scope === "route" ? String(v.route_prefix || "").trim() : undefined,
            duration_minutes: Number(v.duration_minutes) || 60,
            confirm_global: v.scope === "all",
            reason: v.reason,
          });
          await overview.refetch();
          if (blocks.refetch) await blocks.refetch();
          ui.notify("来源封禁已生效");
          ui.close();
        }}
      />
    ));
  }

  return (
    <>
      <Head level={2} title="安全中心" description="监控登录异常、高频探测与敏感操作告警，区分需人工介入的高危事件与常规观察日志。">
        <div className="admin-seg" role="group" aria-label="统计窗口">
          {([["1h", "近 1 小时"], ["24h", "近 24 小时"], ["7d", "近 7 天"]] as const).map(([v, l]) => (
            <button key={v} type="button" aria-pressed={range === v} onClick={() => setRange(v)}>{l}</button>
          ))}
        </div>
        {isSuper && <button type="button" className="btn primary" onClick={() => openBlockForm()}>新增来源封禁</button>}
        <button type="button" className="btn" onClick={() => { void overview.refetch(); if (view === "blocks") void blocks.refetch(); else void events.refetch(); }}>刷新</button>
      </Head>

      <Stats items={[
        [overview.error ? "—" : Number(ov.actionable_high_count || 0), "高危待处理"],
        [overview.error ? "—" : Number(ov.open_high_count || 0), "未结高危事件"],
        [overview.error ? "—" : Number(ov.total_events || 0), `窗口内总事件 (${range})`],
        [overview.error ? "—" : Number(ov.active_blocks_count || 0), "生效来源封禁"],
      ]} />

      <div className="admin-toolbar">
        <div className="admin-seg" role="group" aria-label="安全视图">
          <button type="button" aria-pressed={view === "actionable"} onClick={() => { setView("actionable"); setPage(1); }}>需处置告警</button>
          <button type="button" aria-pressed={view === "all"} onClick={() => { setView("all"); setPage(1); }}>全部观察日志</button>
          {isSuper && <button type="button" aria-pressed={view === "blocks"} onClick={() => setView("blocks")}>生效封禁 ({Number(ov.active_blocks_count || 0)})</button>}
        </div>
        {view !== "blocks" && (
          <select aria-label="严重级别" value={severity} onChange={(e) => { setSeverity(e.target.value); setPage(1); }}>
            <option value="">全部级别</option>
            <option value="high">高危 (high)</option>
            <option value="medium">中危 (medium)</option>
            <option value="low">观察 (low)</option>
          </select>
        )}
      </div>

      {view === "blocks" ? (
        <QueryState query={blocks}>
          <div className="panel admin-list">
            {blockList.map((b) => (
              <div className="list-row admin-row" key={b.id}>
                <div className="list-main">
                  <div className="admin-row-head">
                    <b className="mono">{String(b.source_key || "").slice(0, 20)}…</b>
                    <span className="tag danger">{b.scope === "all" ? "全站封禁" : b.scope === "account" ? "账号接口" : b.route_prefix || "路由封禁"}</span>
                  </div>
                  <p>{b.reason}</p>
                  <small>到期：{time(b.expires_at)} · 创建于 {time(b.created_at)}</small>
                </div>
                <button type="button" className="btn sm" onClick={() => void ui.act(async () => { await write(`/api/super/security/blocks/${b.id}`, {}, "DELETE"); await blocks.refetch(); await overview.refetch(); }, "已解除来源封禁")}>解除封禁</button>
              </div>
            ))}
            {!blockList.length && <Empty icon="check" title="当前没有生效中的临时封禁" />}
          </div>
        </QueryState>
      ) : (
        <QueryState query={events}>
          <div className="panel admin-list">
            {eventList.map((ev) => {
              const high = ev.severity === "high" || ev.level === "high";
              const open = !ev.status || ev.status === "open" || ev.status === "pending";
              return (
                <div className="list-row admin-row" key={ev.id}>
                  <div className="list-main">
                    <div className="admin-row-head">
                      <span className={`tag ${high ? "danger" : ev.severity === "medium" ? "warn" : ""}`}>{ev.severity || "event"}</span>
                      <b>{ev.title || ev.event_type || `事件 #${ev.id}`}</b>
                      {ev.route && <span className="mono muted">{ev.route}</span>}
                      {!open && <span className="tag">{ev.status === "false_positive" ? "误报" : "已处理"}</span>}
                    </div>
                    <p>{ev.summary || ev.detail || ev.message || "安全审计记录"}{ev.user_id ? ` · UID ${ev.user_id}` : ""}</p>
                    <small>{time(ev.created_at)}{isSuper && ev.source_key ? ` · 来源指纹 ${String(ev.source_key).slice(0, 16)}…` : ""}</small>
                  </div>
                  <div className="admin-row-actions">
                    {open && (
                      <>
                        <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/admin/security/events/${ev.id}/resolve`, { note: "管理端核查结案" }); await events.refetch(); await overview.refetch(); }, "事件已标为已处理")}>已处理</button>
                        <button type="button" className="btn sm" onClick={() => void ui.act(async () => { await write(`/api/admin/security/events/${ev.id}/false-positive`, { note: "正常业务操作" }); await events.refetch(); await overview.refetch(); }, "已标记为误报")}>误报</button>
                      </>
                    )}
                    {isSuper && ev.source_key && (
                      <button type="button" className="btn sm danger" onClick={() => openBlockForm(String(ev.source_key))}>封禁来源</button>
                    )}
                  </div>
                </div>
              );
            })}
            {!eventList.length && <Empty icon="check" title={view === "actionable" ? "当前没有需人工处置的高危告警" : "暂无安全事件记录"} />}
          </div>
          {(page > 1 || eventList.length === 20) && <Pagination page={page} hasMore={eventList.length === 20} onChange={setPage} />}
        </QueryState>
      )}
    </>
  );
}

/* ==================== 2. 公众法庭人工复核 & 隐藏帖整改复审 ==================== */
export function AdminAppealsAndRectification() {
  const auth = useAuth(), ui = useUI();
  const isSuper = auth.user?.role === "super_admin";
  const [view, setView] = useState<"appeals" | "rectify" | "all_appeals">("appeals");

  const appeals = useApi(view === "appeals" ? "/api/admin/appeals/review" : null);
  const allAppeals = useApi(isSuper && view === "all_appeals" ? "/api/appeals" : null);
  const rectify = useApi(view === "rectify" ? "/api/admin/rectification?status=pending&page=1&limit=30" : null);

  const appealList = rows(view === "all_appeals" ? allAppeals.data : appeals.data, "appeals", "items");
  const rectifyList = rows(rectify.data, "items", "reviews");

  return (
    <>
      <Head level={2} title="法庭复核与整改复审" description="处理社区陪审未达成绝对多数的申诉案件、审核隐藏帖作者修改后的复审申请，或直接恢复误隐藏内容。">
        <div className="admin-seg" role="group" aria-label="复核类型">
          <button type="button" aria-pressed={view === "appeals"} onClick={() => setView("appeals")}>法庭人工复核</button>
          <button type="button" aria-pressed={view === "rectify"} onClick={() => setView("rectify")}>隐藏帖整改复审</button>
          {isSuper && <button type="button" aria-pressed={view === "all_appeals"} onClick={() => setView("all_appeals")}>全部申诉案卷</button>}
        </div>
        <button
          type="button"
          className="btn"
          onClick={() => ui.open("恢复误隐藏帖子", (
            <Form
              fields={[
                { name: "post_id", label: "帖子 ID", type: "number", min: 1, required: true },
                { name: "reason", label: "恢复说明（必填）", type: "textarea", required: true },
              ]}
              submit="确认恢复公开"
              onSubmit={async (v) => {
                await write(`/api/admin/posts/${Number(v.post_id)}/restore`, { reason: v.reason });
                ui.notify(`帖子 #${v.post_id} 已恢复显示`);
                ui.close();
              }}
            />
          ))}
        >
          按 ID 恢复帖子
        </button>
        <button type="button" className="btn" onClick={() => { if (view === "rectify") void rectify.refetch(); else if (view === "all_appeals") void allAppeals.refetch(); else void appeals.refetch(); }}>刷新</button>
      </Head>

      {view === "rectify" ? (
        <QueryState query={rectify}>
          <div className="panel admin-list">
            {rectifyList.map((r) => (
              <div className="list-row admin-row" key={r.id}>
                <div className="list-main">
                  <div className="admin-row-head">
                    <span className="tag warn">整改待审</span>
                    <b>帖子 #{r.post_id} · {r.post_title || r.title || "内容修改复审"}</b>
                  </div>
                  <p>{r.note || r.reason || r.content || "作者已更新内容并提交复审"}</p>
                  <small>{time(r.created_at)}</small>
                </div>
                <div className="admin-row-actions">
                  <Link className="btn sm" to={`/post/${r.post_id}`} target="_blank" rel="noreferrer">查看帖子</Link>
                  <button
                    type="button"
                    className="btn sm primary"
                    onClick={() => ui.open(`处理整改复审 #${r.id}`, (
                      <Form
                        fields={[
                          { name: "decision", label: "复审决定", options: [["approve", "通过并恢复公开"], ["reject", "驳回整改"]] },
                          { name: "reason", label: "复审意见（驳回必填）", type: "textarea" },
                        ]}
                        onSubmit={async (v) => {
                          if (v.decision === "reject" && !String(v.reason || "").trim()) throw new Error("驳回整改时请填写具体修改建议");
                          await write(`/api/admin/rectification/${r.id}/${v.decision}`, { reason: v.reason });
                          await rectify.refetch();
                          ui.notify("整改复审结果已保存");
                          ui.close();
                        }}
                      />
                    ))}
                  >
                    裁决
                  </button>
                </div>
              </div>
            ))}
            {!rectifyList.length && <Empty icon="check" title="没有待处理的整改复审" />}
          </div>
        </QueryState>
      ) : (
        <QueryState query={view === "all_appeals" ? allAppeals : appeals}>
          <div className="panel admin-list">
            {appealList.map((a) => (
              <div className="list-row admin-row" key={a.id}>
                <div className="list-main">
                  <div className="admin-row-head">
                    <span className="tag violet">{a.status || "待复核"}</span>
                    <b>案件 #{a.id} · {a.target_type || "内容"} #{a.target_id || a.post_id}</b>
                  </div>
                  <p>申诉理由：{a.reason || a.appeal_reason || "—"}</p>
                  <small>支持票 {a.support_votes ?? a.approve_count ?? 0} · 维持票 {a.oppose_votes ?? a.reject_count ?? 0} · {time(a.created_at)}</small>
                </div>
                {view === "appeals" && (
                  <button
                    type="button"
                    className="btn sm primary"
                    onClick={() => ui.open(`人工复核裁决 · 案件 #${a.id}`, (
                      <Form
                        fields={[
                          { name: "decision", label: "终审裁决", options: [["pass", "支持申诉（撤销原处罚）"], ["reject", "驳回申诉（维持原判）"]] },
                          { name: "reason", label: "裁决依据（必填，向当事人公示）", type: "textarea", required: true },
                        ]}
                        onSubmit={async (v) => {
                          await write(`/api/admin/appeals/${a.id}/review`, { decision: v.decision, reason: v.reason });
                          await appeals.refetch();
                          ui.notify("人工复核裁决已生效");
                          ui.close();
                        }}
                      />
                    ))}
                  >
                    复核裁决
                  </button>
                )}
              </div>
            ))}
            {!appealList.length && <Empty icon="check" title={view === "appeals" ? "当前没有需要人工复核的法庭案件" : "暂无申诉记录"} />}
          </div>
        </QueryState>
      )}
    </>
  );
}

/* ==================== 3. 精华申请、全站置顶 & 版块图标审核 ==================== */
export function AdminFeaturedAndPins() {
  const auth = useAuth(), ui = useUI();
  const maxPinDays = auth.user?.role === "super_admin" ? 30 : 7;
  const [view, setView] = useState<"featured" | "pins" | "icons">("featured");
  const [featStatus, setFeatStatus] = useState("pending");

  const featured = useApi(view === "featured" ? query("/api/admin/featured-applications", { status: featStatus, page: 1, limit: 30 }) : null);
  const pins = useApi(view === "pins" ? "/api/admin/posts/pinned?board_id=1" : null);
  const icons = useApi(view === "icons" ? "/api/admin/water/section-icon-reviews?status=pending&page=1&limit=30" : null);

  const featList = rows(featured.data, "items", "applications");
  const pinList = rows(pins.data, "items", "posts");
  const iconList = rows(icons.data, "items", "submissions");

  return (
    <>
      <Head level={2} title="精华、置顶与版块图标" description="审核同学提交的帖子加精申请，管理社区公共置顶帖，以及审核版块共建图标。">
        <div className="admin-seg" role="group" aria-label="内容推荐子模块">
          <button type="button" aria-pressed={view === "featured"} onClick={() => setView("featured")}>精华申请</button>
          <button type="button" aria-pressed={view === "pins"} onClick={() => setView("pins")}>全站置顶帖</button>
          <button type="button" aria-pressed={view === "icons"} onClick={() => setView("icons")}>版块图标审核</button>
        </div>
        {view === "pins" && (
          <button
            type="button"
            className="btn primary"
            onClick={() => ui.open("新增全站置顶", (
              <Form
                fields={[
                  { name: "post_id", label: "帖子 ID", type: "number", min: 1, required: true },
                  { name: "days", label: `置顶天数（当前角色最长 ${maxPinDays} 天）`, type: "number", min: 1, max: maxPinDays, value: Math.min(3, maxPinDays), required: true },
                  { name: "weight", label: "排序权重（数字越大越靠前）", type: "number", value: 10 },
                  { name: "reason", label: "置顶原因", value: "校园公共通知" },
                ]}
                submit="设为全站置顶"
                onSubmit={async (v) => {
                  const days = Math.min(maxPinDays, Math.max(1, Number(v.days) || 3));
                  const pinned_until = new Date(Date.now() + days * 86400_000).toISOString();
                  await write(`/api/admin/posts/${Number(v.post_id)}/pin`, { pinned_until, weight: Number(v.weight) || 0, reason: v.reason });
                  await pins.refetch();
                  ui.notify("全站置顶已生效");
                  ui.close();
                }}
              />
            ))}
          >
            新增置顶
          </button>
        )}
        <button type="button" className="btn" onClick={() => { if (view === "featured") void featured.refetch(); else if (view === "pins") void pins.refetch(); else void icons.refetch(); }}>刷新</button>
      </Head>

      {view === "featured" && (
        <>
          <div className="admin-toolbar">
            <div className="admin-seg" role="group" aria-label="精华筛选">
              <button type="button" aria-pressed={featStatus === "pending"} onClick={() => setFeatStatus("pending")}>待审核</button>
              <button type="button" aria-pressed={featStatus === "all"} onClick={() => setFeatStatus("all")}>全部记录</button>
            </div>
          </div>
          <QueryState query={featured}>
            <div className="panel admin-list">
              {featList.map((f) => (
                <div className="list-row admin-row" key={f.id}>
                  <div className="list-main">
                    <div className="admin-row-head">
                      <span className={`tag ${f.status === "pending" ? "warn" : f.status === "approved" ? "is-resolved" : ""}`}>{f.status === "pending" ? "待审核" : f.status === "approved" ? "已加精" : "已驳回"}</span>
                      <b>{f.post?.title || f.post_title || `帖子 #${f.post_id}`}</b>
                    </div>
                    <p>自荐说明：{f.reason || "申请设为精华内容"}</p>
                    <small>申请人：{f.applicant?.nickname || `UID ${f.user_id || f.applicant_id || ""}`} · {time(f.created_at)}</small>
                  </div>
                  <div className="admin-row-actions">
                    {f.post_id && <Link className="btn sm" to={`/post/${f.post_id}`} target="_blank" rel="noreferrer">查看原帖</Link>}
                    {f.status === "pending" && (
                      <>
                        <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/admin/featured-applications/${f.id}/approve`, {}); await featured.refetch(); }, "已通过加精申请")}>通过</button>
                        <button
                          type="button"
                          className="btn sm"
                          onClick={() => ui.open("驳回精华申请", (
                            <Form
                              fields={[
                                { name: "reason", label: "驳回原因（必填）", type: "textarea", required: true },
                                { name: "penalty_points", label: "恶意滥用扣减诚信分（0 表示不扣分）", type: "number", min: 0, max: 20, value: 0 },
                              ]}
                              submit="确认驳回"
                              onSubmit={async (v) => {
                                const pts = Number(v.penalty_points) || 0;
                                await write(`/api/admin/featured-applications/${f.id}/reject`, { reason: v.reason, is_malicious: pts > 0, penalty_points: pts });
                                await featured.refetch();
                                ui.notify("精华申请已驳回");
                                ui.close();
                              }}
                            />
                          ))}
                        >
                          驳回
                        </button>
                      </>
                    )}
                  </div>
                </div>
              ))}
              {!featList.length && <Empty icon="check" title="没有待处理的精华申请" />}
            </div>
          </QueryState>
        </>
      )}

      {view === "pins" && (
        <QueryState query={pins}>
          <div className="panel admin-list">
            {pinList.map((p) => (
              <div className="list-row admin-row" key={p.id}>
                <div className="list-main">
                  <div className="admin-row-head">
                    <span className="tag brand">置顶中</span>
                    <b>#{p.id} · {p.title || p.content?.slice(0, 48) || "置顶帖"}</b>
                  </div>
                  <p>{p.pinned_reason || "公共置顶"} · 权重 {p.pinned_weight ?? 0}</p>
                  <small>到期：{p.pinned_until ? time(p.pinned_until) : "未设期限"}</small>
                </div>
                <div className="admin-row-actions">
                  <Link className="btn sm" to={`/post/${p.id}`} target="_blank" rel="noreferrer">查看</Link>
                  <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/admin/posts/${p.id}/unpin`); await pins.refetch(); }, "已取消置顶")}>取消置顶</button>
                </div>
              </div>
            ))}
            {!pinList.length && <Empty title="当前没有全站置顶帖子" />}
          </div>
        </QueryState>
      )}

      {view === "icons" && (
        <QueryState query={icons}>
          <div className="panel admin-list">
            {iconList.map((ic) => {
              const img = asset(ic.icon_url || ic.avatar_url || ic.image_url);
              return (
                <div className="list-row admin-row admin-store-row" key={ic.id}>
                  <span className="admin-store-thumb">{img ? <img src={img} alt="" /> : <Icon name="image" />}</span>
                  <div className="list-main">
                    <b>{ic.section_title || ic.section_slug || `版块 #${ic.section_id}`}</b>
                    <p>{ic.reason || ic.description || "申请更新版块图标"}</p>
                    <small>提交人：{ic.submitter?.nickname || `UID ${ic.user_id || ""}`} · {time(ic.created_at)}</small>
                  </div>
                  <div className="admin-row-actions">
                    <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/admin/water/section-icon-reviews/${ic.id}/approve`, {}); await icons.refetch(); }, "图标已通过并生效")}>通过</button>
                    <button
                      type="button"
                      className="btn sm"
                      onClick={() => ui.open("驳回版块图标", (
                        <Form
                          fields={[{ name: "reason", label: "驳回说明（必填）", type: "textarea", required: true }]}
                          onSubmit={async (v) => {
                            await write(`/api/admin/water/section-icon-reviews/${ic.id}/reject`, { reason: v.reason });
                            await icons.refetch();
                            ui.notify("已驳回图标投稿");
                            ui.close();
                          }}
                        />
                      ))}
                    >
                      驳回
                    </button>
                  </div>
                </div>
              );
            })}
            {!iconList.length && <Empty icon="check" title="没有待审核的版块图标" />}
          </div>
        </QueryState>
      )}
    </>
  );
}

/* ==================== 4. 教评、专业、教师与重名治理 ==================== */
export function AdminAcademicReviews() {
  const ui = useUI();
  const [view, setView] = useState<"teachers" | "majors" | "evals" | "governance">("teachers");

  const teachers = useApi(view === "teachers" ? "/api/teachers/pending" : null);
  const majors = useApi(view === "majors" ? "/api/majors/pending" : null);
  const evals = useApi(view === "evals" ? "/api/admin/course-evaluations/pending?page=1&limit=30" : null);
  const dupGroups = useApi(view === "governance" ? "/api/admin/teacher-governance/duplicate-groups" : null);
  const aliases = useApi(view === "governance" ? "/api/admin/teacher-governance/aliases?page=1&limit=50" : null);

  const teacherList = rows(teachers.data, "teachers", "items");
  const majorList = rows(majors.data, "majors", "items");
  const evalList = rows(evals.data, "items", "evaluations");
  const groupList = rows(dupGroups.data, "groups", "items");
  const aliasList = rows(aliases.data, "aliases", "items");

  return (
    <>
      <Head level={2} title="教师、专业与课程评价治理" description="集中审核新增教师、新增专业与课程评价，治理重名教师、同名课程与教师别名。">
        <div className="admin-seg" role="group" aria-label="教评治理子视图">
          <button type="button" aria-pressed={view === "teachers"} onClick={() => setView("teachers")}>待审教师</button>
          <button type="button" aria-pressed={view === "majors"} onClick={() => setView("majors")}>待审专业</button>
          <button type="button" aria-pressed={view === "evals"} onClick={() => setView("evals")}>课程评价审核</button>
          <button type="button" aria-pressed={view === "governance"} onClick={() => setView("governance")}>合并与别名治理</button>
        </div>
        <button type="button" className="btn" onClick={() => { if (view === "teachers") void teachers.refetch(); else if (view === "majors") void majors.refetch(); else if (view === "evals") void evals.refetch(); else { void dupGroups.refetch(); void aliases.refetch(); } }}>刷新</button>
      </Head>

      {view === "teachers" && (
        <QueryState query={teachers}>
          <div className="panel admin-list">
            {teacherList.map((t) => (
              <div className="list-row admin-row" key={t.id}>
                <div className="list-main">
                  <b>{t.name}</b>
                  <p>{[t.department || t.college, t.title, t.courses].filter(Boolean).join(" · ") || "新增教师词条"}</p>
                  <small>{time(t.created_at)}</small>
                </div>
                <div className="admin-row-actions">
                  <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/teachers/${t.id}/verify`, {}, "PUT"); await teachers.refetch(); }, `已通过教师「${t.name}」`)}>通过</button>
                  <button
                    type="button"
                    className="btn sm"
                    onClick={() => ui.open(`合并待审教师 · ${t.name}`, (
                      <Form
                        fields={[
                          { name: "keeper_id", label: "保留的目标教师 ID", type: "number", min: 1, required: true },
                          { name: "note", label: "合并备注", value: "重名词条归并" },
                        ]}
                        submit="确认合并"
                        onSubmit={async (v) => {
                          await write(`/api/admin/teachers/${t.id}/merge-into`, { keeper_id: Number(v.keeper_id), register_alias: true, note: v.note });
                          await teachers.refetch();
                          ui.notify("已合并到目标教师");
                          ui.close();
                        }}
                      />
                    ))}
                  >
                    合并至已有
                  </button>
                  <button
                    type="button"
                    className="btn sm danger"
                    onClick={() => ui.open(`驳回教师 · ${t.name}`, (
                      <Form
                        fields={[{ name: "reason", label: "驳回说明", type: "textarea", required: true }]}
                        submit="确认驳回"
                        onSubmit={async (v) => {
                          await write(`/api/teachers/${t.id}/reject`, { reason: v.reason }, "DELETE");
                          await teachers.refetch();
                          ui.notify("已驳回教师提交");
                          ui.close();
                        }}
                      />
                    ))}
                  >
                    驳回
                  </button>
                </div>
              </div>
            ))}
            {!teacherList.length && <Empty icon="check" title="当前队列为空" description="暂无待审核的教师词条" />}
          </div>
        </QueryState>
      )}

      {view === "majors" && (
        <QueryState query={majors}>
          <div className="panel admin-list">
            {majorList.map((m) => (
              <div className="list-row admin-row" key={m.id}>
                <div className="list-main">
                  <b>{m.name}</b>
                  <p>{m.college || m.department || m.description || "新增专业词条"}</p>
                  <small>{time(m.created_at)}</small>
                </div>
                <div className="admin-row-actions">
                  <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/majors/${m.id}/verify`, {}, "PUT"); await majors.refetch(); }, `已通过专业「${m.name}」`)}>通过</button>
                  <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/majors/${m.id}/reject`, { reason: "信息不准确" }, "DELETE"); await majors.refetch(); }, "已驳回专业词条")}>驳回</button>
                </div>
              </div>
            ))}
            {!majorList.length && <Empty icon="check" title="暂无待审核的专业词条" />}
          </div>
        </QueryState>
      )}

      {view === "evals" && (
        <QueryState query={evals}>
          <div className="panel admin-list">
            {evalList.map((ev) => (
              <div className="list-row admin-row" key={ev.id}>
                <div className="list-main">
                  <div className="admin-row-head">
                    <b>{ev.subject_name || ev.course_name || `评价 #${ev.id}`}</b>
                    {ev.teacher_name && <span className="tag">{ev.teacher_name}</span>}
                  </div>
                  <p>{ev.comment || ev.content}</p>
                  <small>版本 rev.{ev.revision ?? 1} · {time(ev.created_at)}</small>
                </div>
                <div className="admin-row-actions">
                  <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/admin/course-evaluations/${ev.id}/approve`, { revision: Number(ev.revision ?? 1) }, "PUT"); await evals.refetch(); }, "课程评价已通过")}>通过</button>
                  <button
                    type="button"
                    className="btn sm danger"
                    onClick={() => ui.open("驳回课程评价", (
                      <Form
                        fields={[{ name: "reason", label: "驳回原因（必填）", type: "textarea", required: true }]}
                        submit="确认驳回"
                        onSubmit={async (v) => {
                          await write(`/api/admin/course-evaluations/${ev.id}/reject`, { revision: Number(ev.revision ?? 1), reason: v.reason }, "PUT");
                          await evals.refetch();
                          ui.notify("课程评价已驳回");
                          ui.close();
                        }}
                      />
                    ))}
                  >
                    驳回
                  </button>
                </div>
              </div>
            ))}
            {!evalList.length && <Empty icon="check" title="暂无待审核的课程评价" />}
          </div>
        </QueryState>
      )}

      {view === "governance" && (
        <div className="admin-two-cards">
          <section className="panel admin-card">
            <div className="admin-card-head">
              <h3>教师 / 课程归并工具</h3>
              <div className="admin-inline-actions">
                <button type="button" className="btn sm" onClick={() => ui.open("合并重复教师", (
                  <Form
                    fields={[
                      { name: "keeper_id", label: "保留教师 ID", type: "number", min: 1, required: true },
                      { name: "duplicate_id", label: "被合并教师 ID", type: "number", min: 1, required: true },
                      { name: "note", label: "备注说明", value: "同名同院系归并" },
                    ]}
                    submit="执行教师合并"
                    onSubmit={async (v) => {
                      await write("/api/admin/teacher-governance/merge", { keeper_id: Number(v.keeper_id), duplicate_id: Number(v.duplicate_id), register_alias: true, note: v.note });
                      await dupGroups.refetch();
                      ui.notify("教师记录已合并");
                      ui.close();
                    }}
                  />
                ))}>合并教师</button>
                <button type="button" className="btn sm" onClick={() => ui.open("合并重复课程", (
                  <Form
                    fields={[
                      { name: "keeper_subject_id", label: "保留课程 ID", type: "number", min: 1, required: true },
                      { name: "duplicate_subject_id", label: "被合并课程 ID", type: "number", min: 1, required: true },
                      { name: "note", label: "备注说明", value: "课程名规范化归并" },
                    ]}
                    submit="执行课程合并"
                    onSubmit={async (v) => {
                      await write("/api/admin/teacher-governance/course-merge", { keeper_subject_id: Number(v.keeper_subject_id), duplicate_subject_id: Number(v.duplicate_subject_id), note: v.note });
                      ui.notify("课程记录已合并");
                      ui.close();
                    }}
                  />
                ))}>合并课程</button>
              </div>
            </div>
            <QueryState query={dupGroups}>
              <div className="admin-list">
                {groupList.map((g, idx) => (
                  <div className="list-row admin-row" key={g.id || idx}>
                    <div className="list-main">
                      <b>{g.name || g.key || `疑似重名组 #${idx + 1}`}</b>
                      <p>{Array.isArray(g.teachers) ? g.teachers.map((t: Entity) => `${t.name}(#${t.id} ${t.department || ""})`).join(" / ") : (g.summary || "候选重复项")}</p>
                    </div>
                  </div>
                ))}
                {!groupList.length && <Empty title="暂无系统识别的疑似重名教师组" />}
              </div>
            </QueryState>
          </section>

          <section className="panel admin-card">
            <div className="admin-card-head">
              <h3>教师别名映射</h3>
              <button type="button" className="btn sm primary" onClick={() => ui.open("新增教师别名", (
                <Form
                  fields={[
                    { name: "alias_name", label: "常见错写 / 简称", required: true },
                    { name: "target_teacher_id", label: "指向标准教师 ID", type: "number", min: 1, required: true },
                    { name: "note", label: "说明" },
                  ]}
                  submit="添加别名"
                  onSubmit={async (v) => {
                    await write("/api/admin/teacher-governance/aliases", { alias_name: v.alias_name, target_teacher_id: Number(v.target_teacher_id), note: v.note });
                    await aliases.refetch();
                    ui.notify("教师别名已添加");
                    ui.close();
                  }}
                />
              ))}>新增别名</button>
            </div>
            <QueryState query={aliases}>
              <div className="admin-list">
                {aliasList.map((a) => (
                  <div className="list-row admin-row" key={a.id}>
                    <div className="list-main">
                      <b>{a.alias_name} → {a.target_teacher_name || `教师 #${a.target_teacher_id}`}</b>
                      {a.note && <small>{a.note}</small>}
                    </div>
                    <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/admin/teacher-governance/aliases/${a.id}`, {}, "DELETE"); await aliases.refetch(); }, "别名已删除")}>删除</button>
                  </div>
                ))}
                {!aliasList.length && <Empty title="暂无教师别名记录" />}
              </div>
            </QueryState>
          </section>
        </div>
      )}
    </>
  );
}

/* ==================== 5. 表情包与创作者审核 ==================== */
export function AdminEmojiModeration() {
  const auth = useAuth(), ui = useUI();
  const [view, setView] = useState<"packs" | "creators">("packs");
  const [status, setStatus] = useState("pending");

  const packs = useApi(view === "packs" ? query("/api/admin/emoji-packs", { status, page: 1, limit: 30 }) : null);
  const creators = useApi(view === "creators" ? query("/api/admin/emoji-creators", { status, page: 1, limit: 30 }) : null);
  const packList = rows(packs.data, "items", "packs");
  const creatorList = rows(creators.data, "items", "creators");

  return (
    <>
      <Head level={2} title="表情包与创作者审核" description="审核同学投稿的原创/授权表情包与创作者资质申请，本人提交的申请遵循回避原则由其他管理员审核。">
        <div className="admin-seg" role="group" aria-label="表情审核模块">
          <button type="button" aria-pressed={view === "packs"} onClick={() => { setView("packs"); setStatus("pending"); }}>表情包审核</button>
          <button type="button" aria-pressed={view === "creators"} onClick={() => { setView("creators"); setStatus("pending"); }}>创作者资质</button>
        </div>
        <button type="button" className="btn" onClick={() => { if (view === "packs") void packs.refetch(); else void creators.refetch(); }}>刷新</button>
      </Head>

      <div className="admin-toolbar">
        <div className="admin-seg" role="group" aria-label="状态筛选">
          {(view === "packs"
            ? [["pending", "待审核"], ["published", "已上架"], ["rejected", "已驳回"], ["unpublished", "已下架"]]
            : [["pending", "待审核"], ["active", "已认证"], ["rejected", "已驳回"], ["suspended", "已暂停"]]
          ).map(([v, l]) => (
            <button key={v} type="button" aria-pressed={status === v} onClick={() => setStatus(v)}>{l}</button>
          ))}
        </div>
      </div>

      {view === "packs" ? (
        <QueryState query={packs}>
          <div className="panel admin-list">
            {packList.map((p) => {
              const self = Number(p.creator_id || p.user_id) === auth.user?.id;
              return (
                <div className="list-row admin-row admin-store-row" key={p.id}>
                  <span className="admin-store-thumb">
                    <img src={`/api/admin/emoji-packs/${p.id}/cover?variant=thumbnail`} alt="" loading="lazy" onError={(e) => { e.currentTarget.style.display = "none"; }} />
                  </span>
                  <div className="list-main">
                    <div className="admin-row-head">
                      <b>{p.name || p.title || `表情包 #${p.id}`}</b>
                      <span className={`tag ${p.status === "pending" ? "warn" : p.status === "published" ? "is-resolved" : ""}`}>{p.status}</span>
                    </div>
                    <p>{p.description || "无简介"} · 共 {p.asset_count ?? p.sticker_count ?? "—"} 枚</p>
                    <small>创作者：{p.creator_nickname || p.creator?.nickname || `UID ${p.creator_id || ""}`} · {time(p.created_at)}</small>
                  </div>
                  <button
                    type="button"
                    className="btn sm primary"
                    onClick={() => ui.open(`审核表情包 · ${p.name || p.id}`, <EmojiPackReviewDrawer packId={p.id} refreshList={packs.refetch} />, "drawer")}
                  >
                    {self ? "查看详情" : "查看与审核"}
                  </button>
                </div>
              );
            })}
            {!packList.length && <Empty icon="check" title="当前筛选下没有表情包记录" />}
          </div>
        </QueryState>
      ) : (
        <QueryState query={creators}>
          <div className="panel admin-list">
            {creatorList.map((c) => {
              const uid = Number(c.user_id || c.id);
              const self = uid === auth.user?.id;
              return (
                <div className="list-row admin-row" key={uid}>
                  <div className="list-main">
                    <div className="admin-row-head">
                      <b>{c.nickname || c.user?.nickname || `UID ${uid}`}</b>
                      <span className="tag">{c.status}</span>
                    </div>
                    <p>{c.bio || c.reason || c.portfolio_note || "申请成为校园表情创作者"}</p>
                    <small>版本 v{c.version ?? 1} · {time(c.updated_at || c.created_at)}</small>
                  </div>
                  {self ? <span className="muted">本人申请须回避</span> : (
                    <button
                      type="button"
                      className="btn sm primary"
                      onClick={() => ui.open(`创作者审核 · ${c.nickname || uid}`, (
                        <Form
                          fields={[
                            { name: "action", label: "处理决定", options: [["approve", "通过认证"], ["reject", "驳回申请"], ["suspend", "暂停创作者权限"]] },
                            { name: "reason", label: "审核说明（必填）", type: "textarea", required: true },
                          ]}
                          onSubmit={async (v) => {
                            await write(`/api/admin/emoji-creators/${uid}/review`, { action: v.action, reason: v.reason, version: Number(c.version ?? 1) });
                            await creators.refetch();
                            ui.notify("创作者审核结果已保存");
                            ui.close();
                          }}
                        />
                      ))}
                    >
                      审核
                    </button>
                  )}
                </div>
              );
            })}
            {!creatorList.length && <Empty icon="check" title="当前筛选下没有创作者申请" />}
          </div>
        </QueryState>
      )}
    </>
  );
}

const emojiPackStatus: Record<string, string> = {
  pending: "待审核",
  published: "已上架",
  rejected: "已驳回",
  unpublished: "已下架",
  withdrawn: "已撤回",
  superseded: "已被新版本替换",
};

function EmojiPackReviewDrawer({ packId, refreshList }: { packId: string; refreshList: () => Promise<unknown> }) {
  const auth = useAuth();
  const path = `/api/admin/emoji-packs/${encodeURIComponent(packId)}`;
  const q = useApi(path);
  const pack = entity(q.data, "pack", "data");
  const assets = rows(q.data, "assets", "items");
  const [notice, setNotice] = useState("");
  const self = pack.user_id === auth.user?.id;
  const actions: [string, string][] = pack.status === "pending"
    ? [["approve", "通过并上架"], ["reject", "驳回修改"]]
    : pack.status === "published" ? [["unpublish", "下架已发布包"]] : [];

  async function review(action: string, reason: string) {
    setNotice("");
    let conflict = false;
    try {
      await write(`${path}/review`, { action, reason });
    } catch (error) {
      if (!(error instanceof ApiError && error.code === "emoji_pack_conflict")) throw error;
      conflict = true;
    }
    const [detail] = await Promise.all([q.refetch(), refreshList()]);
    setNotice(conflict
      ? detail.isSuccess ? "状态已变化，已刷新" : "状态已变化，请重新加载"
      : "表情包审核已完成");
  }
  return (
    <QueryState query={q}>
      <div className="admin-drawer-stack">
        <p><b>{pack.name || pack.title}</b> · 状态：{emojiPackStatus[pack.status] ?? pack.status}</p>
        {notice && <p role="status">{notice}</p>}
        {pack.description && <p className="muted">{pack.description}</p>}
        <div className="admin-emoji-grid">
          {assets.map((a) => (
            <figure key={a.id} className="admin-emoji-cell">
              <img src={`${path}/assets/${a.id}?variant=thumbnail`} alt={a.shortcode || a.name || ""} loading="lazy" />
              <figcaption>{a.name || a.shortcode || `#${a.id}`}</figcaption>
            </figure>
          ))}
        </div>
        {self ? (
          <p className="muted">当前账号为该表情包提交人，请交由其他管理员完成审核。</p>
        ) : actions.length > 0 && (
          <EmojiPackReviewForm key={pack.status} actions={actions} disabled={q.isFetching} onReview={review} />
        )}
      </div>
    </QueryState>
  );
}

function EmojiPackReviewForm({ actions, disabled, onReview }: {
  actions: [string, string][];
  disabled: boolean;
  onReview: (action: string, reason: string) => Promise<void>;
}) {
  const [action, setAction] = useState(actions[0][0]);
  const reasonRequired = action !== "approve";
  return (
    <Form fields={[]} submit="提交审核结果" submitDisabled={disabled} onSubmit={async (v) => onReview(v.action, v.reason.trim())}>
      <label className="field">
        审核操作
        <select name="action" value={action} onChange={event => setAction(event.target.value)}>
          {actions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
      </label>
      <label className="field">
        {reasonRequired ? "审核说明（必填）" : "审核说明（选填）"}
        <textarea name="reason" rows={4} required={reasonRequired} />
      </label>
    </Form>
  );
}

/* ==================== 6. 管理员协作与团队 ==================== */
export function AdminTeamCollaboration() {
  const auth = useAuth(), ui = useUI();
  const isSuper = auth.user?.role === "super_admin";
  const [view, setView] = useState<"members" | "candidates" | "votes" | "audit">("members");
  const [candSearch, setCandSearch] = useState("");
  const [auditPage, setAuditPage] = useState(1);

  const members = useApi(view === "members" ? "/api/admin/members" : null);
  const candStats = useApi(view === "candidates" ? "/api/admin/candidates/stats" : null);
  const candidates = useApi(view === "candidates" ? query("/api/admin/candidates", { page: 1, page_size: 30, q: candSearch }) : null);
  const invites = useApi(view === "votes" ? "/api/admin/invitations/pending" : null);
  const removals = useApi(view === "votes" ? "/api/admin/removals/pending" : null);
  const superInvites = useApi(isSuper && view === "votes" ? "/api/super/invitations/pending" : null);
  const auditLogs = useApi(view === "audit" ? query("/api/teachers/logs", { page: auditPage, limit: 30 }) : null);

  const memberList = rows(members.data, "items", "members", "admins");
  const candList = rows(candidates.data, "candidates", "items");
  const inviteList = rows(invites.data, "invitations", "items");
  const removalList = rows(removals.data, "targets", "items");
  const superInviteList = rows(superInvites.data, "invitations", "items");
  const logList = rows(auditLogs.data, "logs", "items");

  return (
    <>
      <Head level={2} title="管理员协作" description="查看在任管理团队、从高信誉活跃同学中提名邀请新管理员、参与协作投票与查阅治理记录。">
        <div className="admin-seg" role="group" aria-label="协作模块">
          <button type="button" aria-pressed={view === "members"} onClick={() => setView("members")}>管理团队</button>
          <button type="button" aria-pressed={view === "candidates"} onClick={() => setView("candidates")}>候选人池</button>
          <button type="button" aria-pressed={view === "votes"} onClick={() => setView("votes")}>邀请与罢免投票</button>
          <button type="button" aria-pressed={view === "audit"} onClick={() => setView("audit")}>治理记录</button>
        </div>
      </Head>

      {view === "members" && (
        <QueryState query={members}>
          <div className="panel admin-list">
            {memberList.map((m) => {
              const name = displayName(m.nickname);
              const href = userHref(m.id, auth.user?.id, m.nickname);
              return (
                <div className="list-row admin-row user-list-row" key={m.id}>
                  <span className="avatar user-list-avatar"><ServerAvatar src={m.avatar} name={name} /></span>
                  <div className="list-main">
                    <div className="admin-row-head">
                      {href ? <Link className="author-name-link" to={href}><b>{name}</b></Link> : <b>{name}</b>}
                      <span className={`tag ${m.role === "super_admin" ? "violet" : "brand"}`}>{m.role === "super_admin" ? "超级管理员" : "管理员"}</span>
                    </div>
                    <p>UID #{m.id}{m.credit_score != null ? ` · 诚信分 ${m.credit_score}` : ""}{m.admin_exp != null ? ` · 管理经验 ${m.admin_exp}` : ""}</p>
                  </div>
                  {m.role === "admin" && m.id !== auth.user?.id && (
                    <button
                      type="button"
                      className="btn sm"
                      onClick={() => ui.open(`发起罢免投票 · ${name}`, (
                        <Form
                          fields={[{ name: "reason", label: "罢免理由（必填，管理团队可见）", type: "textarea", required: true }]}
                          submit="提交罢免票"
                          onSubmit={async (v) => {
                            await write(`/api/teachers/admin/${m.id}/vote-remove`, { reason: v.reason });
                            ui.notify("罢免投票已记录");
                            ui.close();
                          }}
                        />
                      ))}
                    >
                      罢免投票
                    </button>
                  )}
                </div>
              );
            })}
            {!memberList.length && <Empty title="暂无管理人员记录" />}
          </div>
        </QueryState>
      )}

      {view === "candidates" && (
        <>
          {candStats.data && (
            <Stats items={[
              [candStats.data.eligible ?? 0, "符合提名条件"],
              [candStats.data.high_credit ?? 0, "高诚信分用户"],
              [candStats.data.active_posters ?? 0, "活跃贡献同学"],
              [candStats.data.total_users ?? 0, "全站用户总数"],
            ]} />
          )}
          <div className="filter-row admin-search">
            <form onSubmit={(e) => { e.preventDefault(); setCandSearch(String(new FormData(e.currentTarget).get("q") || "").trim()); }}>
              <input name="q" aria-label="搜索候选同学" defaultValue={candSearch} placeholder="搜索候选人昵称或 UID" />
              <button className="btn">搜索</button>
            </form>
          </div>
          <QueryState query={candidates}>
            <div className="panel admin-list">
              {candList.map((c) => (
                <div className="list-row admin-row user-list-row" key={c.id}>
                  <span className="avatar user-list-avatar"><ServerAvatar src={c.avatar} name={displayName(c.nickname)} /></span>
                  <div className="list-main">
                    <div className="admin-row-head">
                      <b>{displayName(c.nickname)}</b>
                      <span className="tag">UID #{c.id}</span>
                      {c.pending_invitation_id && <span className="tag warn">邀请流转中</span>}
                    </div>
                    <p>诚信分 {c.credit_score ?? 100} · 发帖 {c.post_count ?? 0} · 回复 {c.reply_count ?? 0}{c.active_days != null ? ` · 活跃 ${c.active_days} 天` : ""}</p>
                  </div>
                  <div className="admin-row-actions">
                    {!c.pending_invitation_id && (
                      <button
                        type="button"
                        className="btn sm primary"
                        onClick={() => ui.open(`提名邀请 · ${displayName(c.nickname)}`, (
                          <Form
                            fields={[{ name: "reason", label: "提名理由（必填）", type: "textarea", required: true }]}
                            submit="发出管理员邀请"
                            onSubmit={async (v) => {
                              await write(`/api/admin/invite/${c.id}`, { reason: v.reason });
                              await candidates.refetch();
                              ui.notify("管理员邀请已发出");
                              ui.close();
                            }}
                          />
                        ))}
                      >
                        发起邀请
                      </button>
                    )}
                    {isSuper && (
                      <button type="button" className="btn sm" onClick={() => void ui.act(async () => { await write("/api/admin/promote", { user_id: c.id }); await candidates.refetch(); }, "已直接提权为管理员")}>直接任命</button>
                    )}
                  </div>
                </div>
              ))}
              {!candList.length && <Empty title="没有符合当前筛选的候选同学" />}
            </div>
          </QueryState>
        </>
      )}

      {view === "votes" && (
        <div className="admin-drawer-stack">
          {isSuper && superInviteList.length > 0 && (
            <section className="panel admin-card">
              <div className="admin-card-head"><h3>待超级管理员终审的邀请</h3><span>投票已达标</span></div>
              <div className="admin-list">
                {superInviteList.map((inv) => (
                  <div className="list-row admin-row" key={inv.id}>
                    <div className="list-main">
                      <b>邀请 {inv.invitee?.nickname || `UID ${inv.invitee_id}`} 担任管理员</b>
                      <p>提名理由：{inv.reason || "—"} · 已获 {inv.vote_count ?? 0} 票</p>
                    </div>
                    <div className="admin-row-actions">
                      <button type="button" className="btn sm primary" onClick={() => void ui.act(async () => { await write(`/api/super/invitations/${inv.id}/approve`, { approved: true }); await superInvites.refetch(); }, "终审已批准")}>批准任命</button>
                      <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/super/invitations/${inv.id}/approve`, { approved: false, reject_reason: "暂缓任命" }); await superInvites.refetch(); }, "已否决该提名")}>否决</button>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          )}

          <section className="panel admin-card">
            <div className="admin-card-head"><h3>管理员提名投票</h3><span>达标后进入超管终审</span></div>
            <QueryState query={invites}>
              <div className="admin-list">
                {inviteList.map((inv) => (
                  <div className="list-row admin-row" key={inv.id}>
                    <div className="list-main">
                      <b>候选人：{inv.invitee?.nickname || `UID ${inv.invitee_id}`}</b>
                      <p>{inv.reason || "管理员协作提名"} · 票数 {inv.vote_count ?? 0}/{inv.required_votes ?? "—"}</p>
                    </div>
                    {inv.has_voted ? <span className="tag">已投票</span> : (
                      <button
                        type="button"
                        className="btn sm primary"
                        onClick={() => ui.open("支持该管理员提名", (
                          <Form
                            fields={[{ name: "reason", label: "附议说明", value: "同意提名", required: true }]}
                            submit="投赞成票"
                            onSubmit={async (v) => {
                              await write(`/api/admin/invitations/${inv.id}/vote`, { reason: v.reason });
                              await invites.refetch();
                              ui.notify("投票已提交");
                              ui.close();
                            }}
                          />
                        ))}
                      >
                        赞成投票
                      </button>
                    )}
                  </div>
                ))}
                {!inviteList.length && <Empty title="暂无进行中的管理员提名投票" />}
              </div>
            </QueryState>
          </section>

          <section className="panel admin-card">
            <div className="admin-card-head"><h3>进行中的罢免投票</h3><span>协作监督</span></div>
            <QueryState query={removals}>
              <div className="admin-list">
                {removalList.map((rm) => {
                  const target = rm.target_admin || rm;
                  return (
                    <div className="list-row admin-row" key={target.id}>
                      <div className="list-main">
                        <b>目标管理员：{target.nickname || `UID ${target.id}`}</b>
                        <p>当前票数 {rm.vote_count ?? 0}/{rm.required_votes ?? "—"}</p>
                      </div>
                      {rm.has_voted ? <span className="tag">已投票</span> : rm.can_vote !== false && (
                        <button
                          type="button"
                          className="btn sm danger"
                          onClick={() => ui.open("参与罢免投票", (
                            <Form
                              fields={[{ name: "reason", label: "投票理由（必填）", type: "textarea", required: true }]}
                              submit="确认投罢免票"
                              onSubmit={async (v) => {
                                await write(`/api/teachers/admin/${target.id}/vote-remove`, { reason: v.reason });
                                await removals.refetch();
                                ui.notify("罢免票已提交");
                                ui.close();
                              }}
                            />
                          ))}
                        >
                          附议罢免
                        </button>
                      )}
                    </div>
                  );
                })}
                {!removalList.length && <Empty title="当前没有进行中的罢免提案" />}
              </div>
            </QueryState>
          </section>
        </div>
      )}

      {view === "audit" && (
        <QueryState query={auditLogs}>
          <div className="panel admin-list">
            {logList.map((l) => (
              <div className="list-row admin-row" key={l.id}>
                <div className="list-main">
                  <b>{l.admin_name || `管理员 #${l.admin_id}`} · {l.action}</b>
                  <p>{[l.target, l.detail].filter(Boolean).join(" · ")}</p>
                  <small>{time(l.created_at)}</small>
                </div>
              </div>
            ))}
            {!logList.length && <Empty title="暂无治理记录" />}
          </div>
          {(auditPage > 1 || logList.length === 30) && <Pagination page={auditPage} hasMore={logList.length === 30} onChange={setAuditPage} />}
        </QueryState>
      )}
    </>
  );
}

/* ==================== 7. 水帖版块全功能管理抽屉 ==================== */
export function AdminWaterSectionDrawer({ item, onSaved }: { item: Entity; onSaved: () => void }) {
  const ui = useUI();
  const slug = encodeURIComponent(item.slug);
  const [sub, setSub] = useState<"profile" | "tags" | "titles" | "mods" | "mutes" | "logs">("profile");

  const mods = useApi(sub === "mods" ? `/api/admin/water/sections/${slug}/moderators` : null);
  const mutes = useApi(sub === "mutes" ? `/api/water/sections/${slug}/mutes?page=1&limit=30` : null);
  const logs = useApi(sub === "logs" ? `/api/water/sections/${slug}/moderation/logs?page=1&limit=30` : null);

  const tagList = rows(item, "tags");
  const titleList = rows(item, "level_titles");
  const modList = rows(mods.data, "moderators", "items");
  const muteList = rows(mutes.data, "items", "mutes");
  const logList = rows(logs.data, "items", "logs");

  return (
    <div className="admin-drawer-stack">
      <div className="admin-seg" role="group" aria-label="版块配置项">
        {([["profile", "基础资料"], ["tags", "版块标签"], ["titles", "等级称号"], ["mods", "版主权限"], ["mutes", "禁言管理"], ["logs", "版块日志"]] as const).map(([k, l]) => (
          <button key={k} type="button" aria-pressed={sub === k} onClick={() => setSub(k)}>{l}</button>
        ))}
      </div>

      {sub === "profile" && (
        <Form
          fields={[
            { name: "title", label: "版块名称", value: item.title, required: true },
            { name: "subtitle", label: "副标题", value: item.subtitle || "" },
            { name: "description", label: "版块说明", type: "textarea", value: item.description || "" },
            { name: "notice_text", label: "版块置顶公告", type: "textarea", value: item.notice_text || "" },
            { name: "publish_action_text", label: "发帖按钮引导文案", value: item.publish_action_text || "" },
            { name: "color_hex", label: "主题色 Hex（可选）", value: item.color_hex || "" },
            { name: "sort_order", label: "排序权重", type: "number", value: item.sort_order ?? 0 },
            { name: "reason", label: "修改原因（必填）", required: true },
          ]}
          onSubmit={async (values) => {
            await write(`/api/water/sections/${slug}`, { ...values, sort_order: Number(values.sort_order) || 0 }, "PATCH");
            onSaved();
            ui.notify("版块资料已更新");
            ui.close();
          }}
        />
      )}

      {sub === "tags" && (
        <div className="admin-drawer-stack">
          <Form
            fields={[
              { name: "name", label: "新标签名称", required: true },
              { name: "slug", label: "标签标识 (英文/拼音)", required: true },
              { name: "sort_order", label: "排序", type: "number", value: 0 },
            ]}
            submit="新增标签"
            onSubmit={async (v) => {
              await write(`/api/water/sections/${slug}/tags`, { name: v.name, slug: v.slug, sort_order: Number(v.sort_order) || 0 });
              onSaved();
              ui.notify("版块标签已创建");
            }}
          />
          <div className="panel admin-list">
            {tagList.map((t) => (
              <div className="list-row admin-row" key={t.id}>
                <div className="list-main">
                  <b>{t.name}</b> <small className="mono">{t.slug}</small>
                </div>
                <button
                  type="button"
                  className="btn sm"
                  onClick={() => void ui.act(async () => {
                    await write(`/api/water/sections/${slug}/tags/${t.id}/status`, { is_enabled: t.is_enabled === false }, "PATCH");
                    onSaved();
                  }, t.is_enabled === false ? "标签已启用" : "标签已停用")}
                >
                  {t.is_enabled === false ? "启用" : "停用"}
                </button>
              </div>
            ))}
            {!tagList.length && <p className="muted">当前版块暂未设置子标签</p>}
          </div>
        </div>
      )}

      {sub === "titles" && (
        <Form
          fields={Array.from({ length: 8 }, (_, idx) => {
            const lv = idx + 1;
            const found = titleList.find((x) => Number(x.level) === lv);
            return { name: `lv_${lv}`, label: `Lv.${lv} 专属头衔`, value: found?.title || "" };
          })}
          submit="保存等级称号"
          onSubmit={async (v) => {
            const titles = Array.from({ length: 8 }, (_, idx) => ({ level: idx + 1, title: String(v[`lv_${idx + 1}`] || "").trim() })).filter((t) => t.title);
            await write(`/api/water/sections/${slug}/level-titles`, { titles }, "PATCH");
            onSaved();
            ui.notify("等级称号已更新");
          }}
        />
      )}

      {sub === "mods" && (
        <div className="admin-drawer-stack">
          <Form
            fields={[
              { name: "user_id", label: "任命版主 UID", type: "number", min: 1, required: true },
              { name: "remark", label: "任命备注", value: "版块协管版主" },
            ]}
            submit="任命版主（授予置顶/加精/隐藏/删评/禁言权限）"
            onSubmit={async (v) => {
              await write(`/api/admin/water/sections/${slug}/moderators`, {
                user_id: Number(v.user_id),
                can_pin: true,
                can_feature: true,
                can_hide_post: true,
                can_delete_reply: true,
                can_mute_user: true,
                can_edit_section_profile: false,
                can_manage_tags: true,
                remark: v.remark,
              });
              await mods.refetch();
              ui.notify("版主已任命");
            }}
          />
          <QueryState query={mods}>
            <div className="panel admin-list">
              {modList.map((m) => (
                <div className="list-row admin-row" key={m.id}>
                  <div className="list-main">
                    <b>{m.user?.nickname || m.nickname || `UID ${m.user_id}`}</b>
                    <p>UID #{m.user_id}{m.remark ? ` · ${m.remark}` : ""}</p>
                  </div>
                  <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/admin/water/sections/${slug}/moderators/${m.id}`, {}, "DELETE"); await mods.refetch(); }, "已卸任版主")}>卸任</button>
                </div>
              ))}
              {!modList.length && <Empty title="当前版块暂无协管版主" />}
            </div>
          </QueryState>
        </div>
      )}

      {sub === "mutes" && (
        <div className="admin-drawer-stack">
          <Form
            fields={[
              { name: "user_id", label: "禁言用户 UID", type: "number", min: 1, required: true },
              { name: "duration_minutes", label: "禁言时长", value: "1440", options: [["60", "1 小时"], ["1440", "1 天"], ["4320", "3 天"], ["10080", "7 天"]] },
              { name: "reason", label: "禁言原因（必填）", required: true },
            ]}
            submit="执行版块禁言"
            onSubmit={async (v) => {
              await write(`/api/water/sections/${slug}/users/${Number(v.user_id)}/mute`, { duration_minutes: Number(v.duration_minutes) || 1440, reason: v.reason });
              await mutes.refetch();
              ui.notify("已执行版块禁言");
            }}
          />
          <QueryState query={mutes}>
            <div className="panel admin-list">
              {muteList.map((mu) => (
                <div className="list-row admin-row" key={mu.id || mu.user_id}>
                  <div className="list-main">
                    <b>{mu.user?.nickname || `UID ${mu.user_id}`}</b>
                    <p>{mu.reason} · 到期 {time(mu.expires_at || mu.muted_until)}</p>
                  </div>
                  <button type="button" className="btn sm" onClick={() => void ui.act(async () => { await write(`/api/water/sections/${slug}/users/${mu.user_id}/mute`, { reason: "提前解禁" }, "DELETE"); await mutes.refetch(); }, "已解除版块禁言")}>解禁</button>
                </div>
              ))}
              {!muteList.length && <Empty title="当前版块没有生效中的禁言" />}
            </div>
          </QueryState>
        </div>
      )}

      {sub === "logs" && (
        <QueryState query={logs}>
          <div className="panel admin-list">
            {logList.map((l, i) => (
              <div className="list-row admin-row" key={l.id || i}>
                <div className="list-main">
                  <b>{l.operator_name || l.admin_name || `操作人 #${l.operator_id || ""}`} · {l.action}</b>
                  <p>{l.reason || l.detail || ""}</p>
                  <small>{time(l.created_at)}</small>
                </div>
              </div>
            ))}
            {!logList.length && <Empty title="暂无版块管理日志" />}
          </div>
        </QueryState>
      )}
    </div>
  );
}

/* ==================== 8. 竞赛管理 & 抽奖管理 ==================== */
export function AdminCompetitionsModule() {
  const ui = useUI();
  const q = useApi("/api/competitions?page=1&page_size=30");
  const items = rows(q.data, "competitions", "items");

  function openEditor(item?: Entity) {
    ui.open(item ? `编辑竞赛 · ${item.title}` : "发布竞赛信息", (
      <Form
        fields={[
          { name: "title", label: "竞赛名称", value: item?.title || "", required: true },
          { name: "organizer", label: "主办单位", value: item?.organizer || "" },
          { name: "level", label: "赛事级别", value: item?.level || "校级", options: [["国家级", "国家级"], ["省级", "省级"], ["校级", "校级"], ["院级", "院级"]] },
          { name: "registration_deadline", label: "报名截止日期 (YYYY-MM-DD)", value: String(item?.registration_deadline || "").slice(0, 10) },
          { name: "official_url", label: "官方通知链接", value: item?.official_url || "" },
          { name: "description", label: "赛事说明与参赛要求", type: "textarea", value: item?.description || "", required: true },
        ]}
        onSubmit={async (v) => {
          await write(item ? `/api/admin/competitions/${item.id}` : "/api/admin/competitions", v, item ? "PUT" : "POST");
          await q.refetch();
          ui.notify(item ? "竞赛已更新" : "竞赛已发布");
          ui.close();
        }}
      />
    ), "drawer");
  }

  return (
    <>
      <Head level={2} title="竞赛事件管理" description="维护校园竞赛日历、报名截止提醒与赛事说明。">
        <button type="button" className="btn primary" onClick={() => openEditor()}>新增竞赛</button>
        <button type="button" className="btn" onClick={() => void q.refetch()}>刷新</button>
      </Head>
      <QueryState query={q}>
        <div className="panel admin-list">
          {items.map((c) => (
            <div className="list-row admin-row" key={c.id}>
              <div className="list-main">
                <div className="admin-row-head">
                  <b>{c.title}</b>
                  {c.level && <span className="tag brand">{c.level}</span>}
                </div>
                <p>{[c.organizer, c.registration_deadline && `截止 ${String(c.registration_deadline).slice(0, 10)}`].filter(Boolean).join(" · ")}</p>
              </div>
              <div className="admin-row-actions">
                <button type="button" className="btn sm" onClick={() => openEditor(c)}>编辑</button>
                <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/admin/competitions/${c.id}`, {}, "DELETE"); await q.refetch(); }, "竞赛已删除")}>删除</button>
              </div>
            </div>
          ))}
          {!items.length && <Empty title="暂无竞赛记录" />}
        </div>
      </QueryState>
    </>
  );
}

export function AdminLotteryModule() {
  const ui = useUI();
  const current = useApi("/api/lottery/current");
  const participants = useApi("/api/super/lottery/participants");
  const ev = entity(current.data, "event");
  const partList = rows(participants.data, "participants", "items");

  return (
    <>
      <Head level={2} title="校园抽奖管理" description="创建福利抽奖活动、手动开奖及核查参与记录（超级管理员专属）。">
        <button
          type="button"
          className="btn primary"
          onClick={() => ui.open("创建新抽奖活动", (
            <Form
              fields={[
                { name: "title", label: "活动标题", required: true },
                { name: "prize_name", label: "奖品名称", required: true },
                { name: "draw_time", label: "开奖时间 (ISO 或 YYYY-MM-DD HH:mm:ss)", required: true },
                { name: "description", label: "活动规则说明", type: "textarea", required: true },
              ]}
              submit="创建活动"
              onSubmit={async (v) => {
                await write("/api/super/lottery", v);
                await current.refetch();
                ui.notify("抽奖活动已创建");
                ui.close();
              }}
            />
          ))}
        >
          发起抽奖
        </button>
        <button type="button" className="btn" onClick={() => { void current.refetch(); void participants.refetch(); }}>刷新</button>
      </Head>

      <QueryState query={current}>
        {ev.id ? (
          <section className="panel panel-pad admin-card">
            <div className="admin-row-head">
              <b>{ev.title || ev.prize_name}</b>
              <span className={`tag ${ev.status === 0 ? "is-resolved" : ""}`}>{ev.status === 0 ? "进行中" : "已开奖"}</span>
            </div>
            <p>{ev.description}</p>
            <p className="muted">参与人数：{current.data?.participant_count ?? 0} · 开奖时间：{ev.draw_time}{ev.winner?.nickname ? ` · 中奖者：${ev.winner.nickname}` : ""}</p>
            <div className="form-actions">
              {ev.status === 0 && (
                <button type="button" className="btn primary" onClick={() => void ui.act(async () => { await write(`/api/admin/lottery/${ev.id}/draw`); await current.refetch(); }, "已完成开奖")}>立即开奖</button>
              )}
              <button type="button" className="btn danger" onClick={() => void ui.act(async () => { await write(`/api/super/lottery/${ev.id}`, {}, "DELETE"); await current.refetch(); }, "活动已删除")}>删除活动</button>
            </div>
          </section>
        ) : (
          <div className="panel"><Empty title="当前没有进行中的抽奖活动" /></div>
        )}
      </QueryState>

      {partList.length > 0 && (
        <section className="panel admin-card">
          <div className="admin-card-head"><h3>参与人列表</h3><span>共 {partList.length} 条</span></div>
          <div className="admin-list">
            {partList.map((p, idx) => (
              <div className="list-row admin-row" key={`${p.event_id}:${p.user_id}:${idx}`}>
                <div className="list-main">
                  <b>{p.nickname || p.user?.nickname || `UID ${p.user_id}`}</b>
                  <small>活动 #{p.event_id} · UID #{p.user_id}</small>
                </div>
                {p.event_id && p.user_id && (
                  <button type="button" className="btn sm danger" onClick={() => void ui.act(async () => { await write(`/api/super/lottery/participants/${p.event_id}/${p.user_id}`, {}, "DELETE"); await participants.refetch(); }, "已移除该参与记录")}>移除</button>
                )}
              </div>
            ))}
          </div>
        </section>
      )}
    </>
  );
}
