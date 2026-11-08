import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useSearchParams } from "react-router-dom";
import {
  bridgeErrorCode,
  courseConflicts,
  defaultAcademicTerm,
  gradeStats,
  mergeCourses,
  parseBackup,
  teachingWeek,
  type AcademicBackup,
  type AcademicConnection,
  type AcademicDataset,
  type AcademicProvider,
  type AcademicSnapshot,
  type AssistantConnection,
  type BridgeErrorCode,
  type Course,
  type Grade,
  type HelloResult,
  BridgeFailure,
} from "@sylulive/academic-contracts";
import { bridge } from "./bridge";
import { useAssistantProbe } from "./use-assistant-probe";
import { AssistantInstallGuide } from "./assistant-guide";
import { waitForSchoolLogin } from "./assistant-login";
import { downloadJSON, errorText, write, request, entity } from "./api";
import { Form, Head, Empty, Icon, Stats, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
import { mobileTermLabel, useMobile } from "./mobile";
const initial = (): AcademicBackup => ({
  version: 1,
  term: defaultAcademicTerm(),
  termStart: "",
  courses: [],
  overrides: {},
  grades: [],
  exams: [],
});
/**
 * 学校对某个学期返回空列表是合法的（假期、尚未排课），但把用户已有资料清空不可逆。
 * 只在「新结果为空且本地非空」时拒绝替换，其余情况仍按学校结果整体更新。
 */
function keepEmptyResult(next: unknown, previous: unknown[]): string | void {
  if (Array.isArray(next) && !next.length && previous.length)
    return "学校这次没有返回任何记录，已保留本机原有资料；请在设置里核对学年学期后重试。";
}
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
  successMessage = "学校资料已更新",
}: {
  dataset: AcademicDataset;
  onData: (value: unknown, snapshot: AcademicSnapshot) => string | void;
  successMessage?: string | null;
}) {
  const { requireUser, user } = useAuth(),
    ui = useUI(),
    store = useAcademic();
  const [provider, setProvider] = useState<AcademicProvider>(
    dataset === "physical"
      ? "physical"
      : dataset === "erke"
        ? "erke"
        : "undergraduate",
  );
  const [connection, setConnection] = useState<AssistantConnection | null>(
      null,
    ),
    [busy, setBusy] = useState(false),
    [status, setStatus] = useState(""),
    [failure, setFailure] = useState<BridgeErrorCode | undefined>();
  // 关注当前学校系统的授权位：本机还未授权时握手会继续复检，
  // 用户在助手页点完授权后本页能免刷新恢复。
  const assistant = useAssistantProbe({ watchProvider: provider });
  const pending = useRef<AbortController | null>(null),
    busyRef = useRef(false),
    automaticLogin = useRef(false),
    announced = useRef(false);
  busyRef.current = busy;
  useEffect(() => () => pending.current?.abort(), []);
  useEffect(() => {
    if (assistant.state !== "ready" || announced.current) return;
    announced.current = true;
    if (!busyRef.current) setStatus("教务助手已连接，可以继续。");
  }, [assistant.state]);
  // 助手已保有这台学校系统的连接时复用其代次：重新打开弹窗不再重跑 session
  // （站点账号核对 + 学校身份页各一次）。真正读取前 query 仍会重新核对身份，
  // 所以这里只是省去重复握手，没有放松写入边界。
  useEffect(() => {
    const known = assistant.connections.find(
      (c) => c.provider === provider && c.state === "connected",
    );
    if (!known || busyRef.current) return;
    setConnection((current) => current || known);
  }, [assistant.connections, provider]);
  async function verifySiteUser(signal: AbortSignal) {
    const currentUser = entity(await request("/api/user/profile", { signal }), "user", "data");
    if (currentUser.id !== user?.id)
      throw new BridgeFailure("site_login_required", "本站账号已改变，请刷新网页后重新连接。");
  }
  async function act(fn: (signal: AbortSignal) => Promise<void>) {
    if (busyRef.current) return;
    if (!requireUser()) return;
    busyRef.current = true;
    const controller = new AbortController();
    pending.current = controller;
    setBusy(true);
    setStatus("正在连接本机助手…");
    setFailure(undefined);
    assistant.setPaused(true);
    try {
      // 由同源网页先刷新过期的 HttpOnly 会话，扩展始终只核对 Cookie，
      // 不取得 Token，也不因页面缓存的旧用户资料而误报学校连接失败。
      await verifySiteUser(controller.signal);
      const hello = await bridge<HelloResult>("hello", {}, controller.signal);
      automaticLogin.current = hello?.automaticLogin === true;
      assistant.markReady();
      await fn(controller.signal);
    } catch (e) {
      if (!controller.signal.aborted) {
        const code = bridgeErrorCode(e);
        // 连接或身份已失效时把界面退回「未连接」，否则用户会对着过期代次反复点击。
        if (
          code === "connection_stale" ||
          code === "identity_changed" ||
          code === "site_login_required"
        )
          setConnection(null);
        setFailure(code);
        setStatus(errorText(e));
        assistant.recheck();
      }
    } finally {
      assistant.setPaused(false);
      busyRef.current = false;
      setBusy(false);
      if (pending.current === controller) pending.current = null;
    }
  }
  async function login(signal: AbortSignal) {
    setStatus("请在助手页完成首次授权；已保存凭据时会自动登录，成功后自动返回并读取资料…");
    const ready = await waitForSchoolLogin(provider, signal, setStatus, () => verifySiteUser(signal));
    if (!ready) setStatus("已打开学校登录助手。请完成登录后返回，重新点击连接并读取资料。");
    return ready;
  }
  async function readSchoolData(signal: AbortSignal, known?: AssistantConnection, retryLogin = true): Promise<void> {
    try {
      setStatus("正在获取学校身份…");
      const value = known || await bridge<AcademicConnection>("session", { provider }, signal);
      if (!known && 'appUserId' in value && value.appUserId !== user?.id)
        throw new BridgeFailure("connection_stale", "本站账号已改变，本次学校连接未写入。");
      if (!known && (provider === "undergraduate" || provider === "graduate")) {
        await request("/api/student-identity/bind", {
          method: "POST", signal, headers: {"X-Expected-App-User": String(user!.id)},
          body: JSON.stringify({ provider_id: `sylu_${provider}`, student_id: value.studentId, verification_method: "local_academic_login" }),
        });
      }
      if (signal.aborted) return;
      setConnection(value);
      setStatus(`已连接 ${value.displayName || value.studentId}，正在读取资料…`);
      const snapshot = await bridge<AcademicSnapshot>("query", { provider, dataset, term: store.data.term, epoch: value.epoch }, signal);
      if (signal.aborted) return;
      const note = onData(snapshot.data, snapshot);
      if (note) { setStatus(note); return; }
      store.setUpdated(snapshot.fetchedAt);
      if (successMessage) ui.notify(successMessage);
      ui.close();
    } catch (error) {
      const code = bridgeErrorCode(error);
      if (retryLogin && automaticLogin.current && (code === "school_login_required" || code === "authorization_required")) {
        setConnection(null);
        if (await login(signal)) await readSchoolData(signal, undefined, false);
      } else throw error;
    }
  }
  const unauthorized = assistant.authorized
    ? assistant.authorized[provider] === false
    : failure === "authorization_required";
  const guidance = unauthorized
    ? "本机助手还未获准访问这所学校的教务系统。用下方按钮打开助手页并授予权限，回到本页会自动继续，不必刷新。"
    : failure === "school_login_required"
      ? "学校登录已过期：用下方按钮打开学校登录助手；新版助手完成登录后会自动返回并读取。"
      : failure === "site_login_required"
        ? "沈理校园的登录状态已失效，请重新登录本站后再连接教务助手。"
        : failure === "identity_changed" || failure === "connection_stale"
          ? "本机教务连接已过期，重新点击「连接并读取资料」即可核对身份。"
          : "";
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
        <li className={assistant.state === "ready" ? "done" : "active"}><b>1</b><span>检测助手</span></li>
        <li className={connection ? "done" : assistant.state === "ready" ? "active" : ""}><b>2</b><span>获取身份</span></li>
        <li className={connection ? "done" : ""}><b>3</b><span>读取资料</span></li>
      </ol>
      <div className="inline-actions">
        <button
          className="btn primary"
          disabled={busy}
          onClick={() =>
            act(signal => readSchoolData(signal))
          }
        >
          {busy ? "正在连接并读取…" : "连接并读取资料"}
        </button>
        <button
          className="btn ghost"
          disabled={busy}
          onClick={() =>
            act(async (signal) => {
              if (await login(signal)) await readSchoolData(signal, undefined, false);
            })
          }
        >
          {unauthorized ? "打开助手完成授权" : "学校未登录？打开登录页"}
        </button>
      </div>
      {guidance && <p className="notice-line">{guidance}</p>}
      {busy && <button className="btn ghost" onClick={() => { pending.current?.abort(); setStatus("已取消本次连接，原资料已保留。"); }}>取消连接</button>}
      <AssistantInstallGuide state={assistant.state} onRecheck={assistant.recheck} />
      {connection && (
        <>
          <p className="source-line">
            已连接：{connection.displayName} · {connection.studentId}
          </p>
          <label className="check-label"><input type="checkbox" disabled={busy} onChange={e=>{const enabled=e.target.checked;void act(async()=>{await bridge('persistence',{provider,epoch:connection.epoch,enabled});setStatus(enabled?'后续查询结果将保存在此电脑的扩展中':'已清除此身份的持久缓存')})}}/>在此电脑保存结构化资料</label>
          <button className="btn" disabled={busy} onClick={()=>act(async()=>{const snapshot=await bridge<AcademicSnapshot|null>('cache',{provider,epoch:connection.epoch,dataset,term:store.data.term});if(!snapshot)throw new Error('此身份和学期没有保存的资料');const note=onData(snapshot.data,snapshot);if(note){setStatus(note);return}store.setUpdated(snapshot.fetchedAt);setStatus('已恢复本地资料，请留意获取时间')})}>恢复本机资料</button>
          <button
            className="btn primary"
            disabled={busy}
            onClick={() =>
              act(signal => readSchoolData(signal, connection))
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
          options: [
            ["1", "周一"],
            ["2", "周二"],
            ["3", "周三"],
            ["4", "周四"],
            ["5", "周五"],
            ["6", "周六"],
            ["7", "周日"],
          ],
          value: String(course?.day || 1),
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
  return useMobile() ? <MobileSchedule /> : <DesktopSchedule />;
}
function MobileSchedule() {
  const store = useAcademic(), ui = useUI();
  const termLabel = mobileTermLabel(store.data.term);
  const [params, setParams] = useSearchParams();
  const week = Math.min(60, Math.max(1, Number(params.get('week')) || teachingWeek(store.data.termStart) || 1));
  const all = mergeCourses(store.data.courses, store.data.overrides);
  const courses = all.filter(course => course.weeks.includes(week));
  const monday = store.data.termStart ? new Date(`${store.data.termStart}T00:00:00`) : new Date();
  if (store.data.termStart) monday.setDate(monday.getDate() + (week - 1) * 7);
  else monday.setDate(monday.getDate() - (monday.getDay() + 6) % 7);
  const dates = Array.from({ length: 7 }, (_, index) => {
    const date = new Date(monday);
    date.setDate(date.getDate() + index);
    return date;
  });
  function connect() {
    ui.open('更新学校课表', <ConnectionForm dataset="courses" onData={value => {
      const note = keepEmptyResult(value, store.data.courses);
      if (note) return note;
      store.setData(previous => ({ ...previous, courses: value as Course[] }));
    }} />);
  }
  function tools() {
    ui.open('课表工具', <div className="mobile-settings-actions">
      <button className="btn" onClick={() => ui.open('课表设置', <AcademicSettings />)}>课表设置与导入</button>
      <button className="btn" onClick={() => ui.open('添加课程', <CourseForm />)}>添加课程</button>
      <button className="btn" onClick={connect}>连接教务助手 / 刷新</button>
      <button className="btn" onClick={() => downloadJSON('sylulive-academic.json', store.data)}>导出课表</button>
      <button className="btn" onClick={() => ui.open('课程提醒与小窗', <ReminderSettings />)}>课程提醒与小窗</button>
      <button className="btn" onClick={() => ui.open('本周空闲节次', <>{Array.from({ length: 7 }, (_, day) => <p key={day}>周{day + 1} · {Array.from({ length: 12 }, (_, period) => period + 1).filter(period => !courses.some(course => course.day === day + 1 && course.periods.includes(period))).join('、') || '无'}</p>)}</>)}>查看空闲节次</button>
      <button className="btn" onClick={() => ui.open('本地调整', <><p>清除调整后恢复学校原始课表。</p><button className="btn" onClick={() => { store.setData(previous => ({ ...previous, overrides: {} })); ui.close(); }}>清除本地调整</button></>)}>管理本地调整</button>
    </div>);
  }
  return <div className="mobile-schedule">
    <header className="mobile-page-heading"><div><h1>课表</h1><p>{termLabel}</p></div><button className="mobile-icon-button" aria-label="课表工具" onClick={tools}><Icon name="more" size={24} /></button></header>
    <div className="mobile-week-nav"><button className="mobile-icon-button" aria-label="上一周" disabled={week === 1} onClick={() => setParams({ week: String(week - 1) })}><Icon name="arrow" size={17} /></button><b>第 {week} 周 · {dates[0].getMonth() + 1}/{dates[0].getDate()} – {dates[6].getMonth() + 1}/{dates[6].getDate()}</b><button className="mobile-icon-button next" aria-label="下一周" disabled={week === 60} onClick={() => setParams({ week: String(week + 1) })}><Icon name="arrow" size={17} /></button></div>
    <div className="mobile-week-days">{dates.map((date, index) => <div className={date.toDateString() === new Date().toDateString() ? 'today' : ''} key={index}><b>{['一', '二', '三', '四', '五', '六', '日'][index]}</b><span>{date.getMonth() + 1}/{date.getDate()}</span></div>)}</div>
    {!all.length ? <section className="mobile-schedule-empty"><i><Icon name="schedule" size={38} /></i><h2>还没有课表</h2><span className="mobile-term-hint">推荐导入 {termLabel}</span><p>还没有任何课表数据，可以通过教务助手读取，或导入本地课表。</p><button className="btn primary" onClick={connect}>课表拉取</button><button className="link-btn" onClick={() => ui.open('课表设置', <AcademicSettings />)}>切换历史学期 / 导入课表</button></section>
      : <div className="schedule mobile-course-grid"><div className="sch-head">节次</div>{['一', '二', '三', '四', '五', '六', '日'].map(day => <div className="sch-head" key={day}>{day}</div>)}{Array.from({ length: 6 }, (_, index) => index * 2 + 1).map(period => <Row key={period} period={period} days={7} courses={courses} onEdit={course => ui.open('课程详情与编辑', <CourseForm course={course} />)} />)}</div>}
    {!all.length && <p className="mobile-schedule-steps">1 选择学期 · 2 预览课程 · 3 设置开学第一周</p>}
  </div>;
}
function DesktopSchedule() {
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
  const openConnect = () =>
    ui.open(
      "更新学校课表",
      <ConnectionForm
        dataset="courses"
        onData={(value) => {
          const note = keepEmptyResult(value, store.data.courses);
          if (note) return note;
          store.setData((s) => ({ ...s, courses: value as Course[] }));
        }}
      />,
    );
  const todayIndex = (new Date().getDay() || 7) - 1;
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
        <button className="link-btn" onClick={openConnect}>
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
        {!store.data.courses.length && (
          <div className="schedule-empty-hint">
            <Icon name="schedule" size={22} />
            <b>还没有课表</b>
            <p>连接教务助手自动读取本学期课表，也可以手动添加课程。</p>
            <div className="empty-actions">
              <button className="btn primary" onClick={openConnect}>连接教务助手</button>
              <button className="btn" onClick={() => ui.open("添加课程", <CourseForm />)}>手动添加</button>
            </div>
          </div>
        )}
        <div
          className="schedule"
          style={{
            gridTemplateColumns: `86px repeat(${weekend ? 7 : 5},minmax(104px,1fr))`,
          }}
        >
          <div className="sch-head">节次</div>
          {["一", "二", "三", "四", "五", "六", "日"]
            .slice(0, weekend ? 7 : 5)
            .map((d, index) => (
              <div className={`sch-head ${index === todayIndex ? "today" : ""}`} key={d}>
                周{d}
              </div>
            ))}
          {Array.from({ length: 6 }, (_, i) => i * 2 + 1).map((period) => (
            <Row
              key={period}
              period={period}
              today={todayIndex}
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
// 与 App 课表页一致的大节作息，键为大节起始小节。
const PERIOD_TIMES: Record<number, string> = { 1: "08:00–09:40", 3: "10:00–11:40", 5: "13:00–14:40", 7: "14:50–16:30", 9: "16:40–18:20", 11: "19:30–21:10" };
function Row({
  period,
  today,
  days,
  courses,
  onEdit,
}: {
  period: number;
  today?: number;
  days: number;
  courses: Course[];
  onEdit: (c: Course) => void;
}) {
  return (
    <>
      <div className="sch-time">第 {period}–{period+1} 节{PERIOD_TIMES[period] && <small>{PERIOD_TIMES[period]}</small>}</div>
      {Array.from({ length: days }, (_, i) => (
        <div className={`sch-cell ${i === today ? "is-today" : ""}`} key={i}>
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
                  if (dataset === 'grades') {
                    const note = keepEmptyResult(value, store.data.grades);
                    if (note) return note;
                    store.setData((s) => ({ ...s, grades: value as Grade[] }));
                  }
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
              <Empty icon="grades" description="通过教务助手更新成绩，或导入本地资料。" />
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
