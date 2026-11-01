import { useRef, useState, useEffect } from "react";
import type { AcademicSnapshot, Grade } from "@sylulive/academic-contracts";
import { ConnectionForm } from "./academic";
import { ApiError, captureAuthSession, write, time } from "./api";
import { useUI } from "./ui";

export function makePersonalUpload(snapshot: AcademicSnapshot): Record<string, unknown> {
  if (snapshot.dataset === "grades") {
    if (!Array.isArray(snapshot.data)) throw new Error("成绩格式无效，请重新读取本机资料。");
    return {
      consent: true, fetched_at: snapshot.fetchedAt, year: snapshot.term.year,
      semester: Number(snapshot.term.semester),
      grades: (snapshot.data as Grade[]).map(row => ({
        course_name: row.name, score: row.score, credits: row.credit,
        ...(row.gpa !== null && row.gpa !== undefined ? { gpa: row.gpa } : {}),
        course_nature: row.nature,
      })),
    };
  }
  if (snapshot.dataset !== "erke" || !snapshot.data || typeof snapshot.data !== "object") throw new Error("不支持此类资料同步。");
  const data = snapshot.data as { earned: number; required: number; categories: { name: string; earned: number; required: number }[] };
  if (![data.earned, data.required].every(Number.isFinite) || !Array.isArray(data.categories)) throw new Error("二课摘要格式无效，请重新读取。");
  const gaps = data.categories.map(row => ({ name: row.name, gap: Math.max(0, row.required - row.earned) }));
  return {
    schema_version: 2, fetched_at: snapshot.fetchedAt,
    graduation: { earned_total: data.earned, required_total: data.required,
      graduation_gap: Math.max(0, data.required - data.earned, gaps.reduce((sum, row) => sum + row.gap, 0)),
      unmet_categories: gaps.filter(row => row.gap > 0) },
    yearly: {}, recent_activities: [],
  };
}

type Feedback = { text: string; error?: boolean };
export function IntegrationPersonalSync({ enabled }: { enabled?: boolean }) {
  const ui = useUI();
  const [dataset, setDataset] = useState<"grades" | "erke">("grades");
  const [snapshot, setSnapshot] = useState<AcademicSnapshot | null>(null);
  const [confirmed, setConfirmed] = useState(false), [deleteConfirmed, setDeleteConfirmed] = useState(false);
  const [busy, setBusy] = useState<"upload" | "delete" | null>(null), [message, setMessage] = useState<Feedback | null>(null);
  const mounted = useRef(true), inFlight = useRef(false), generation = useRef(0);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; generation.current += 1; }; }, []);
  function prepare() {
    if (enabled !== true || inFlight.current) return;
    const session = captureAuthSession(), version = ++generation.current;
    ui.open(dataset === "grades" ? "读取本机成绩" : "读取本机二课", <ConnectionForm dataset={dataset} successMessage={null} onData={(_, value) => {
      if (!mounted.current || !session() || generation.current !== version) return "当前页面或账号已变化，请重新读取。";
      if (value.dataset !== dataset) return "资料类型不匹配，请重新读取。";
      try { makePersonalUpload(value); } catch (error) { return error instanceof Error ? error.message : "资料无效"; }
      setSnapshot(value); setConfirmed(false); setMessage({ text: "资料已在本机准备，尚未上传。" });
    }} />);
  }
  async function act(remove: boolean) {
    if (inFlight.current || (remove ? !deleteConfirmed : enabled !== true || !snapshot || !confirmed)) return;
    inFlight.current = true;
    const session = captureAuthSession(), current = () => mounted.current && session();
    setBusy(remove ? "delete" : "upload"); setMessage(null);
    try {
      const path = dataset === "grades" ? "/api/connected-apps/personal-sync/grades" : "/api/personal-snapshots/erke";
      if (remove) await write(path, {}, "DELETE");
      else await write(path, makePersonalUpload(snapshot!), dataset === "grades" ? "POST" : "PUT");
      if (current()) {
        setSnapshot(null); setConfirmed(false); setDeleteConfirmed(false);
        setMessage({ text: remove ? "该类上传副本已删除。删除成绩上传副本不删除 App 原有教务云快照。" : "已同步最小资料。QQ 查询还需本人绑定并勾选对应读取权限；不会自动给机器人授权。" });
      }
    } catch (error) {
      if (current()) setMessage({ error: true, text: error instanceof ApiError && error.code === "SCHOOL_AUTHORITY_RETIRED"
        ? "服务端已停用二课云资料接口，本次操作未完成。请联系站点维护者处理已有副本，重复点击不会恢复接口。"
        : error instanceof ApiError && error.code === "personal_queries_disabled"
          ? "服务端已关闭个人查询，本次未同步；公开查询不受影响。"
        : error instanceof ApiError && error.code === "personal_data_disabled"
          ? "隐私设置已关闭该类上传，请本人先检查设置。"
        : error instanceof ApiError && error.code === "academic_verification_required"
          ? "当前账号缺少受支持的教务身份核验；本机自报身份不能代替核验。"
        : error instanceof ApiError && error.code === "older_snapshot_rejected"
          ? "已有较新的成绩上传副本，本次未覆盖。请重新读取本机资料后再同步。"
        : error instanceof ApiError && ["invalid_personal_upload", "invalid_erke_snapshot"].includes(error.code)
          ? "资料格式或获取时间无效，本次未同步。请核对设备时间并重新读取，不要上传原始页面。"
          : "操作未完成，请核对身份、隐私设置和网络后重试；尚未确认同步结果。" });
    } finally { inFlight.current = false; if (current()) setBusy(null); }
  }
  return <section className="panel panel-pad integration-panel integration-sync" aria-label="个人资料同步">
    <header><h2>供本人 QQ 查询的资料同步</h2><p>先在本机读取并核对，再决定是否同步给已授权助手。</p></header>
    {enabled !== true && <p className="sync-notice" role="status">{enabled === false ? "服务端尚未开放个人查询" : "尚未确认服务端个人查询状态，请刷新连接列表后重试"}，暂不读取或同步新资料；仍可删除成绩上传副本，公开查询不受影响。</p>}
    <ol className="sync-steps" aria-label="资料同步步骤"><li aria-current={!snapshot ? "step" : undefined}>1. 准备资料</li><li aria-current={snapshot ? "step" : undefined}>2. 核对并同步</li></ol>
    <div className="sync-prepare">
      <label className="field">资料类型<select disabled={!!busy} value={dataset} onChange={e => { generation.current += 1; setDataset(e.target.value as "grades" | "erke"); setSnapshot(null); setConfirmed(false); setDeleteConfirmed(false); setMessage(null); }}><option value="grades">当前学期成绩</option><option value="erke">二课毕业摘要</option></select></label>
      <button className="btn" disabled={!!busy || enabled !== true} onClick={prepare}>从本机教务助手读取</button>
    </div>
    {snapshot ? <PersonalPreview snapshot={snapshot} /> : <p className="sync-hint">尚未准备资料。当前学期成绩或二课毕业摘要会先显示在这里，读取本机资料不会自动上传。</p>}
    <p className="sync-retention">只同步最小资料，5 天后标记过期，云端副本保留至你删除或覆盖。上传不等于授权机器人；QQ 查询需本人另行批准。</p>
    <label className="sync-confirm"><input type="checkbox" checked={confirmed} disabled={!!busy || !snapshot || enabled !== true} onChange={e => setConfirmed(e.target.checked)} /><span>我确认仅操作当前账号的资料，了解云端保存与已授权机器人读取范围</span></label>
    <button className="btn primary sync-submit" disabled={!!busy || enabled !== true || !snapshot || !confirmed} onClick={() => void act(false)}>{busy === "upload" ? "正在同步…" : "确认同步最小资料"}</button>
    {message && <p className={`sync-notice ${message.error ? "is-error" : "is-success"}`} role={message.error ? "alert" : "status"}>{message.text}</p>}
    <details className="sync-details"><summary>查看同步范围</summary><p>学校资料默认留在本机。这里只同步一个学期的课程名称、成绩、学分等，或二课毕业总量与分类缺口；不包含学校密码、Cookie、原始页面和完整活动记录，也不代表学校实时查询。</p></details>
    <details className="sync-details sync-delete"><summary>删除云端上传副本</summary>
      <p>当前选择：{dataset === "grades" ? "当前学期成绩" : "二课毕业摘要"}。删除这类上传副本不会撤销助手授权，也不删除 App 原有教务云快照或已发送到 QQ 的内容。</p>
      <label className="sync-confirm"><input type="checkbox" checked={deleteConfirmed} disabled={!!busy} onChange={e => setDeleteConfirmed(e.target.checked)} /><span>确认删除当前选择的上传副本</span></label>
      <button className="btn danger" disabled={!!busy || !deleteConfirmed} onClick={() => void act(true)}>{busy === "delete" ? "正在删除…" : "删除该类上传副本"}</button>
    </details>
  </section>;
}

