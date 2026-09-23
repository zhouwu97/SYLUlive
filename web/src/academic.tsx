import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useSearchParams } from "react-router-dom";
import {
  courseConflicts,
  gradeStats,
  mergeCourses,
  parseBackup,
  teachingWeek,
  type AcademicBackup,
  type AcademicConnection,
  type AcademicDataset,
  type AcademicProvider,
  type AcademicSnapshot,
  type Course,
  type Grade,
} from "@sylulive/academic-contracts";
import { bridge } from "./bridge";
import { downloadJSON, errorText, write } from "./api";
import { Form, Head, Empty, Stats, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
const initial = (): AcademicBackup => ({
  version: 1,
  term: { year: String(new Date().getFullYear()), semester: "3" },
  termStart: "",
  courses: [],
  overrides: {},
  grades: [],
  exams: [],
});
type Store = {
  data: AcademicBackup;
  setData: React.Dispatch<React.SetStateAction<AcademicBackup>>;
  updated: string;
  setUpdated: (s: string) => void;
};
const Context = createContext<Store>(null!);
export function AcademicProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  return <AccountData key={user?.id || "guest"}>{children}</AccountData>;
}
function AccountData({ children }: { children: ReactNode }) {
  const [data, setData] = useState(initial),
    [updated, setUpdated] = useState("");
  return (
    <Context.Provider value={{ data, setData, updated, setUpdated }}>
      {children}
    </Context.Provider>
  );
}
export const useAcademic = () => useContext(Context);
export function ConnectionForm({
  dataset,
  onData,
}: {
  dataset: AcademicDataset;
  onData: (value: unknown, snapshot: AcademicSnapshot) => void;
}) {
  const { requireUser } = useAuth(),
    ui = useUI(),
    store = useAcademic();
  const [provider, setProvider] = useState<AcademicProvider>(
    dataset === "physical"
      ? "physical"
      : dataset === "erke"
        ? "erke"
        : "undergraduate",
  );
  const [connection, setConnection] = useState<AcademicConnection | null>(null),
    [busy, setBusy] = useState(false),
    [status, setStatus] = useState(""),
    [assistantState, setAssistantState] = useState<"checking" | "ready" | "missing">("checking");
  const pending = useRef<AbortController | null>(null);
  useEffect(() => () => pending.current?.abort(), []);
  useEffect(() => {
    let active = true;
    bridge("hello", {}, AbortSignal.timeout(2200))
      .then(() => {
        if (active) {
          setAssistantState("ready");
          setStatus("教务助手已连接，可以打开学校登录页面。");
        }
      })
      .catch(() => {
        if (active) {
          setAssistantState("missing");
          setStatus("未检测到教务助手，请先安装或启用扩展，再刷新本页面。");
        }
      });
    return () => { active = false; };
  }, []);
  async function act(fn: (signal: AbortSignal) => Promise<void>) {
    if (!requireUser()) return;
    const controller = new AbortController();
    pending.current = controller;
    setBusy(true);
    setStatus("正在连接本机助手…");
    try {
      await bridge("hello", {}, controller.signal);
      setAssistantState("ready");
      await fn(controller.signal);
    } catch (e) {
      if (!controller.signal.aborted) setStatus(errorText(e));
    } finally {
      if (!controller.signal.aborted) setBusy(false);
      if (pending.current === controller) pending.current = null;
    }
  }
  return (
    <div className="dialog-form">
      <label className="field">
        学校系统
        <select
          disabled={busy}
          value={provider}
          onChange={(e) => {
            setProvider(e.target.value as AcademicProvider);
            setConnection(null);
          }}
        >
          {(dataset === "courses"
            ? ["undergraduate", "graduate"]
            : [provider]
          ).map((p) => (
            <option key={p} value={p}>
              {
                (
                  {
                    undergraduate: "本科教务",
                    graduate: "研究生教务",
                    erke: "二课 WebVPN",
                    physical: "体测",
                  } as Record<string, string>
                )[p]
              }
            </option>
          ))}
        </select>
      </label>
      <p className="muted">
        课表、成绩等资料只在本机助手中读取。本科或研究生首次连接时，会向 SYLUlive 同步教务类型和学号，用于记录本机身份声明；学校密码和会话不会上传。
      </p>
      <ol className="academic-steps" aria-label="教务连接步骤">
        <li className={assistantState === "ready" ? "done" : "active"}><b>1</b><span>检测助手</span></li>
        <li className={connection ? "done" : assistantState === "ready" ? "active" : ""}><b>2</b><span>获取身份</span></li>
        <li className={connection ? "done" : ""}><b>3</b><span>读取资料</span></li>
      </ol>
      <div className="inline-actions">
        <button
          className="btn primary"
          disabled={busy}
          onClick={() =>
            act(async (signal) => {
              setStatus("正在获取学校身份…");
              const value = await bridge<AcademicConnection>("session", { provider }, signal);
              if (provider === 'undergraduate' || provider === 'graduate') {
                await write('/api/student-identity/bind', {provider_id:`sylu_${provider}`,student_id:value.studentId,verification_method:'local_academic_login'});
              }
              if (signal.aborted) return;
              setConnection(value);
              setStatus(`已连接 ${value.displayName || value.studentId}，正在读取资料…`);
              const snapshot = await bridge<AcademicSnapshot>("query", {provider, dataset, term: store.data.term, epoch: value.epoch}, signal);
              if (signal.aborted) return;
              onData(snapshot.data, snapshot);
              store.setUpdated(snapshot.fetchedAt);
              ui.notify("学校资料已更新");
              ui.close();
            })
          }
        >
          {busy ? "正在连接并读取…" : "连接并读取资料"}
        </button>
        <button
          className="btn ghost"
          disabled={busy}
          onClick={() =>
            act(async (signal) => {
              await bridge("connect", { provider }, signal);
              setStatus("已打开学校登录页；登录完成后回到此页点击“连接并获取身份”。");
            })
          }
        >
          学校未登录？打开登录页
        </button>
      </div>
      {connection && (
        <>
          <p className="source-line">
            已连接：{connection.displayName} · {connection.studentId}
          </p>
          <label className="check-label"><input type="checkbox" disabled={busy} onChange={e=>{const enabled=e.target.checked;void act(async()=>{await bridge('persistence',{provider,epoch:connection.epoch,enabled});setStatus(enabled?'后续查询结果将保存在此电脑的扩展中':'已清除此身份的持久缓存')})}}/>在此电脑保存结构化资料</label>
          <button className="btn" disabled={busy} onClick={()=>act(async()=>{const snapshot=await bridge<AcademicSnapshot|null>('cache',{provider,epoch:connection.epoch,dataset,term:store.data.term});if(!snapshot)throw new Error('此身份和学期没有保存的资料');onData(snapshot.data,snapshot);store.setUpdated(snapshot.fetchedAt);setStatus('已恢复本地资料，请留意获取时间')})}>恢复本机资料</button>
          <button
            className="btn primary"
            disabled={busy}
            onClick={() =>
              act(async (signal) => {
                const snapshot = await bridge<AcademicSnapshot>("query", {
                  provider,
                  dataset,
                  term: store.data.term,
                  epoch: connection.epoch,
                }, signal);
                if (signal.aborted) return;
                onData(snapshot.data, snapshot);
                store.setUpdated(snapshot.fetchedAt);
                ui.notify("学校资料已更新");
                ui.close();
              })
            }
          >
            {busy ? "正在读取…" : "查询并更新资料"}
          </button>
          <button
            className="btn ghost"
            disabled={busy}
            onClick={() =>
              act(async () => {
                await bridge("disconnect", { provider });
                store.setData(initial());
                setConnection(null);
              })
            }
          >
            断开并清除当前资料
          </button>
        </>
      )}
      {status && <p role="status">{status}</p>}
    </div>
  );
}
function CourseForm({ course }: { course?: Course }) {
  const { data, setData } = useAcademic(),
    ui = useUI();
  return (
    <Form
      fields={[
        {
          name: "name",
          label: "课程名称",
          required: true,
          value: course?.name,
        },
        { name: "teacher", label: "教师", value: course?.teacher },
        { name: "room", label: "地点", value: course?.room },
        {
          name: "day",
          label: "星期",
          type: "number",
          min: 1,
          max: 7,
          value: course?.day || 1,
          required: true,
        },
        {
          name: "periods",
          label: "节次，以逗号分隔",
          value: course?.periods.join(",") || "1,2",
          required: true,
        },
        {
          name: "weeks",
          label: "周次，以逗号分隔",
          value: course?.weeks.join(",") || "1,2,3,4",
          required: true,
        },
      ]}
      onSubmit={async (values) => {
        const next: Course = {
          id: course?.id || `local:${crypto.randomUUID()}`,
          name: values.name,
          teacher: values.teacher,
          room: values.room,
          day: Number(values.day),
          periods: String(values.periods).split(/[,，]/).map(Number),
          weeks: String(values.weeks).split(/[,，]/).map(Number),
        };
        parseBackup(
          JSON.stringify({
            ...data,
            termStart: data.termStart || "2000-01-01",
            overrides: { ...data.overrides, [next.id]: next },
          }),
        );
        const conflict = mergeCourses(data.courses, data.overrides).find((c) =>
          courseConflicts(c, next),
        );
        if (conflict)
          throw new Error(`与“${conflict.name}”的节次冲突，请调整课程时间`);
        setData((s) => ({
          ...s,
          overrides: { ...s.overrides, [next.id]: next },
        }));
        ui.close();
        ui.notify("课程已保存");
      }}
    >
      {course && (
        <button
          type="button"
          className="btn"
          onClick={() => {
            setData((s) => ({
              ...s,
              overrides: { ...s.overrides, [course.id]: null },
            }));
            ui.close();
          }}
        >
          删除本地课程
        </button>
      )}
    </Form>
  );
}
export function AcademicSettings() {
  const { data, setData } = useAcademic();
  const ui = useUI();
  return (
    <>
      <Form
        fields={[
          {
            name: "year",
            label: "学年起始年份",
            type: "number",
            required: true,
            value: data.term.year,
          },
          {
            name: "semester",
            label: "学期",
            value: data.term.semester,
            options: [
              ["3", "第一学期"],
              ["12", "第二学期"],
              ["16", "第三学期"],
            ],
          },
          {
            name: "termStart",
            label: "第一周周一",
            type: "date",
            required: true,
            value: data.termStart,
          },
        ]}
        onSubmit={async (values) => {
          setData((s) => ({
            ...s,
            term: {
              year: String(values.year),
              semester: String(values.semester),
            },
            termStart: values.termStart,
          }));
          ui.close();
        }}
      />
      <label className="field">
        导入本地资料（将替换当前数据）
        <input
          type="file"
          accept="application/json,.json"
          onChange={async (e) => {
            const f = e.target.files?.[0];
            if (!f) return;
            try {
              const next = parseBackup(await f.text());
              setData(next);
              ui.notify("导入成功");
              ui.close();
            } catch (error) {
              ui.notify(errorText(error));
            }
          }}
        />
      </label>
      <p className="muted">
        学校资料和手动课程分开保存，更新学校课表不会覆盖本地调整。
      </p>
    </>
  );
}
export function Schedule() {
  const store = useAcademic(),
    ui = useUI();
  const [params, setParams] = useSearchParams();
  const week = Math.max(
    1,
    Math.min(
      60,
      Number(params.get("week")) ||
        Math.max(1, teachingWeek(store.data.termStart)),
    ),
  );
  const weekend = params.get("weekend") !== "0";
  const all = mergeCourses(store.data.courses, store.data.overrides);
  const courses = all.filter((c) => c.weeks.includes(week));
  return (
    <>
      <Head
        title="我的课表"
        description={`${store.data.term.year} 学年 · 学校课表与本地调整`}
      >
        <button
          className="btn"
          onClick={() => ui.open("课表设置", <AcademicSettings />)}
        >
          课表设置
        </button>
        <button
          className="btn"
          onClick={() => downloadJSON("sylulive-academic.json", store.data)}
        >
          导出
        </button>
        <button
          className="btn primary"
          onClick={() => ui.open("添加课程", <CourseForm />)}
        >
          ＋ 添加课程
        </button>
      </Head>
      <div className="source-line">
        <span>
          {store.updated
            ? `学校数据更新于 ${new Date(store.updated).toLocaleString("zh-CN")}`
            : "未读取学校课表"}
        </span>
        <button
          className="link-btn"
          onClick={() =>
            ui.open(
              "更新学校课表",
              <ConnectionForm
                dataset="courses"
                onData={(value) =>
                  store.setData((s) => ({ ...s, courses: value as Course[] }))
                }
              />,
            )
          }
        >
          连接教务助手 / 刷新
        </button>
      </div>
      <div className="schedule-toolbar">
        <div className="week-nav">
          <button
            className="btn"
            disabled={week === 1}
            onClick={() =>
              setParams({
                week: String(week - 1),
                weekend: weekend ? "1" : "0",
              })
            }
          >
            上一周
          </button>
          <div className="week-current">第 {week} 周</div>
          <button
            className="btn"
            disabled={week === 60}
            onClick={() =>
              setParams({
                week: String(week + 1),
                weekend: weekend ? "1" : "0",
              })
            }
          >
            下一周
          </button>
        </div>
        <label>
          <input
            type="checkbox"
            checked={weekend}
            onChange={(e) =>
              setParams({
                week: String(week),
                weekend: e.target.checked ? "1" : "0",
              })
            }
          />{" "}
          显示周末
        </label>
      </div>
      <div className="schedule-scroll" tabIndex={0}>
        <div
          className="schedule"
          style={{
            gridTemplateColumns: `65px repeat(${weekend ? 7 : 5},minmax(104px,1fr))`,
          }}
        >
          <div className="sch-head">节次</div>
          {["一", "二", "三", "四", "五", "六", "日"]
            .slice(0, weekend ? 7 : 5)
            .map((d) => (
              <div className="sch-head" key={d}>
                周{d}
              </div>
            ))}
          {Array.from({ length: 6 }, (_, i) => i * 2 + 1).map((period) => (
            <Row
              key={period}
              period={period}
              days={weekend ? 7 : 5}
              courses={courses}
              onEdit={(c) =>
                ui.open("课程详情与编辑", <CourseForm course={c} />)
              }
            />
          ))}
        </div>
      </div>
      <div className="section">
        <div className="section-head">
          <h2>课表工具</h2>
        </div>
        <div className="three-col">
          <div className="panel tool-summary">
            <b>本地调整</b>
            <p className="muted">学校刷新保留手动课程和修改。</p>
            <button
              className="btn"
              onClick={() =>
                ui.open(
                  "本地调整",
                  <>
                    <p>清除调整后恢复学校原始课表。</p>
                    <button
                      className="btn"
                      onClick={() => {
                        store.setData((s) => ({ ...s, overrides: {} }));
                        ui.close();
                      }}
                    >
                      清除本地调整
                    </button>
                  </>,
                )
              }
            >
              管理调整
            </button>
          </div>
          <div className="panel tool-summary">
            <b>空闲时间</b>
            <p className="muted">按所选教学周计算</p>
            <button
              className="btn"
              onClick={() =>
                ui.open(
                  "本周空闲节次",
                  <>
                    {Array.from({ length: 7 }, (_, d) => (
                      <p key={d}>
                        周{d + 1}：
                        {Array.from({ length: 12 }, (_, p) => p + 1)
                          .filter(
                            (p) =>
                              !courses.some(
                                (c) => c.day === d + 1 && c.periods.includes(p),
                              ),
                          )
                          .join("、") || "无"}
                      </p>
                    ))}
                  </>,
                )
              }
            >
              查看空闲节次
            </button>
          </div>
          <div className="panel tool-summary">
            <b>课程提醒</b>
            <p className="muted">浏览器运行时由助手提醒；修改课表后需重新同步。</p>
            <button className="btn" onClick={() => ui.open('课程提醒与小窗', <ReminderSettings />)}>设置提醒与小窗</button>
          </div>
        </div>
      </div>
    </>
  );
}
function ReminderSettings() {
  const {data} = useAcademic();
  const {requireUser} = useAuth();
  const ui = useUI();
  const payload = {...data, grades: []};
  return <div className="dialog-form">
    <p className="muted">使用当前课表（含本地调整）及考试。请先在课表设置中填写第一周周一。启用提醒时，助手会单独确认本机保存及通知权限。</p>
    <Form fields={[{name:'minutes',label:'提前分钟数',type:'number',value:'10',required:true}]} submit="在助手中确认启用" onSubmit={async values => {
      if (!requireUser()) return;
      await bridge('reminders',{enabled:true,data:payload,minutes:Number(values.minutes)});
      ui.notify('请在新打开的助手页面确认通知权限');
    }}/>
    <button className="btn" onClick={() => {if(requireUser()) void ui.act(() => bridge('window',{data:payload}),'已打开课程小窗');}}>打开今日课程小窗</button>
    <button className="btn" onClick={() => {if(requireUser()) void ui.act(() => bridge('reminders',{enabled:false}),'已关闭提醒并清除保存的提醒课表');}}>关闭提醒并清除提醒数据</button>
  </div>;
}
function Row({
  period,
  days,
  courses,
  onEdit,
}: {
  period: number;
  days: number;
  courses: Course[];
  onEdit: (c: Course) => void;
}) {
  return (
    <>
      <div className="sch-time">第 {period}–{period+1} 节</div>
      {Array.from({ length: days }, (_, i) => (
        <div className="sch-cell" key={i}>
          {courses
            .filter((c) => c.day === i + 1 && c.periods.some(p=>p===period||p===period+1))
            .map((c) => (
              <button className="course" key={c.id} onClick={() => onEdit(c)}>
                <b>{c.name}</b>
                <span>{c.room}</span>
                <small>{c.teacher}</small>
              </button>
            ))}
        </div>
      ))}
    </>
  );
}
export function Grades() {
  const store = useAcademic(),
    ui = useUI();
  const [params, setParams] = useSearchParams();
  const tab = params.get("tab") || "grades";
  const [extra, setExtra] = useState<Record<string,AcademicSnapshot>>({});
  const dataset = tab === 'graduation' ? 'requirements' : tab;
  const stats = gradeStats(store.data.grades);
  return (
    <>
      <Head
        title="成绩与学业"
        description="成绩、学分要求、二课、体测与毕业检查"
      >
        <button
          className="btn"
          onClick={() => ui.open("数据设置", <AcademicSettings />)}
        >
          数据设置
        </button>
        <button
          className="btn primary"
          onClick={() =>
            ui.open(
              "更新学业资料",
              <ConnectionForm
                dataset={dataset as AcademicDataset}
                onData={(value,snapshot) => {
                  if(dataset === 'grades')store.setData((s) => ({ ...s, grades: value as Grade[] }));
                  setExtra(current=>({...current,[dataset]:snapshot}));
                }}
              />,
            )
          }
        >
          更新本地资料
        </button>
      </Head>
      <Tabs
        tabs={[
          ["grades", "成绩"],
          ["requirements", "学分要求"],
          ["situation", "学业情况"],
          ["erke", "二课"],
          ["physical", "体测"],
          ["graduation", "毕业检查"],
        ]}
        value={tab}
        onChange={(value) => {
          setParams({ tab: value });
        }}
      />
      {extra[dataset]&&<p className="muted">学校来源：{extra[dataset].provider} · 获取时间：{new Date(extra[dataset].fetchedAt).toLocaleString('zh-CN')}</p>}
      {tab === "grades" ? (
        <>
          <Stats
            items={[
              [stats.gpa?.toFixed(2) || "—", "加权绩点"],
              [stats.average?.toFixed(2) || "—", "加权平均分"],
              [stats.credits, "已获学分"],
            ]}
          />
          <p className="muted">以上统计按当前已读取或导入的成绩在本地计算。</p>
          <div className="panel table-scroll">
            <table className="data-table">
              <thead>
                <tr>
                  <th>课程</th>
                  <th>学期</th>
                  <th>学分</th>
                  <th>成绩</th>
                  <th>绩点</th>
                  <th>性质</th>
                </tr>
              </thead>
              <tbody>
                {store.data.grades.map((g) => (
                  <tr key={g.id}>
                    <td>{g.name}</td>
                    <td>{g.term}</td>
                    <td>{g.credit}</td>
                    <td>{g.score}</td>
                    <td>{g.gpa ?? "—"}</td>
                    <td>{g.nature}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!store.data.grades.length && (
              <Empty description="通过教务助手更新成绩，或导入本地资料。" />
            )}
          </div>
        </>
      ) : (
        <div className="panel panel-pad">
          {extra[dataset] ? (
            dataset==='requirements'?<Requirements value={extra[dataset].data} graduation={tab==='graduation'}/>:<DataTable value={extra[dataset].data} />
          ) : (
            <Empty description="点击更新本地资料，从对应学校系统读取。" />
          )}
        </div>
      )}
    </>
  );
}
function Requirements({value,graduation}:{value:unknown;graduation:boolean}){
  const modules=(value as {modules?:{name:string;required:number|null;requiredCount:number|null;earned:number;status:string;courses:unknown[]}[]})?.modules;
  if(!modules)return <DataTable value={value}/>;
  return <>
    <p className="muted">要求学分、门数及课程来自学校；已获学分和模块状态由助手根据已返回课程在本地计算。不同模块可能包含同一课程，不累加为毕业总学分。</p>
    {graduation&&<p>此检查只核对已取得的学分模块数据，不代表学校毕业审核结论。二课、体测及其他毕业条件请分别查看学校结果。</p>}
    <div className="table-scroll"><table className="data-table"><thead><tr><th>学分模块</th><th>要求学分</th><th>要求门数</th><th>本地统计学分</th><th>检查结果</th></tr></thead>
      <tbody>{modules.map((module,index)=><tr key={index}><td><details><summary>{module.name}</summary><DataTable value={module.courses}/></details></td><td>{module.required??'未提供'}</td><td>{module.requiredCount??'未提供'}</td><td>{module.earned}</td><td>{module.status}</td></tr>)}</tbody>
    </table></div>{!modules.length&&<Empty title="学校没有返回学分模块"/>}
  </>;
}
function DataTable({ value }: { value: unknown }) {
  if (Array.isArray(value))
    return (
      <div className="table-scroll">
        <table className="data-table">
          <tbody>
            {value.map((row, i) => (
              <tr key={i}>
                {(Array.isArray(row) ? row : Object.values(row || {})).map(
                  (v, j) => (
                    <td key={j}>
                      {typeof v === "object" ? (
                        <DataTable value={v} />
                      ) : (
                        String(v ?? "")
                      )}
                    </td>
                  ),
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  if (value && typeof value === "object")
    return (
      <dl>
        {Object.entries(value).map(([k, v]) => (
          <div key={k}>
            <dt>
              {(
                {
                  required: "要求学分",
                  earned: "已获学分",
                  categories: "分类",
                  total_score: "总分",
                  total_grade: "等级",
                  scores: "项目成绩",
                  tables:'学校数据表',headers:'表头',rows:'数据',modules:'学分模块',requiredCount:'要求门数',name:'名称',courses:'课程',credits:'学分',grade:'成绩',status:'状态',term:'学期',id:'课程编号',room:'地点',teacher:'教师',result:'测试结果',score:'得分',
                } as Record<string, string>
              )[k] || k}
            </dt>
            <dd>
              {typeof v === "object" ? (
                <DataTable value={v} />
              ) : (
                String(v ?? "")
              )}
            </dd>
          </div>
        ))}
      </dl>
    );
  return <span>{String(value ?? "")}</span>;
}
