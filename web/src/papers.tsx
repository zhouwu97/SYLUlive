import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { ApiError, query, requestBlob, rows, useApi, write, type Entity } from "./api";
import { Empty, Form, Head, Pagination, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";

const semesterLabels: Record<string, string> = { first: "第一学期", second: "第二学期", other: "其他" };
const examLabels: Record<string, string> = { final: "期末", midterm: "期中", makeup: "补考", retake: "重修", other: "其他" };
const statusLabels: Record<string, string> = { pending: "待审核", published: "已发布", rejected: "未通过", unpublished: "已下架" };
const formatSize = (value: unknown) => { const size = Number(value); if (!size) return "未知大小"; return size > 1024 * 1024 ? `${(size / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(size / 1024))} KB`; };

export const paperFields = (paper: Entity = {}) => [
  { name: "course_name", label: "课程名称", required: true, value: paper.course_name },
  { name: "academic_year", label: "学年（如 2025-2026）", required: true, value: paper.academic_year },
  { name: "semester", label: "学期", value: paper.semester, options: [["first", "第一学期"], ["second", "第二学期"], ["other", "其他"]] as [string, string][] },
  { name: "exam_type", label: "考试类型", value: paper.exam_type, options: [["final", "期末"], ["midterm", "期中"], ["makeup", "补考"], ["retake", "重修"], ["other", "其他"]] as [string, string][] },
];

export function PaperLibrary() {
  const [params, setParams] = useSearchParams();
  const ui = useUI(), auth = useAuth();
  const mine = params.get("papers") === "mine";
  const page = Number(params.get("paper_page")) || 1;
  const path = mine ? "/api/exam-papers/my-submissions" : "/api/exam-papers";
  const q = useApi(query(path, { page, page_size: 20, keyword: params.get("keyword"), academic_year: params.get("academic_year"), semester: params.get("semester"), exam_type: params.get("exam_type"), status: mine ? params.get("paper_status") : undefined, sort: params.get("sort") }));
  const update = (values: Record<string, string>) => { const next = new URLSearchParams(params); Object.entries(values).forEach(([key, value]) => value ? next.set(key, value) : next.delete(key)); setParams(next); };
  const academicYears = Array.isArray(q.data?.academic_years) ? q.data.academic_years : [];
  const papers = rows(q.data);
  return <section className="panel panel-pad paper-library"><Head title="试卷库" description="经授权访问的历史试卷与本人投稿"><button className="btn primary" onClick={() => auth.requireUser() && ui.open("上传试卷", <PaperUpload />)}>上传 PDF</button></Head>
    <Tabs value={mine ? "mine" : "library"} tabs={[["library", "试卷搜索"], ["mine", "我的投稿"]]} onChange={(value) => update({ papers: value === "mine" ? "mine" : "", paper_page: "1" })} />
    <form className="paper-filters" onSubmit={(event) => { event.preventDefault(); update({ keyword: String(new FormData(event.currentTarget).get("keyword") || ""), paper_page: "1" }); }}>
      <input name="keyword" aria-label="搜索试卷" placeholder="搜索课程名称" defaultValue={params.get("keyword") || ""} />
      <select aria-label="学年" value={params.get("academic_year") || ""} onChange={(event) => update({ academic_year: event.target.value, paper_page: "1" })}><option value="">全部学年</option>{academicYears.map((year: string) => <option key={year} value={year}>{year}</option>)}</select>
      <select aria-label="学期" value={params.get("semester") || ""} onChange={(event) => update({ semester: event.target.value, paper_page: "1" })}><option value="">全部学期</option>{Object.entries(semesterLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
      <select aria-label="考试类型" value={params.get("exam_type") || ""} onChange={(event) => update({ exam_type: event.target.value, paper_page: "1" })}><option value="">全部类型</option>{Object.entries(examLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
      {mine && <select aria-label="投稿状态" value={params.get("paper_status") || ""} onChange={(event) => update({ paper_status: event.target.value, paper_page: "1" })}><option value="">全部状态</option>{Object.entries(statusLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>}
      {!mine && <select aria-label="排序" value={params.get("sort") || "latest"} onChange={(event) => update({ sort: event.target.value, paper_page: "1" })}><option value="latest">最新发布</option><option value="downloads">下载最多</option></select>}
      <button className="btn">搜索</button>
    </form>
    <QueryState query={q}>
      <div className="paper-stats"><span>共 {q.data?.total || papers.length} 份</span>{q.data?.status_counts && Object.entries(q.data.status_counts).map(([key, value]) => <span key={key}>{statusLabels[key] || key} {String(value)}</span>)}</div>
      <div className="paper-list">{papers.map((paper) => <PaperRow key={paper.id} paper={paper} mine={mine} onOpen={() => ui.open(paper.title || "试卷详情", <PaperDetail paper={paper} />)} onWithdraw={() => ui.open("撤回投稿", <WithdrawPaper id={Number(paper.id)} />)} />)}</div>
      {!papers.length && <Empty title="暂无符合条件的试卷" description="可以换一个课程、学年或考试类型试试" />}
      <Pagination page={page} hasMore={page * 20 < Number(q.data?.total || 0)} onChange={(nextPage) => update({ paper_page: String(nextPage) })} />
    </QueryState>
  </section>;
}

function PaperRow({ paper, mine, onOpen, onWithdraw }: { paper: Entity; mine: boolean; onOpen: () => void; onWithdraw: () => void }) {
  const reason = paper.approval_reason || paper.unpublish_reason;
  return <article className="paper-row"><div className="paper-row-icon"><span>PDF</span></div><div className="paper-row-main"><div className="paper-row-title"><b>{paper.title || paper.course_name || "未命名试卷"}</b><span className={`tag ${paper.status === "published" ? "brand" : ""}`}>{statusLabels[paper.status] || paper.status || "未知状态"}</span></div><p>{paper.course_name || "未填写课程"} · {paper.academic_year || "未知学年"} · {semesterLabels[paper.semester] || paper.semester || "未知学期"} · {examLabels[paper.exam_type] || paper.exam_type || "其他"}</p><small>{formatSize(paper.file_size)} · 下载 {paper.download_count || 0} 次 · {paper.contributor?.nickname || "校园同学"}</small>{reason && <div className="paper-reason">{paper.status === "unpublished" ? "下架原因：" : "审核说明："}{reason}</div>}</div><div className="paper-row-actions"><button className="btn" onClick={onOpen}>查看</button>{mine && paper.status === "pending" && <button className="btn danger" onClick={onWithdraw}>撤回投稿</button>}</div></article>;
}

function WithdrawPaper({ id }: { id: number }) { const ui = useUI(); return <div><p>撤回后文件及奖励按服务端规则处理，确认撤回这份投稿？</p><button className="btn danger" onClick={async () => { if (await ui.act(() => write(`/api/exam-papers/my-submissions/${id}`, {}, "DELETE"), "投稿已撤回")) ui.close(); }}>确认撤回</button></div>; }

function PaperDetail({ paper }: { paper: Entity }) {
  const [showPreview, setShowPreview] = useState(false);
  const published = paper.status === "published";
  return <div className="paper-detail"><div className="paper-detail-meta"><span className={`tag ${published ? "brand" : ""}`}>{statusLabels[paper.status] || paper.status}</span><b>{paper.course_name || "未填写课程"}</b><span>{paper.academic_year} · {semesterLabels[paper.semester] || paper.semester} · {examLabels[paper.exam_type] || paper.exam_type}</span><span>{formatSize(paper.file_size)} · 下载 {paper.download_count || 0} 次</span></div>{paper.approval_reason && <div className="info-box">审核说明：{paper.approval_reason}</div>}{paper.unpublish_reason && <div className="info-box">下架原因：{paper.unpublish_reason}</div>}{published ? <><div className="paper-preview-frame">{showPreview ? <PaperPreview id={Number(paper.id)} /> : <div className="paper-preview-placeholder"><div className="paper-preview-icon">PDF</div><b>PDF 预览</b><p>在当前页面查看试卷内容，保留原始 PDF 下载入口。</p><button className="btn primary" onClick={() => setShowPreview(true)}>打开预览</button></div>}</div><div className="form-actions"><a className="btn" href={`/api/exam-papers/${paper.id}/preview`} target="_blank" rel="noreferrer">新窗口打开</a><a className="btn primary" href={`/api/exam-papers/${paper.id}/download`}>下载试卷</a></div></> : <div className="empty-state"><b>试卷尚未发布</b><p>审核完成后才会开放预览和下载。</p></div>}</div>;
}

function PaperPreview({ id }: { id: number }) { const [url, setUrl] = useState(""), [error, setError] = useState(""); useEffect(() => { let objectURL = ""; setError(""); requestBlob(`/api/exam-papers/${id}/preview`).then((blob) => { objectURL = URL.createObjectURL(blob); setUrl(objectURL); }).catch((reason) => setError(reason instanceof Error ? reason.message : "预览加载失败")); return () => { if (objectURL) URL.revokeObjectURL(objectURL); }; }, [id]); if (error) return <div className="paper-preview-error"><b>预览加载失败</b><p>{error}</p><a className="btn" href={`/api/exam-papers/${id}/preview`} target="_blank" rel="noreferrer">新窗口打开</a></div>; if (!url) return <div className="loading-state">正在准备 PDF 预览…</div>; return <iframe title="试卷 PDF 预览" src={url} />; }

function PaperUpload() {
  const ui = useUI();
  return <Form fields={[...paperFields(), { name: "file", label: "PDF 文件（不超过 20 MiB）", type: "file", required: true, accept: "application/pdf,.pdf", help: "仅支持 PDF，文件内容会进行格式校验" }]} submit="上传并提交审核" onSubmit={async (values, form) => {
    const file = form.get("file"); if (!(file instanceof File) || !file.size || file.size > 20 * 1024 * 1024) throw new Error("请选择不超过 20 MiB 的 PDF 文件"); if (file.type && file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) throw new Error("请选择 PDF 文件"); if (await file.slice(0, 5).text() !== "%PDF-") throw new Error("文件内容不是 PDF"); if (form.get("privacy_confirmed") !== "on") throw new Error("请确认文件分享权限及隐私信息");
    const metadata = { course_name: values.course_name, academic_year: values.academic_year, semester: values.semester, exam_type: values.exam_type, privacy_confirmed: true }; const body = new FormData(); Object.entries(metadata).forEach(([key, value]) => body.set(key, String(value))); body.set("file", file);
    try { await write("/api/exam-papers", body); } catch (error) { if (!(error instanceof ApiError) || error.code !== "client_upgrade_required") throw error; const session = await write<any>("/api/exam-papers/upload-sessions", { ...metadata, file_size: file.size }); const target = new URL(session.upload_url); if (target.protocol !== "https:") throw new Error("文件服务未提供 HTTPS 上传地址"); const remote = new FormData(); remote.set("file", file); const response = await fetch(target, { method: "POST", headers: { Authorization: `Bearer ${session.upload_token}` }, body: remote, credentials: "omit", redirect: "error" }); const receipt = await response.json(); if (!response.ok || typeof receipt.receipt !== "string") throw new Error(receipt.error || "文件服务未返回有效回执"); await write(`/api/exam-papers/upload-sessions/${encodeURIComponent(session.session_id)}/complete`, { receipt: receipt.receipt }); }
    ui.notify("试卷已提交，审核结果请在我的投稿查看"); ui.close();
  }}><label className="check-label"><input name="privacy_confirmed" type="checkbox" required />文件不含隐私信息，且我拥有分享权限</label></Form>;
}
