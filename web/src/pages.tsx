import { useAcademic } from "./academic";
import { PaperLibrary } from './papers';
import { teachingWeek, mergeCourses } from "@sylulive/academic-contracts";
import {
  PostCard as CommunityPostCard,
  PostForm as CommunityPostForm,
} from "./community";
import { useMemo, useState } from "react";
import { useParams, useNavigate, useSearchParams } from "react-router-dom";
import {
  useApi,
  rows,
  entity,
  query,
  write,
  time,
  asset,
  downloadJSON,
  errorText,
  type Entity,
} from "./api";
import { useAuth } from "./auth";
import { bridge } from "./bridge";
import {
  Empty,
  Form,
  Head,
  Icon,
  Pagination,
  QueryState,
  Stats,
  Tabs,
  useUI,
} from "./ui";
import {
  gradeStats,
  parseBackup,
  type AcademicBackup,
  type AcademicProvider,
  type AcademicTerm,
  type Course,
  type Grade,
} from "@sylulive/academic-contracts";

function Card({
  children,
  className = "",
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section className={`panel panel-pad ${className}`}>{children}</section>
  );
}
function List({
  items,
  empty = "暂无数据",
  render,
}: {
  items: Entity[];
  empty?: string;
  render: (item: Entity, index: number) => React.ReactNode;
}) {
  return items.length ? (
    <div className="data-list">{items.map(render)}</div>
  ) : (
    <Empty text={empty} />
  );
}
function useRows(path: string | null, ...keys: string[]) {
  const q = useApi<Entity>(path);
  return { ...q, items: rows(q.data, ...keys) };
}
export function Dashboard() {
  const nav = useNavigate(),
    ui = useUI();
  const posts = useRows("/api/posts?page=1&limit=5&sort=time", "posts");
  const { user, requireUser } = useAuth();
  const academic = useAcademic();
  const week = academic.data.termStart
    ? teachingWeek(academic.data.termStart)
    : null;
  const today = mergeCourses(
    academic.data.courses,
    academic.data.overrides,
  ).filter(
    (c) =>
      c.day === (new Date().getDay() || 7) && (!week || c.weeks.includes(week)),
  );
  return (
    <>
      <Head
        title={user ? `${user.nickname}，你好` : "欢迎来到沈理校园"}
        description={new Date().toLocaleDateString("zh-CN", {
          year: "numeric",
          month: "long",
          day: "numeric",
          weekday: "long",
        })}
      >
        <button className="btn" onClick={() => nav("/schedule")}>
          查看课表
        </button>
        <button
          className="btn primary"
          onClick={() =>
            requireUser() && ui.open("发布内容", <CommunityPostForm />)
          }
        >
          <Icon name="plus" />
          发布内容
        </button>
      </Head>
      <div className="today-card">
        <div>
          <span className="tag brand">
            {week ? `第 ${week} 周` : "我的课表"}
          </span>
          <h2>
            {today[0]?.name ||
              (academic.updated ? "今天没有课程" : "连接你的校园日程")}
          </h2>
          <p>
            {today[0]
              ? `${today[0].room} · ${today[0].teacher} · 第 ${today[0].periods.join("、")} 节`
              : "通过教务助手在本机读取课表，或添加个人课程。"}
          </p>
          <button className="btn" onClick={() => nav("/schedule")}>
            {academic.updated ? "查看今日课表" : "连接教务助手"}
          </button>
        </div>
        <div className="today-side">
          <div className="today-time">{today.length}</div>
          <span className="muted">今日课程</span>
        </div>
      </div>
      <div className="section quick-section">
        <div className="section-head">
          <h2>常用功能</h2>
          <button className="link-btn" onClick={() => nav("/toolbox")}>
            全部工具 →
          </button>
        </div>
        <div className="quick-grid compact-quick">
          {[
            ["schedule", "我的课表"],
            ["grades", "成绩"],
            ["exams", "考试"],
            ["competition", "竞赛"],
            ["canteen", "食堂"],
            ["ai", "AI 助手"],
          ].map(([id, name]) => (
            <button className="quick" key={id} onClick={() => nav(`/${id}`)}>
              <i>
                <Icon name={id} />
              </i>
              <span>{name}</span>
            </button>
          ))}
        </div>
      </div>
      <div className="section">
        <div className="section-head">
          <h2>校园动态</h2>
          <button className="link-btn" onClick={() => nav("/community")}>
            进入社区 →
          </button>
        </div>
        <div className="panel">
          <QueryState query={posts}>
            {posts.items.map((post) => (
              <CommunityPostCard post={post} key={post.id} />
            ))}
            {!posts.items.length && <Empty />}
          </QueryState>
        </div>
      </div>
    </>
  );
}

