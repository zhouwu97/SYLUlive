import {
  Link,
  useLocation,
  useNavigate,
  useParams,
  useSearchParams,
} from "react-router-dom";
import { entity, query, rows, time, useApi, write, type Entity } from "./api";
import { Empty, Form, Head, Pagination, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
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
import "./feedback.css";
export const states: Record<string, string> = {
  pending: "待受理",
  accepted: "已受理",
  waiting_user: "待补充",
  investigating: "定位中",
  fixing: "修复中",
  testing: "测试中",
  resolved: "已解决",
  closed: "已关闭",
};
// 状态色只做辅助，文字本身始终表达状态：待受理需要管理员动作，待补充等用户，
// 处理中各阶段共用品牌色，已解决为成功色，已关闭弱化。
const statusTones: Record<string, string> = {
  pending: "warn",
  waiting_user: "indigo",
  accepted: "brand",
  investigating: "brand",
  fixing: "brand",
  testing: "brand",
  resolved: "is-resolved",
};
export function StatusTag({ status }: { status: string }) {
  return (
    <span className={`tag ticket-status ${statusTones[status] || ""}`}>
      {states[status] || status}
    </span>
  );
}
export const ticketTypes: Record<string, string> = {
  bug: "问题反馈",
  suggestion: "功能建议",
  other: "其他",
};
const priorities: Record<string, string> = {
  P0: "P0 紧急",
  P1: "P1 重要",
  P2: "P2 一般",
  P3: "P3 次要",
};
const listDescription = (admin: boolean) =>
  admin
    ? "处理用户反馈的问题与建议，回复、内部备注和状态变更都会留下记录"
    : "创建工单反馈 Bug 或建议，查看处理进度与管理员回复";
// 工单列表的筛选条件只写在列表自己的地址里，进详情时必须把它带上，
// 否则返回会掉回「全部 / 第 1 页」，管理员刚在看的那批工单就找不回来了。
// 管理端列表是 /admin 的 feedback 标签页，不是独立路由。
export function ticketRowHREF(admin: boolean, id: unknown, search: string) {
  return admin
    ? `/admin/feedback/${id}${search}`
    : `/feedback/${id}${search}`;
}
export function ticketListHREF(admin: boolean, search: string) {
  if (!admin) return `/feedback${search}`;
  const params = new URLSearchParams(search);
  params.set("tab", "feedback");
  return `/admin?${params}`;
}
// 管理端列表按服务端 status_filter 分组筛选：“处理中”包含已受理、定位中、修复中，
// 服务端不支持按这三个单独状态过滤，所以不能直接用 states 的八个值当筛选项。
export const adminTicketFilters: [string, string][] = [
  ["", "全部"],
  ["pending", "待受理"],
  ["processing", "处理中"],
  ["testing", "测试中"],
  ["waiting_user", "待补充"],
  ["resolved", "已解决"],
  ["closed", "已关闭"],
  ["unviewed", "未查看"],
];
export function Feedback({ admin = false }: { admin?: boolean }) {
  const auth = useAuth(),
    ui = useUI(),
    nav = useNavigate(),
    location = useLocation();
  const [params, setParams] = useSearchParams();
  const status = admin && params.get("status") === "all" ? "" : params.get("status") || "",
    page = Number(params.get("page")) || 1;
  const base = admin ? "/api/admin/feedback" : "/api/feedback";
  const q = useApi(
    auth.user
      ? query(`${base}/tickets`, {
          ...(admin ? { status_filter: status } : { status_group: status }),
          page,
          limit: 20,
        })
      : null,
  );
  if (!auth.user)
    return (
      <>
        <Head
          title={admin ? "工单管理" : "我的工单"}
          description={listDescription(admin)}
          level={admin ? 2 : 1}
        />
        <Empty icon="lock" title="登录后查看工单" description="登录后可提交问题并跟进处理进展。">
          <button className="btn primary" onClick={auth.login}>
            登录
          </button>
        </Empty>
      </>
    );
  return (
    <>
      <Head
        title={admin ? "工单管理" : "我的工单"}
        description={listDescription(admin)}
        level={admin ? 2 : 1}
      >
        {!admin && (
          <button
            className="btn primary"
            onClick={() =>
              ui.open(
                "创建工单",
                <Form
                  fields={[
                    {
                      name: "type",
                      label: "类型",
                      options: [
                        ["bug", "问题反馈"],
                        ["suggestion", "功能建议"],
                        ["other", "其他"],
                      ],
                    },
                    { name: "title", label: "标题", required: true },
                    {
                      name: "description",
                      label: "具体描述",
                      type: "textarea",
                      required: true,
                    },
                    {
                      name: "steps_to_reproduce",
                      label: "复现步骤",
                      type: "textarea",
                    },
                    {
                      name: "images",
                      label: `附件图片，最多 ${ticketAttachmentLimits.maxCount} 张`,
                      type: "file",
                      multiple: true,
                      accept: attachmentAccept,
                      help: attachmentHelp,
                    },
                  ]}
                  submit="提交工单"
                  onSubmit={async (data, fd) => {
                    const image_ids = await uploadIDs(
                      fd,
                      ticketAttachmentLimits,
                    );
                    const { images, ...body } = data;
                    const result = await write(`${base}/tickets`, {
                      ...body,
                      image_ids,
                      app_version: "web-0.1.0",
                      current_route: location.pathname,
                    });
                    ui.close();
                    await q.refetch();
                    nav(`/feedback/${result.ticket?.id || result.id}`);
                  }}
                />,
              )
            }
          >
            创建工单
          </button>
        )}
      </Head>
      <Tabs
        tabs={
          admin
            ? adminTicketFilters
            : [
                ["", "全部"],
                ["processing", "处理中"],
                ["waiting_user", "待补充"],
                ["resolved", "已解决"],
              ]
        }
        value={status}
        onChange={(status) => setParams({ ...(admin ? {tab: "feedback"} : {}), status: admin && !status ? "all" : status, page: "1" })}
      />
      <div className="panel ticket-list">
        <QueryState query={q}>
          {rows(q.data, "tickets").map((t) => (
            <Link
              className="ticket-row"
              key={t.id}
              to={ticketRowHREF(admin, t.id, location.search)}
            >
              <span className="mono">{t.ticket_no}</span>
              <div className="ticket-row-copy">
                <b>{t.title}</b>
                <p>{t.latest_reply_snippet || t.description}</p>
              </div>
              <StatusTag status={t.status} />
              <time className="ticket-row-time" dateTime={t.updated_at}>
                {time(t.updated_at)}
              </time>
            </Link>
          ))}
          {!rows(q.data, "tickets").length && <Empty />}
        </QueryState>
      </div>
      <Pagination
        page={page}
        hasMore={rows(q.data, "tickets").length === 20}
        onChange={(page) => setParams({ status, page: String(page) })}
      />
    </>
  );
}
export function TicketDetail({ admin = false }: { admin?: boolean }) {
  const { id } = useParams(),
    ui = useUI(),
    location = useLocation();
  const base = admin ? "/api/admin/feedback" : "/api/feedback";
  const q = useApi(`${base}/tickets/${id}`);
  const ticket = entity(q.data, "ticket");
  const back = ticketListHREF(admin, location.search);
  const closedForUser = !admin && ticket.status === "closed";
  const closedForAdmin = admin && ticket.status === "closed";
  const messages = rows(q.data, "messages"),
    history = rows(q.data, "history");
  // 创建时只有描述进入初始消息，复现步骤等结构化字段要单独展示，否则网页端看不到。
  const extraFields = (
    [
      ["复现步骤", ticket.steps_to_reproduce],
      ["实际结果", ticket.actual_result],
      ["期望结果", ticket.expected_result],
    ] as [string, unknown][]
  ).filter(([, value]) => typeof value === "string" && value.trim());
  const headline = [
    ticket.ticket_no,
    ticketTypes[ticket.type],
    ticket.created_at && `提交于 ${time(ticket.created_at)}`,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <>
      <Head title={ticket.title || "工单详情"} description={headline}>
        <Link className="btn" to={back}>
          返回列表
        </Link>
      </Head>
      <QueryState query={q}>
        <div className="ticket-layout ticket-detail">
          <div className="ticket-main">
            <div className="panel">
              <div className="thread">
                <div className="thread-message">
                  <div className="message-meta">
                    <b>初始提交</b>
                    <time>{time(ticket.created_at)}</time>
                  </div>
                  <div className="bubble details-text">
                    {q.data?.initial_submission?.content || ticket.description}
                  </div>
                  {extraFields.length > 0 && (
                    <dl className="ticket-extra">
                      {extraFields.map(([label, value]) => (
                        <div key={label}>
                          <dt>{label}</dt>
                          <dd className="details-text">{String(value)}</dd>
                        </div>
                      ))}
                    </dl>
                  )}
                  <TicketAttachments data={initialAttachmentIDs(q.data)} scope="初始提交附件" />
                </div>
                {messages.map((m) => (
                  <div
                    key={m.id}
                    className={`thread-message ${m.sender_type === "admin" ? "official" : ""} ${isInternalMessage(m) ? "internal" : ""}`}
                  >
                    <div className="message-meta">
                      <b>{messageSenderLabel(m)}</b>
                      {isInternalMessage(m) && <span className="tag">内部备注</span>}
                      <time>{time(m.created_at)}</time>
                    </div>
                    <div className="bubble details-text">{m.content}</div>
                    <TicketAttachments data={messageAttachmentIDs(m)} scope="本条消息附件" />
                  </div>
                ))}
              </div>
              <div className="reply-form">
                {closedForUser ? (
                  <div className="panel panel-pad">
                    <b>该工单已关闭</b>
                    <p className="muted">
                      关闭后不能再追加回复；如问题仍在，请在右侧重新打开工单，
                      再补充新的信息与截图。
                    </p>
                  </div>
                ) : (
                  <>
                  {closedForAdmin && <p className="muted">该工单已关闭，请先修改处理状态，再公开回复。内部备注仍可保存。</p>}
                  <Form
                    // 表单非受控：消息数变化即发送成功，换 key 清空输入，避免重复发送同一条回复。
                    key={`${messages.length}:${closedForAdmin}`}
                    fields={[
                      ...(admin
                        ? [
                            {
                              name: "scope",
                              label: "回复方式",
                              value: closedForAdmin ? "internal" : "public",
                              options: closedForAdmin ? [["internal", "内部备注（仅管理员可见）"]] as [string, string][] : [
                                ["public", "公开回复（用户可见）"],
                                ["internal", "内部备注（仅管理员可见）"],
                              ] as [string, string][],
                            },
                          ]
                        : []),
                      {
                        name: "content",
                        label: admin ? "回复内容" : "补充信息",
                        type: "textarea",
                        required: true,
                      },
                      {
                        name: "images",
                        label: "附件图片",
                        type: "file",
                        multiple: true,
                        accept: attachmentAccept,
                        help: attachmentHelp,
                      },
                    ]}
                    submit={closedForAdmin ? "保存备注" : "发送"}
                    onSubmit={async (data, fd) => {
                      const image_ids = await uploadIDs(
                        fd,
                        ticketAttachmentLimits,
                      );
                      await write(`${base}/tickets/${id}/messages`, {
                        content: data.content,
                        image_ids,
                        ...(admin
                          ? { visible_to_user: data.scope === "public" }
                          : {}),
                      });
                      await q.refetch();
                      ui.notify("回复已发送");
                    }}
                  />
                  </>
                )}
              </div>
            </div>
          </div>
          <aside className="ticket-aside">
            <div className="panel panel-pad">
              <div className="ticket-aside-head">
                <h3>处理进度</h3>
                <StatusTag status={ticket.status} />
              </div>
              {admin ? (
                <Form
                  key={`${ticket.status}:${history.length}`}
                  submit="更新状态"
                  fields={[
                    {
                      name: "status",
                      label: "处理状态",
                      value: ticket.status,
                      options: Object.entries(states),
                    },
                    {
                      // 与 App 一致：说明选填，服务端也不要求；填写后随状态变更通知用户。
                      name: "status_note",
                      label: "进度说明（选填）",
                      type: "textarea",
                      help: "如版本号或修复说明，会随状态变更通知用户",
                    },
                  ]}
                  onSubmit={async (data) => {
                    await write(
                      `${base}/tickets/${id}/status`,
                      { ...data, expected_status: ticket.status },
                      "PATCH",
                    );
                    await q.refetch();
                    ui.notify("处理进度已更新");
                  }}
                />
              ) : (
                <div className="section">
                  {ticket.status === "resolved" && (
                    <button
                      className="btn"
                      onClick={() =>
                        ui.act(() =>
                          write(`${base}/tickets/${id}/confirm-resolved`),
                        )
                      }
                    >
                      确认解决
                    </button>
                  )}
                  {["resolved", "closed"].includes(ticket.status) && (
                    <button
                      className="btn"
                      onClick={() =>
                        ui.open(
                          "重新打开工单",
                          <Form
                            fields={[
                              {
                                name: "reason",
                                label: "仍未解决的问题",
                                type: "textarea",
                                required: true,
                              },
                            ]}
                            onSubmit={async (data) => {
                              await write(`${base}/tickets/${id}/reopen`, data);
                              await q.refetch();
                              ui.close();
                            }}
                          />,
                        )
                      }
                    >
                      重新打开
                    </button>
                  )}
                </div>
              )}
            </div>
            {admin && <TicketFacts ticket={ticket} />}
            <div className="panel panel-pad">
              <h3>操作记录</h3>
              <ol className="event-list ticket-timeline">
                {history.map((h) => (
                  <li key={h.id}>
                    <b>{states[h.new_status] || h.new_status}</b>
                    {h.note && <span> · {h.note}</span>}
                    <time className="muted" dateTime={h.created_at}>
                      {time(h.created_at)}
                    </time>
                  </li>
                ))}
              </ol>
              {!history.length && <p className="muted">暂无操作记录</p>}
            </div>
          </aside>
        </div>
      </QueryState>
    </>
  );
}
// 管理端排查所需的提交上下文；只展示接口已返回的字段，缺失的行直接省略。
function TicketFacts({ ticket }: { ticket: Entity }) {
  const facts: [string, unknown][] = [
    [
      "提交人",
      ticket.user_id &&
        `${ticket.user?.nickname || "未设置昵称"} · UID ${ticket.user_id}`,
    ],
    ["类型", ticketTypes[ticket.type] || ticket.type],
    ["优先级", priorities[ticket.priority] || ticket.priority],
    ["负责人", ticket.assignee_admin?.nickname],
    [
      "客户端",
      [ticket.app_version, ticket.build_number && `(${ticket.build_number})`]
        .filter(Boolean)
        .join(" "),
    ],
    ["设备", [ticket.device_model, ticket.os_version].filter(Boolean).join(" · ")],
    ["网络", ticket.network_type],
    ["页面", ticket.current_route],
  ];
  const visible = facts.filter(([, value]) => value);
  if (!visible.length) return null;
  return (
    <div className="panel panel-pad">
      <h3>工单信息</h3>
      <dl className="ticket-facts">
        {visible.map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{String(value)}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}
export function Notifications() {
  const auth = useAuth(),
    ui = useUI(),
    nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const q = useApi(auth.user ? "/api/user/notifications" : null);
  const unread = params.get("unread") === "1";
  const values = rows(q.data, "notifications").filter(
    (x) => !unread || !x.is_read,
  );
  async function open(n: Entity) {
    if (
      !(await ui.act(
        () => write("/api/user/notifications/read-selected", { ids: [n.id] }),
        "已读状态已更新",
      ))
    )
      return;
    if (n.post_id) nav(`/post/${n.post_id}`);
    else if (n.type?.startsWith("feedback"))
      nav(
        n.type === "feedback_admin_update"
          ? `/admin/feedback/${n.related_id}`
          : `/feedback/${n.related_id}`,
      );
    else if(n.type==='course_evaluation_result') nav(`/profile?tab=evaluations`);
    else if(n.type==='canteen_pending'||n.type==='canteen_review_result') nav('/canteen?tab=mine');
    else if(n.type==='competition_award_verification') nav('/competition?tab=awards');
    else
      ui.open(
        "通知详情",
        <>
          <p className="details-text">{n.content}</p>
          <p className="muted">
            此通知的目标类型尚未接入网页详情，请在 App 中查看。
          </p>
        </>,
      );
  }
  return (
    <>
      <Head title="通知中心" description="评论、审核结果与工单进展">
        <button
          className="btn"
          disabled={!auth.user}
          onClick={() => ui.act(() => write("/api/user/notifications/read"))}
        >
          全部已读
        </button>
      </Head>
      <Tabs
        tabs={[
          ["0", "全部"],
          ["1", "未读"],
        ]}
        value={unread ? "1" : "0"}
        onChange={(unread) => setParams({ unread })}
      />
      {!auth.user ? (
        <Empty icon="lock" title="登录后查看通知">
          <button className="btn primary" onClick={auth.login}>
            登录
          </button>
        </Empty>
      ) : (
        <div className="panel">
          <QueryState query={q}>
            {values.map((n) => (
              <button
                key={n.id}
                className={`notification-row ${n.is_read ? "" : "unread"}`}
                onClick={() => open(n)}
              >
                <div className="notification-copy">
                  <b>{n.content}</b>
                  <p>{time(n.created_at)}</p>
                </div>
                {!n.is_read && <span className="tag brand">未读</span>}
              </button>
            ))}
            {!values.length && <Empty title="没有新的通知" />}
          </QueryState>
        </div>
      )}
    </>
  );
}
