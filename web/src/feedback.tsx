import {
  Link,
  useNavigate,
  useParams,
  useSearchParams,
} from "react-router-dom";
import { entity, query, rows, time, useApi, write, type Entity } from "./api";
import { Empty, Form, Head, Pagination, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
import { uploadIDs } from "./community";
const states: Record<string, string> = {
  pending: "待受理",
  accepted: "已受理",
  waiting_user: "待补充",
  investigating: "定位中",
  fixing: "修复中",
  testing: "测试中",
  resolved: "已解决",
  closed: "已关闭",
};
export function Feedback({ admin = false }: { admin?: boolean }) {
  const auth = useAuth(),
    ui = useUI(),
    nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const status = params.get("status") || "",
    page = Number(params.get("page")) || 1;
  const base = admin ? "/api/admin/feedback" : "/api/feedback";
  const q = useApi(
    auth.user
      ? query(`${base}/tickets`, {
          ...(admin ? { status } : { status_group: status }),
          page,
          limit: 20,
        })
      : null,
  );
  if (!auth.user)
    return (
      <Empty title="登录后查看工单">
        <button className="btn primary" onClick={auth.login}>
          登录
        </button>
      </Empty>
    );
  return (
    <>
      <Head
        title={admin ? "工单管理" : "反馈与工单"}
        description="提交问题、补充信息，查看处理进展"
      >
        {!admin && (
          <button
            className="btn primary"
            onClick={() =>
              ui.open(
                "提交反馈",
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
                      label: "附件图片，最多 6 张",
                      type: "file",
                      multiple: true,
                    },
                  ]}
                  submit="提交工单"
                  onSubmit={async (data, fd) => {
                    const image_ids = await uploadIDs(fd);
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
            新建工单
          </button>
        )}
      </Head>
      <Tabs
        tabs={
          admin
            ? [["", "全部"], ...Object.entries(states)]
            : [
                ["", "全部"],
                ["processing", "处理中"],
                ["waiting_user", "待补充"],
                ["resolved", "已解决"],
              ]
        }
        value={status}
        onChange={(status) => setParams({ status, page: "1" })}
      />
      <div className="panel">
        <QueryState query={q}>
          {rows(q.data, "tickets").map((t) => (
            <Link
              className="ticket-row"
              key={t.id}
              to={admin ? `/admin/feedback/${t.id}` : `/feedback/${t.id}`}
            >
              <span className="mono">{t.ticket_no}</span>
              <div>
                <b>{t.title}</b>
                <p>{t.latest_reply_snippet || t.description}</p>
              </div>
              <span className="tag">{states[t.status] || t.status}</span>
              <span>{time(t.updated_at)}</span>
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
    ui = useUI();
  const base = admin ? "/api/admin/feedback" : "/api/feedback";
  const q = useApi(`${base}/tickets/${id}`);
  const ticket = entity(q.data, "ticket");
  return (
    <>
      <Head title={ticket.title || "工单详情"} description={ticket.ticket_no}>
        <Link className="btn" to={admin ? "/admin" : "/feedback"}>
          返回列表
        </Link>
      </Head>
      <QueryState query={q}>
        <div className="ticket-layout">
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
                </div>
                {rows(q.data, "messages").map((m) => (
                  <div
                    key={m.id}
                    className={`thread-message ${m.sender_type === "admin" ? "official" : ""} ${m.visible_to_user === false ? "internal" : ""}`}
                  >
                    <div className="message-meta">
                      <b>
                        {m.sender_type === "admin" ? "官方回复" : "用户补充"}
                      </b>
                      {m.visible_to_user === false && (
                        <span className="tag">内部备注</span>
                      )}
                      <time>{time(m.created_at)}</time>
                    </div>
                    <div className="bubble details-text">{m.content}</div>
                  </div>
                ))}
              </div>
              <div className="reply-form">
                <Form
                  fields={[
                    {
                      name: "content",
                      label: admin ? "官方回复 / 内部备注" : "补充信息",
                      type: "textarea",
                      required: true,
                    },
                    ...(admin
                      ? [
                          {
                            name: "scope",
                            label: "可见范围",
                            options: [
                              ["public", "用户可见"],
                              ["internal", "内部备注"],
                            ] as [string, string][],
                          },
                        ]
                      : []),
                    {
                      name: "images",
                      label: "附件图片",
                      type: "file",
                      multiple: true,
                    },
                  ]}
                  submit="发送"
                  onSubmit={async (data, fd) => {
                    const image_ids = await uploadIDs(fd);
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
              </div>
            </div>
          </div>
          <aside className="ticket-aside">
            <div className="panel panel-pad">
              <h3>处理进度</h3>
              <span className="tag brand">
                {states[ticket.status] || ticket.status}
              </span>
              {admin ? (
                <Form
                  fields={[
                    {
                      name: "status",
                      label: "处理状态",
                      value: ticket.status,
                      options: Object.entries(states),
                    },
                    {
                      name: "status_note",
                      label: "处理说明",
                      type: "textarea",
                      required: true,
                    },
                  ]}
                  onSubmit={async (data) => {
                    await write(
                      `${base}/tickets/${id}/status`,
                      { ...data, expected_status: ticket.status },
                      "PATCH",
                    );
                    await q.refetch();
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
            <div className="panel panel-pad">
              <h3>操作记录</h3>
              <ul className="event-list">
                {rows(q.data, "history").map((h) => (
                  <li key={h.id}>
                    {states[h.new_status] || h.new_status} · {h.note}
                    <br />
                    <span className="muted">{time(h.created_at)}</span>
                  </li>
                ))}
              </ul>
            </div>
          </aside>
        </div>
      </QueryState>
    </>
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
        <Empty title="登录后查看通知">
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
