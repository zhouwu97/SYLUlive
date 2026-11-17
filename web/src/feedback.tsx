import {
  Link,
  useLocation,
  useNavigate,
  useParams,
  useSearchParams,
} from "react-router-dom";
import {useEffect,useRef,useState} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import { captureAuthSession, entity, errorText, query, request, rows, time, useApi, write, type Entity } from "./api";
import { Empty, Form, Head, Icon, Pagination, QueryState, Tabs, useUI } from "./ui";
import {notificationTarget} from './notification-target';
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
import {MediaUploadPicker} from './media';
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
  const [replyScope,setReplyScope]=useState('public'),[replyBusy,setReplyBusy]=useState(false);
  useEffect(()=>setReplyScope('public'),[id]);
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
      <header className="ticket-page-head"><div><span className="ticket-breadcrumb"><Icon name="feedback" size={15}/>{admin?'工单管理':'我的工单'}</span><h1>{ticket.title || '工单详情'}</h1>{headline&&<p>{headline}</p>}</div><div className="ticket-page-actions">{ticket.status&&<StatusTag status={ticket.status}/>}<Link className="btn" to={back}><Icon name="arrow" size={15}/>返回列表</Link></div></header>
      <QueryState query={q}>
        <div className="ticket-layout ticket-detail">
          <div className="ticket-main">
            <div className="panel ticket-conversation">
              <div className="ticket-thread-head"><div><span className="ticket-section-icon"><Icon name="messages" size={20}/></span><div><h2>沟通记录</h2><p>{messages.length?`${messages.length} 条后续消息`:'等待进一步沟通'} · {admin?'与提交人共同跟进问题':'补充信息与处理回复都在这里'}</p></div></div><a className="link-btn" href="#ticket-reply">{admin?'回复工单':'补充信息'}<Icon name="edit" size={14}/></a></div>
              <div className="thread">
                <div className="thread-message">
                  <div className="message-meta">
                    <span className="ticket-message-avatar"><Icon name="profile" size={16}/></span><b>初始提交</b>
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
                      <span className="ticket-message-avatar"><Icon name={isInternalMessage(m)?'lock':m.sender_type==='admin'?'admin':'profile'} size={16}/></span><b>{messageSenderLabel(m)}</b>
                      {isInternalMessage(m) && <span className="tag">内部备注</span>}
                      <time>{time(m.created_at)}</time>
                    </div>
                    <div className="bubble details-text">{m.content}</div>
                    <TicketAttachments data={messageAttachmentIDs(m)} scope="本条消息附件" />
                  </div>
                ))}
              </div>
              <div id="ticket-reply" className={`reply-form${admin&&(replyScope==='internal'||closedForAdmin)?' is-internal':''}`} onChange={e=>{const input=e.target;if(input instanceof HTMLSelectElement&&input.name==='scope')setReplyScope(input.value);}}>
                <div className="ticket-reply-head"><h3>{admin?'回复与备注':'补充信息'}</h3><span><Icon name={admin&&(replyScope==='internal'||closedForAdmin)?'lock':'eye'} size={14}/>{admin&&(replyScope==='internal'||closedForAdmin)?'仅管理员可见':admin?'回复对提交人可见':'仅你和处理人员可见'}</span></div>
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
                    key={`${id}:${messages.length}:${closedForAdmin}`}
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
                    ]}
                    submit={closedForAdmin ? "保存备注" : "发送"}
                    onSubmit={async (data, fd) => {
                      setReplyBusy(true);
                      const isCurrent=captureAuthSession();
                      try{
                        const image_ids = await uploadIDs(fd,ticketAttachmentLimits);
                        if(!isCurrent())throw new Error('账号已切换，请重新确认回复');
                        await write(`${base}/tickets/${id}/messages`, {
                          content: data.content,image_ids,
                          ...(admin?{visible_to_user:data.scope==='public'}:{}),
                        });
                        if(!isCurrent())return;
                        await q.refetch();
                        setReplyScope(closedForAdmin?'internal':'public');
                        ui.notify("回复已发送");
                      }finally{setReplyBusy(false);}
                    }}
                  ><div className="ticket-reply-upload"><span>附件图片</span><MediaUploadPicker compact maxCount={ticketAttachmentLimits.maxCount} disabled={replyBusy}/><small>{attachmentHelp}</small></div></Form>
                  </>
                )}
              </div>
            </div>
          </div>
          <aside className="ticket-aside">
            <div className="panel panel-pad ticket-progress-panel">
              <div className="ticket-aside-head">
                <h3>处理进度</h3>
                <StatusTag status={ticket.status} />
              </div>
              <p className="ticket-progress-copy">{({pending:'尚未开始处理，可以先回复确认收到问题。',accepted:'已受理，正在安排排查。',waiting_user:'等待提交人补充信息后继续处理。',investigating:'正在定位问题原因。',fixing:'正在修复，进展会在这里更新。',testing:'修复正在验证中。',resolved:'已标记解决，等待提交人确认。',closed:'工单已关闭，历史沟通仍可查看。'} as Record<string,string>)[ticket.status]||'处理状态以当前工单记录为准。'}</p>
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
            <div className="panel panel-pad ticket-history-panel">
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
  const qc=useQueryClient(),inFlight=useRef(new Set<number>());
  const [readingAll,setReadingAll]=useState(false);
  const refresh=()=>qc.invalidateQueries({predicate:q=>q.queryKey[0]==='api'&&String(q.queryKey[1]).startsWith('/api/user/notifications')});
  const unread = params.get("unread") === "1";
  const values = rows(q.data, "notifications").filter(
    (x) => !unread || !x.is_read,
  );
  function open(n: Entity) {
    const target=notificationTarget(n,auth.user?.role);
    if(target.to)nav(target.to);
    else ui.open('通知详情',<div className="notification-detail"><span className="tag">{target.kind}</span><p className="details-text">{n.content}</p><time className="muted">{time(n.created_at)}</time><p className="muted">{String(n.type||'').startsWith('feedback')?'关联工单不可用，或当前账号没有访问权限。':'这条通知的完整内容已展示在这里。'}</p></div>);
    // 打开内容与回执独立；慢网或回执失败都不阻塞用户查看目标。
    if(n.is_read||inFlight.current.has(n.id))return;
    const isCurrent=captureAuthSession();
    inFlight.current.add(n.id);
    void request('/api/user/notifications/read-selected',{method:'POST',body:JSON.stringify({ids:[n.id]}),signal:AbortSignal.timeout(10000)}).then(()=>{if(isCurrent())void refresh();}).catch(()=>{if(isCurrent())ui.notify('内容已打开，已读状态同步失败；可在通知中心重试');}).finally(()=>inFlight.current.delete(n.id));
  }
  return (
    <>
      <Head title="通知中心" description="评论、审核结果与工单进展">
        <button
          className="btn"
          disabled={!auth.user||readingAll||!rows(q.data,'notifications').some(n=>!n.is_read)}
          onClick={async()=>{const isCurrent=captureAuthSession();setReadingAll(true);try{await request('/api/user/notifications/read',{method:'POST',body:'{}',signal:AbortSignal.timeout(10000)});if(isCurrent()){void refresh();ui.notify('全部通知已标为已读');}}catch(e){if(isCurrent())ui.notify(errorText(e));}finally{setReadingAll(false);}}}
        >
          {readingAll?'正在更新…':'全部已读'}
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
        <div className="panel notification-list">
          <QueryState query={q}>
            {values.map((n) => {const target=notificationTarget(n,auth.user?.role);return (
              <button
                key={n.id}
                className={`notification-row ${n.is_read ? "" : "unread"}`}
                onClick={() => open(n)}
              >
                <span className={`notification-icon kind-${target.icon}`}><Icon name={target.icon} size={21}/></span>
                <div className="notification-copy">
                  <span className="notification-kind">{target.kind}{!n.is_read&&<span className="notification-unread">未读</span>}</span>
                  <b>{n.content}</b>
                  <time dateTime={n.created_at}>{time(n.created_at)}</time>
                </div>
                <span className="notification-open">{target.to?target.label:'查看详情'}<Icon name="chevron" size={17}/></span>
              </button>
            );})}
            {!values.length && <Empty title="没有新的通知" />}
          </QueryState>
        </div>
      )}
    </>
  );
}