function PersonalPreview({ snapshot }: { snapshot: AcademicSnapshot }) {
  const grades = snapshot.dataset === "grades" ? snapshot.data as Grade[] : null;
  const erke = grades ? null : makePersonalUpload(snapshot).graduation as { earned_total: number; required_total: number; graduation_gap: number; unmet_categories: { name: string; gap: number }[] };
  return <section className="sync-preview" aria-label="待同步资料预览">
    <div className="sync-preview-heading"><h3>待同步资料预览</h3><span>尚未上传</span></div>
    <p className="sync-hint">获取于 {time(snapshot.fetchedAt)} · {grades ? `当前学期 ${grades.length} 门课程` : "二课毕业摘要"}</p>
    {Date.now() - Date.parse(snapshot.fetchedAt) >= 5 * 24 * 60 * 60 * 1000 && <p className="sync-notice">这份资料已超过 5 天，同步后仍会标记过期，建议先重新读取。</p>}
    {grades ? <>
      {grades.length > 0 ? <table><thead><tr><th scope="col">课程</th><th scope="col">成绩</th><th scope="col">学分</th></tr></thead><tbody>{grades.slice(0, 5).map((row, i) => <tr key={i}><td>{row.name}</td><td>{row.score ?? "未公布"}</td><td>{row.credit ?? "未提供"}</td></tr>)}</tbody></table> : <p>本次读取没有课程成绩，请确认学期后再同步。</p>}
      {grades.length > 5 && <p className="sync-hint">预览前 5 门，同步将包含本次读取的全部 {grades.length} 门课程。</p>}
    </> : erke && <>
      <dl className="sync-totals"><div><dt>已获积分</dt><dd>{erke.earned_total}</dd></div><div><dt>毕业要求</dt><dd>{erke.required_total}</dd></div><div><dt>还差</dt><dd>{erke.graduation_gap}</dd></div></dl>
      {erke.unmet_categories.length > 0 && <ul>{erke.unmet_categories.slice(0, 6).map((row, i) => <li key={i}>{row.name}：还差 {row.gap} 分</li>)}</ul>}
      <p className="sync-hint">仅毕业摘要，不包含学年与完整活动明细。{erke.unmet_categories.length > 6 ? "此处仅预览前 6 个分类，同步包含全部缺口分类。" : ""}</p>
    </>}
  </section>;
}
