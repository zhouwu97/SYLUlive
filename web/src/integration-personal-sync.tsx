import { useRef, useState, useEffect } from "react";
import type { AcademicSnapshot, Grade } from "@sylulive/academic-contracts";
import { ConnectionForm } from "./academic";
import { ApiError, captureAuthSession, write } from "./api";
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

export function IntegrationPersonalSync({ enabled }: { enabled?: boolean }) {
  const ui = useUI();
  const [dataset, setDataset] = useState<"grades" | "erke">("grades");
  const [snapshot, setSnapshot] = useState<AcademicSnapshot | null>(null);
  const [confirmed, setConfirmed] = useState(false), [busy, setBusy] = useState(false), [message, setMessage] = useState("");
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  function prepare() {
    const session = captureAuthSession();
    ui.open(dataset === "grades" ? "读取本机成绩" : "读取本机二课", <ConnectionForm dataset={dataset} onData={(_, value) => {
      if (!mounted.current || !session()) return "账号已切换，请重新读取。";
      try { makePersonalUpload(value); } catch (error) { return error instanceof Error ? error.message : "资料无效"; }
      setSnapshot(value); setConfirmed(false); setMessage("资料已在本机准备，尚未上传。");
    }} />);
  }
  async function act(remove: boolean) {
    const session = captureAuthSession(), current = () => mounted.current && session();
    setBusy(true); setMessage("");
    try {
      const path = dataset === "grades" ? "/api/connected-apps/personal-sync/grades" : "/api/personal-snapshots/erke";
      if (remove) await write(path, {}, "DELETE");
      else if (snapshot && confirmed) await write(path, makePersonalUpload(snapshot), dataset === "grades" ? "POST" : "PUT");
      else return;
      if (current()) { setSnapshot(null); setConfirmed(false); setMessage(remove ? "该类上传副本已删除。删除成绩上传副本不删除 App 原有教务云快照。" : "已同步最小资料。QQ 查询还需本人绑定并勾选对应读取权限；不会自动给机器人授权。"); }
    } catch (error) {
      if (current()) setMessage(error instanceof ApiError && error.code === "SCHOOL_AUTHORITY_RETIRED"
        ? "服务端已停用二课云资料接口，本次操作未完成。请联系站点维护者处理已有副本，重复点击不会恢复接口。"
        : error instanceof ApiError && error.code === "personal_data_disabled"
        ? "隐私设置已关闭该类上传，请本人先检查设置。"
        : error instanceof ApiError && error.code === "academic_verification_required"
          ? "当前账号缺少受支持的教务身份核验；本机自报身份不能代替核验。"
          : error instanceof ApiError && error.code === "older_snapshot_rejected"
            ? "已有较新的成绩上传副本，本次未覆盖。请重新读取本机资料后再同步。"
          : error instanceof ApiError && ["invalid_personal_upload", "invalid_erke_snapshot"].includes(error.code)
            ? "资料格式或获取时间无效，本次未同步。请核对设备时间并重新读取，不要上传原始页面。"
          : "操作未完成，请核对身份、隐私设置和网络后重试；尚未确认同步结果。");
    } finally { if (current()) setBusy(false); }
  }
  return <section className="panel panel-pad integration-panel">
    <h2>供本人 QQ 查询的资料同步</h2>
    {enabled !== true && <p role="status">{enabled === false ? "服务端尚未开放个人查询" : "尚未确认服务端个人查询状态，请刷新连接列表后重试"}，暂不读取或同步新资料；仍可删除成绩上传副本，公开查询不受影响。</p>}
    <p>学校资料默认留在本机。此处由你主动读取并确认，只上传结构化最小资料，5天后标记过期，副本保留至你删除或覆盖；不上传学校密码、Cookie、原始页面或完整活动记录。只读取一个学期或毕业二课摘要，不代表全部成绩或活动。</p>
    <label className="field">资料类型<select disabled={busy} value={dataset} onChange={e => { setDataset(e.target.value as "grades" | "erke"); setSnapshot(null); setConfirmed(false); setMessage(""); }}><option value="grades">当前学期成绩</option><option value="erke">二课毕业摘要</option></select></label>
    <button className="btn" disabled={busy || !enabled} onClick={prepare}>从本机教务助手读取</button>
    {snapshot && <p>已准备：{dataset === "grades" ? `当前学期 ${Array.isArray(snapshot.data) ? snapshot.data.length : 0} 门课程` : "二课毕业摘要（不含学年及活动明细）"} · {new Date(snapshot.fetchedAt).toLocaleString()}</p>}
    <label><input type="checkbox" checked={confirmed} disabled={busy} onChange={e => setConfirmed(e.target.checked)} />我确认仅操作当前账号的资料，了解云端保存与已授权机器人读取范围</label>
    <div className="form-actions"><button className="btn primary" disabled={busy || !enabled || !snapshot || !confirmed} onClick={() => void act(false)}>确认同步最小资料</button><button className="btn" disabled={busy || !confirmed} onClick={() => void act(true)}>删除该类上传副本</button></div>
    {message && <p role="status">{message}</p>}
  </section>;
}