export function Exams() {
  const ui = useUI(),
    { data, setData } = useAcademic();
  const [params,setParams]=useSearchParams();
  const tab=params.get('tab')||'schedule';
  function edit(exam?: Entity) {
    ui.open(
      exam ? "编辑考试" : "录入考试",
      <Form
        fields={[
          {
            name: "name",
            label: "考试名称",
            required: true,
            value: exam?.name,
          },
          {
            name: "startTime",
            label: "开始时间",
            type: "datetime-local",
            required: true,
            value: exam?.startTime,
          },
          {
            name: "endTime",
            label: "结束时间",
            type: "datetime-local",
            required: true,
            value: exam?.endTime,
          },
          { name: "room", label: "地点", value: exam?.room },
        ]}
        onSubmit={async (values) => {
          if (Date.parse(values.endTime) <= Date.parse(values.startTime))
            throw new Error("结束时间必须晚于开始时间");
          const next = {
            id: exam?.id || crypto.randomUUID(),
            name: String(values.name),
            startTime: String(values.startTime),
            endTime: String(values.endTime),
            room: String(values.room),
            semester: data.term.year + "-" + data.term.semester,
          };
          setData((s) => ({
            ...s,
            exams: [...s.exams.filter((e) => e.id !== next.id), next],
          }));
          ui.close();
        }}
      >
        {exam && (
          <button
            className="btn"
            type="button"
            onClick={() => {
              setData((s) => ({
                ...s,
                exams: s.exams.filter((e) => e.id !== exam.id),
              }));
              ui.close();
            }}
          >
            删除考试
          </button>
        )}
      </Form>,
    );
  }
  return (
    <>
      <Head
        title="考试与试卷库"
        description="考试安排、倒计时、历史试卷与资料共享"
      >
        <button
          className="btn"
          onClick={() =>
            downloadJSON("sylulive-exams.json", {
              version: 1,
              semester: data.term.year + '-' + data.term.semester,
              export_time: new Date().toISOString(),
              exams: data.exams.map(e=>({...e,location:e.room})),
            })
          }
        >
          导出考试
        </button>
        <button className="btn primary" onClick={() => edit()}>
          录入考试
        </button>
      </Head>
      <Tabs tabs={[["schedule","考试安排"],["papers","试卷库"],["mine","我的提交"]]} value={tab} onChange={value=>setParams(value==='mine'?{tab:value,papers:'mine'}:{tab:value})}/>
      {tab!=='schedule'?<PaperLibrary/>:<>
      <div className="filter-row">
        <label>
          导入考试 JSON{" "}
          <input
            type="file"
            accept="application/json,.json"
            onChange={async (e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              try {
                const value = JSON.parse(await file.text());
                if(value.version !== 1 || !Array.isArray(value.exams))throw new Error('不支持的考试存档格式');
                const parsed = parseBackup(
                  JSON.stringify({
                    ...data,
                    termStart: data.termStart || "2000-01-01",
                    exams: value.exams.map((e:Entity)=>({...e,id:e.id||crypto.randomUUID(),room:e.room??e.location??'',semester:e.semester||value.semester||''})),
                  }),
                );
                setData((s) => ({ ...s, exams: parsed.exams }));
                ui.notify("考试导入成功");
              } catch (error) {
                ui.notify(errorText(error));
              }
            }}
          />
        </label>
      </div>
      <div className="panel">
        {[...data.exams]
          .sort((a, b) => Date.parse(a.startTime) - Date.parse(b.startTime))
          .map((exam) => (
            <div className="list-row" key={exam.id}>
              <div className="author-avatar">
                {Math.max(
                  0,
                  Math.ceil(
                    (Date.parse(exam.startTime) - Date.now()) / 86400000,
                  ),
                )}
                d
              </div>
              <div className="list-main">
                <b>{exam.name}</b>
                <p>
                  {new Date(exam.startTime).toLocaleString("zh-CN")} ·{" "}
                  {exam.room || "地点待定"}
                </p>
              </div>
              <button className="btn" onClick={() => edit(exam)}>
                编辑
              </button>
            </div>
          ))}
        {!data.exams.length && <Empty text="还没有考试安排" />}
      </div>
      <div className="section">
        <PaperLibrary />
      </div>
      </>}
    </>
  );
}


