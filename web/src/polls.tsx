import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { entity, rows, time, useApi, write, type Entity } from "./api";
import { Empty, Form, Head, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
export function Polls() {
  const [params, setParams] = useSearchParams();
  const team = params.get("tab") === "team",
    ui = useUI(),
    auth = useAuth();
  const q = useApi(team ? "/api/team/recruitments" : "/api/polls");
  return (
    <>
      <Head title="投票 · 组队" description="一起做选择，寻找志同道合的队友">
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
          ＋ {team ? "发布组队" : "创建投票"}
        </button>
      </Head>
      <Tabs
        tabs={[
          ["polls", "校园投票"],
          ["team", "组队广场"],
        ]}
        value={team ? "team" : "polls"}
        onChange={(tab) => setParams({ tab })}
      />
      <QueryState query={q}>
        <div className="two-col">
          {rows(q.data, "recruitments").map((p) =>
            team ? (
              <div className="panel panel-pad" key={p.id}>
                <span className="tag">{p.status}</span>
                <h3>{p.title}</h3>
                <p>{p.description}</p>
                <p className="muted">还需 {p.remaining_count} 人</p>
                <button
                  className="btn"
                  onClick={() => ui.open(p.title, <TeamDetail id={p.id} />)}
                >
                  查看组队
                </button>
              </div>
            ) : (
              <PollCard key={p.id} post={p} />
            ),
          )}
        </div>
        {!rows(q.data, "recruitments").length && <Empty />}
      </QueryState>
    </>
  );
}
function PollCard({ post }: { post: Entity }) {
  const ui = useUI(),
    auth = useAuth();
  const poll = post.poll_meta || {};
  const [chosen, setChosen] = useState<number[]>([]);
  return (
    <div className="panel panel-pad">
      <span className="tag brand">
        {poll.effective_status === "active" ? "进行中" : "已结束"}
      </span>
      <h3>{post.title}</h3>
      <p className="muted">{post.content}</p>
      {(poll.options || []).map((o: Entity) => (
        <label
          className={`poll-option ${o.is_chosen ? "voted" : ""}`}
          key={o.id}
        >
          <input
            type={poll.selection_mode === "multiple" ? "checkbox" : "radio"}
            name={`poll-${post.id}`}
            disabled={!poll.can_vote && !poll.can_change}
            checked={chosen.includes(o.id)}
            onChange={(e) =>
              setChosen(
                poll.selection_mode === "multiple"
                  ? e.target.checked
                    ? [...chosen, o.id]
                    : chosen.filter((id) => id !== o.id)
                  : [o.id],
              )
            }
          />
          {o.text}
          <span className="muted">
            {o.vote_count !== undefined ? ` ${o.vote_count} 票` : ""}
          </span>
        </label>
      ))}
      <div className="inline-actions">
        <button
          className="btn primary"
          disabled={!chosen.length || (!poll.can_vote && !poll.can_change)}
          onClick={() =>
            auth.requireUser() &&
            ui.act(
              () =>
                write(
                  `/api/polls/${post.id}/ballot`,
                  { option_ids: chosen },
                  "PUT",
                ),
              "投票结果已更新",
            )
          }
        >
          {poll.has_voted ? "修改选择" : "投票"}
        </button>
        <span className="muted">
          {poll.participant_count || 0} 人参与 · {time(poll.ends_at)}
        </span>
      </div>
    </div>
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
      <p>状态：{d.effective_status || d.status}</p>
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
