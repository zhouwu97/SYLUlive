import { useEffect, useRef, useState, type CSSProperties, type MouseEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { captureAuthSession, entity, errorText, query, rows, time, useApi, write, type Entity } from "./api";
import { Empty, Form, Icon, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
import { ServerAvatar } from "./server-avatar";
import { MediaGallery } from "./media";
import { mobilePostTime, useMobile } from "./mobile";
import "./polls.css";

const teamStatuses: Record<string, string> = {
  recruiting: "招募中",
  full: "已满员",
  closed: "已关闭",
  expired: "已截止",
};
export function Polls() {
  const [params, setParams] = useSearchParams();
  const team = params.get("tab") === "team",
    ui = useUI(),
    auth = useAuth();
  const sort = params.get("sort") || "recommend";
  const category = params.get("category") || "all";
  const q = useApi(team ? "/api/team/recruitments" : query("/api/polls", { sort, category }));
  const items = rows(q.data, "recruitments");
  function filter(name: string, value: string) {
    setParams(previous => {
      const next = new URLSearchParams(previous);
      next.set(name, value);
      return next;
    });
  }
  return (
    <div className="polls-page">
      <header className="participation-intro">
        <div className="participation-intro-copy">
          <h1>投票 · 组队</h1>
          <p>一起做选择，寻找志同道合的队友</p>
        </div>
        <button
          className="btn primary"
          onClick={() =>
            auth.requireUser() &&
            ui.open(
              team ? "发布组队" : "创建投票",
              team ? <TeamForm /> : <PollForm />,
            )
          }
        >
          <Icon name="plus" size={18} />{team ? "发布组队" : "创建投票"}
        </button>
      </header>
      <div className="participation-toolbar">
      <Tabs
        tabs={[
          ["polls", "校园投票"],
          ["team", "组队广场"],
        ]}
        value={team ? "team" : "polls"}
        onChange={(tab) => setParams({ tab })}
      />
        {!q.isPending && !q.error && <span className="participation-count">本页 <b>{items.length}</b> {team ? "个招募" : "场投票"}</span>}
      </div>
      {!team && <section className="poll-filters" aria-label="筛选校园投票">
        <p>校园投票由用户发起，结果仅代表参与用户的选择。</p>
        <Tabs tabs={[["recommend", "推荐"], ["latest", "最新"], ["ending", "即将结束"]]} value={sort} onChange={value => filter("sort", value)} />
        <div className="poll-categories" aria-label="投票分类">
          {[["all", "全部"], ["campus_life", "校园生活"], ["study", "学习"], ["activity", "活动"], ["other", "其他"]].map(([value, label]) => <button key={value} aria-pressed={category === value} onClick={() => filter("category", value)}>{label}</button>)}
        </div>
      </section>}
      <QueryState query={q}>
        <div key={auth.user?.id ?? "guest"}>
          {team ? <div className="participation-grid">{items.map((p) => (
              <article className="panel team-card" key={p.id}>
                <div className="participation-heading">
                <div className="participation-card-head">
                  <span className={`participation-status ${(p.effective_status || p.status) === "recruiting" ? "is-active" : ""}`}>
                    {teamStatuses[p.effective_status || p.status] || "状态待确认"}
                  </span>
                  <Icon name="community" size={18} />
                </div>
                <h3>{p.title}</h3>
                <p className="participation-description">{p.description}</p>
                </div>
                {p.roles?.length > 0 && (
                  <div className="team-roles">
                    {p.roles.map((role: string, index: number) => <span key={index}>{role}</span>)}
                  </div>
                )}
                <div className="participation-footer">
                  <div className="participation-meta">
                    <span>{p.remaining_count != null ? `还需 ${p.remaining_count} 人` : "查看招募详情"}</span>
                    {p.deadline && <span>截止 {time(p.deadline)}</span>}
                  </div>
                  <button className="btn" onClick={() => ui.open(p.title, <TeamDetail id={p.id} />)}>
                    查看组队
                  </button>
                </div>
              </article>
            ))}</div> : <div className="poll-feed">{items.map(post => <PollCard key={post.id} post={post} linked />)}</div>}
        </div>
        {!items.length && (
          <Empty
            title={team ? "还没有组队招募" : "还没有校园投票"}
            description={team ? "发布你的计划，找到一起学习、参赛或运动的伙伴。" : "发起一个问题，听听同学们的想法。"}
          />
        )}
      </QueryState>
    </div>
  );
}
// 列表卡片（首页信息流、投票列表）需要进入详情；详情页内复用时不再自链接。
export function PollCard({ post, compact = false, linked = compact }: { post: Entity; compact?: boolean; linked?: boolean }) {
  const ui = useUI(), auth = useAuth(), qc = useQueryClient();
  const mobile = useMobile();
  const location = useLocation(), navigate = useNavigate();
  const poll = post.poll_meta || {};
  const authorName = post.author?.nickname || "匿名用户";
  const options: Entity[] = poll.options || [];
  const savedChoices = options.filter(option => option.is_chosen).map(option => option.id as number);
  const [draft, setDraft] = useState<number[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(false);
  const visibleOptions = compact && !expanded ? options.slice(0, 3) : options;
  const submitting = useRef(false), mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);
  const chosen = draft ?? savedChoices;
  const active = poll.effective_status === "active";
  const multiple = poll.selection_mode === "multiple";
  const maxChoices = multiple ? Math.max(1, Number(poll.max_choices) || options.length) : 1;
  const editable = active && !!auth.user && !!(poll.can_vote || poll.can_change);
  const resultsVisible = poll.results_visible !== false && poll.can_view_result !== false;
  const unchanged = poll.has_voted && chosen.length === savedChoices.length && chosen.every(id => savedChoices.includes(id));
  const detailPath = poll.id ? `/polls/${poll.id}` : `/post/${post.id}`;
  const detailState = { from: location.pathname + location.search };
  // 与普通帖子卡片一致：点卡片空白处进入详情；选项、按钮、图片等交互区保持原行为。
  function openDetail(event: MouseEvent<HTMLElement>) {
    if (!linked || event.defaultPrevented || event.button !== 0) return;
    if ((event.target as Element).closest("a, button, input, label, select, textarea, fieldset, .poll-media, [role='button']")) return;
    if (window.getSelection()?.toString()) return;
    navigate(detailPath, { state: detailState });
  }
  const hintId = `poll-hint-${post.id}`;
  const titleId = `poll-title-${post.id}`;
  const hiddenResultHint = ({
    after_vote: "投票后可查看结果",
    after_end: "投票结束后公开结果",
    private: "投票结果不公开",
  } as Record<string, string>)[poll.results_visibility] || "结果暂不可见";

  async function vote() {
    if (submitting.current || !editable || !chosen.length || !auth.requireUser()) return;
    const isCurrent = captureAuthSession();
    const canUpdate = () => mounted.current && isCurrent();
    submitting.current = true;
    setBusy(true);
    setError("");
    try {
      await write(`/api/polls/${poll.id ?? post.id}/ballot`, { option_ids: chosen }, "PUT");
      if (!canUpdate()) return;
      await qc.invalidateQueries({ queryKey: ["api"] });
      if (!canUpdate()) return;
      setDraft(null);
      ui.notify("投票结果已更新");
    } catch (err) {
      if (canUpdate()) setError(errorText(err));
    } finally {
      submitting.current = false;
      if (canUpdate()) setBusy(false);
    }
  }

  return (
    <article className={`panel poll-card ${compact ? "mobile-feed-poll" : ""} ${linked ? "poll-card-linked" : ""} ${active ? "poll-card-active" : "poll-card-closed"}`} aria-labelledby={titleId} aria-busy={busy} onClick={openDetail}>
      <div className="participation-heading">
        <div className="poll-author">
          <span className="poll-avatar"><ServerAvatar src={post.author?.avatar} name={authorName} /></span>
          <div className="poll-author-copy"><b>{authorName}</b>{post.created_at && <time dateTime={post.created_at} title={time(post.created_at)}>{compact || mobile ? mobilePostTime(post.created_at) : time(post.created_at)}</time>}</div>
          <span className="poll-type-label">校园投票</span>
        </div>
      <h3 id={titleId}>{linked ? <Link to={detailPath} state={detailState}>{post.title}</Link> : post.title}</h3>
      {post.content && <p className="participation-description">{post.content}</p>}
      </div>
      <MediaGallery items={post.images} title={post.title} className="poll-media" maxVisible={9} />
      <p className="poll-selection-rule">{multiple ? `多选 · 最多选 ${maxChoices} 项` : "单选 · 选择 1 项"}</p>
      <fieldset className="poll-choices" aria-describedby={hintId}>
        <legend className="sr-only">{post.title}的选项</legend>
        {visibleOptions.map(option => {
          const selected = chosen.includes(option.id);
          const showCount = resultsVisible && typeof option.vote_count === "number";
          const ratio = typeof option.ratio === "number"
            ? option.ratio
            : (poll.participant_count > 0 ? option.vote_count / poll.participant_count : 0);
          const percent = Math.round(Math.min(1, Math.max(0, ratio || 0)) * 100);
          const disabled = !editable || busy || (multiple && !selected && chosen.length >= maxChoices);
          return (
            <label
              className={`poll-choice ${selected ? "is-selected" : ""} ${disabled ? "is-disabled" : ""}`}
              key={option.id}
              style={{ "--poll-result": `${showCount ? percent : 0}%` } as CSSProperties}
            >
              <input
                type={multiple ? "checkbox" : "radio"}
                name={`poll-${post.id}`}
                aria-label={option.text}
                disabled={disabled}
                checked={selected}
                onChange={event => {
                  setError("");
                  const selection = event.target.checked
                    ? [...chosen, option.id]
                    : chosen.filter(id => id !== option.id);
                  setDraft(multiple ? selection : [option.id]);
                }}
              />
              <span className="poll-choice-text">
                {option.text}{option.is_chosen && <small>已投</small>}
              </span>
              {showCount && (
                <span className="poll-result" title={`${option.vote_count} 票`}><b>{percent}%</b></span>
              )}
            </label>
          );
        })}
      </fieldset>
      {visibleOptions.length < options.length && <button className="mobile-more-options" onClick={() => setExpanded(true)}>还有 {options.length - visibleOptions.length} 个选项 <span aria-hidden="true">›</span></button>}
      <p className="poll-hint" id={hintId}>
        {!resultsVisible ? hiddenResultHint : multiple ? "占比按参与人数计算，每人可选择多项" : "占比按参与人数计算"}
        {editable && multiple && ` · 已选 ${chosen.length}/${maxChoices} 项`}
      </p>
      {error && <p className="poll-error" role="alert">{error}，可保留当前选择重试。</p>}
      <div className="poll-submit">
        {active && !auth.user ? (
          <button className="btn" disabled={auth.loading} onClick={auth.login}>登录参与</button>
        ) : editable ? (
          <button className="btn primary" disabled={busy || !chosen.length || unchanged} onClick={vote}>
            {busy ? "提交中…" : error ? "重试投票" : unchanged ? "已提交选择" : !chosen.length ? multiple ? "选择后提交" : "选择一项后投票" : poll.has_voted ? "确认修改" : "提交选择"}
          </button>
        ) : (
          <button className="btn" disabled>{poll.has_voted ? "已提交，不可修改" : active ? "暂不可投票" : "投票已结束"}</button>
        )}
      </div>
      <div className="poll-footnote"><span>{poll.participant_count ?? 0} 人参与</span>{poll.ends_at && <span><Icon name="schedule" size={14} />{active ? <>截止 <time dateTime={poll.ends_at}>{time(poll.ends_at)}</time></> : "已结束"}</span>}</div>
    </article>
  );
}
function PollForm() {
  const ui = useUI();
  return (
    <Form
      fields={[
        { name: "title", label: "投票标题", required: true },
        { name: "description", label: "描述", type: "textarea" },
        {
          name: "options",
          label: "选项，每行一项",
          type: "textarea",
          required: true,
        },
        {
          name: "category",
          label: "分类",
          options: [
            ["campus_life", "校园生活"],
            ["study", "学习"],
            ["activity", "活动"],
            ["other", "其他"],
          ],
        },
        {
          name: "ends_at",
          label: "截止时间",
          type: "datetime-local",
          required: true,
        },
        {
          name: "results_visibility",
          label: "结果可见性",
          options: [
            ["always", "始终可见"],
            ["after_vote", "投票后可见"],
            ["after_end", "结束后可见"],
          ],
        },
        {
          name: "selection_mode",
          label: "选择方式",
          options: [
            ["single", "单选"],
            ["multiple", "多选"],
          ],
        },
        {
          name: "max_choices",
          label: "最多选择数",
          type: "number",
          min: 1,
          max: 10,
          value: 1,
        },
      ]}
      submit="创建投票"
      onSubmit={async (data) => {
        await write("/api/polls", {
          ...data,
          options: String(data.options)
            .split(/\r?\n/)
            .map((s) => s.trim())
            .filter(Boolean),
          ends_at: new Date(data.ends_at).toISOString(),
          max_choices: Number(data.max_choices),
          allow_change: true,
        });
        ui.close();
        ui.notify("投票已创建");
      }}
    />
  );
}
function TeamForm() {
  const ui = useUI();
  return (
    <Form
      fields={[
        { name: "title", label: "组队标题", required: true },
        {
          name: "description",
          label: "组队说明",
          type: "textarea",
          required: true,
        },
        {
          name: "category",
          label: "分类",
          required: true,
          options: [
            ["study", "学习"],
            ["competition", "竞赛"],
            ["sports", "运动"],
            ["other", "其他"],
          ],
        },
        {
          name: "needed_count",
          label: "招募人数",
          type: "number",
          min: 1,
          max: 100,
          required: true,
        },
        { name: "roles", label: "所需角色，以逗号分隔" },
        { name: "deadline", label: "截止时间", type: "datetime-local" },
      ]}
      submit="发布组队"
      onSubmit={async (data) => {
        await write("/api/team/recruitments", {
          ...data,
          needed_count: Number(data.needed_count),
          roles: String(data.roles)
            .split(/[,，]/)
            .map((s) => s.trim())
            .filter(Boolean),
          deadline: data.deadline ? new Date(data.deadline).toISOString() : "",
        });
        ui.close();
        ui.notify("组队已发布");
      }}
    />
  );
}
function TeamDetail({ id }: { id: number }) {
  const ui = useUI();
  const q = useApi(`/api/team/recruitments/${id}`);
  const d = entity(q.data, "recruitment", "data");
  const applications = useApi(
    d.can_manage ? `/api/team/recruitments/${id}/applications` : null,
  );
  return (
    <QueryState query={q}>
      <p className="details-text">{d.description}</p>
      <p>状态 · {teamStatuses[d.effective_status || d.status] || "状态待确认"}</p>
      {d.can_apply && (
        <Form
          fields={[
            {
              name: "message",
              label: "申请说明",
              type: "textarea",
              required: true,
            },
            { name: "availability", label: "可用时间" },
          ]}
          submit="申请加入"
          onSubmit={async (data) => {
            await write(`/api/team/recruitments/${id}/apply`, data);
            await q.refetch();
            ui.notify("申请已提交");
          }}
        />
      )}
      {d.my_application_id && d.my_application_status === "pending" && (
        <button
          className="btn"
          onClick={() =>
            ui.act(() =>
              write(`/api/team/applications/${d.my_application_id}/cancel`),
            )
          }
        >
          撤回申请
        </button>
      )}
      {d.can_manage && (
        <QueryState query={applications}>
          {rows(applications.data, "applications").map((a) => (
            <div className="list-row" key={a.id}>
              <div className="list-main">
                <b>{a.user?.nickname || a.applicant?.nickname}</b>
                <p>{a.message}</p>
                <span>{a.status}</span>
              </div>
              {a.status === "pending" && (
                <div className="inline-actions">
                  <button
                    className="btn"
                    onClick={() =>
                      ui.act(() =>
                        write(`/api/team/applications/${a.id}/accept`),
                      )
                    }
                  >
                    接受
                  </button>
                  <button
                    className="btn"
                    onClick={() =>
                      ui.act(() =>
                        write(`/api/team/applications/${a.id}/reject`),
                      )
                    }
                  >
                    拒绝
                  </button>
                </div>
              )}
            </div>
          ))}
        </QueryState>
      )}
    </QueryState>
  );
}
