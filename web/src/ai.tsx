import { gradeStats } from "@sylulive/academic-contracts";
import { useAcademic } from "./academic";
import { useEffect, useRef, useState } from "react";
import { useApi, rows, request, write, type Entity, errorText } from "./api";
import { Head, Icon, QueryState, useUI } from "./ui";
import { useAuth } from "./auth";
import { consumeSSE } from "./sse";
import './ai.css';
export function AiPage() {
  const auth = useAuth(),
    ui = useUI();
  const history = useApi(auth.user ? "/api/ai/conversations" : null);
  const [historyOpen, setHistoryOpen] = useState(false);
  const conversations = rows(history.data, 'conversations');
  const [conversation, setConversation] = useState(""),
    [question, setQuestion] = useState(""),
    [answer, setAnswer] = useState(""),
    [busy, setBusy] = useState(false),
    [stopping, setStopping] = useState(false),
    [historyLoading, setHistoryLoading] = useState(false),
    [error, setError] = useState(""),
    [sources, setSources] = useState<Entity[]>([]);
  const active = useRef<{ id: string; controller: AbortController } | null>(
    null,
  );
  const historyRead = useRef<AbortController | null>(null);
  useEffect(() => () => {
    active.current?.controller.abort();
    active.current = null;
    historyRead.current?.abort();
    historyRead.current = null;
  }, []);
  async function readConversation(id: string) {
    historyRead.current?.abort();
    const controller = new AbortController();
    historyRead.current = controller;
    setHistoryLoading(true);
    try {
      const data = await request(`/api/ai/conversations/${id}`, {signal: controller.signal});
      if (historyRead.current !== controller || controller.signal.aborted) return;
      setConversation(id);
      setHistoryOpen(false);
      setAnswer(rows(data, "messages").map(m => `${m.role === "user" ? "你" : "助手"}：${m.content}`).join("\n\n"));
      setSources([]);
      setError("");
    } catch (e) {
      if (historyRead.current === controller && !controller.signal.aborted) ui.notify(errorText(e));
    } finally {
      if (historyRead.current === controller) {
        historyRead.current = null;
        setHistoryLoading(false);
      }
    }
  }
  async function ask() {
    if (!question.trim() || busy || historyLoading || !auth.requireUser()) return;
    setBusy(true);
    setError("");
    setAnswer("");
    setSources([]);
    const controller = new AbortController();
    const operation = {id: "", controller};
    active.current = operation;
    const isCurrent = () => active.current === operation && !controller.signal.aborted;
    try {
      const created = await request("/api/ai/runs", {method: "POST", signal: controller.signal, body: JSON.stringify({
        message: question,
        client_request_id: crypto.randomUUID(),
        ...(conversation ? { conversation_id: conversation } : {}),
      })});
      if (!isCurrent()) return;
      const run = created.run;
      if (!run?.id) throw new Error("服务器未返回有效会话");
      operation.id = run.id;
      if (run.conversation_id) setConversation(run.conversation_id);
      const response = await fetch(`/api/ai/runs/${run.id}/events`, {
        credentials: "same-origin",
        signal: controller.signal,
      });
      await consumeSSE(response, (type, data) => {
        if (!isCurrent()) return;
        const value = data as Entity,
          p = value.payload || {};
        if (type === "answer.delta") setAnswer((s) => s + String(p.text || ""));
        if (type === "answer.checkpoint" || type === "answer.completed")
          setAnswer(String(p.text || ""));
        if (type === "run.failed")
          setError(p.message || p.error?.message || "生成未完成");
        if (type === "run.cancelled") setError("已取消");
        if (type === "sources.ready") setSources(rows(p, "sources"));
      });
      if (isCurrent()) await history.refetch();
    } catch (e) {
      if (isCurrent()) setError(errorText(e));
    } finally {
      if (active.current === operation) {
        active.current = null;
        setBusy(false);
      }
    }
  }
  async function cancel() {
    const run = active.current;
    if (!run || stopping) return;
    if (!run.id) {
      run.controller.abort();
      active.current = null;
      setBusy(false);
      setError("已停止等待创建结果；服务端是否已开始生成尚未确认，请从历史会话核对。");
      return;
    }
    setStopping(true);
    try {
      await write(`/api/ai/runs/${run.id}/cancel`);
      if (active.current !== run) return;
      run.controller.abort();
      active.current = null;
      setBusy(false);
      setError("已取消");
    } catch (e) {
      if (active.current === run) ui.notify(errorText(e));
    } finally {
      setStopping(false);
    }
  }
  return (
    <>
      <Head title="AI 校园助手" description="校园问答与公共信息查询">
        <button className="btn ai-history-toggle" aria-expanded={historyOpen} onClick={()=>setHistoryOpen(value=>!value)}><Icon name="clock" size={16}/>历史会话</button>
        <button
          className="btn"
          onClick={() =>
            auth.requireUser() &&
            ui.open("本地成绩分析 · 本次授权", <PersonalAnalysis />)
          }
        >
          分析我的成绩摘要
        </button>
      </Head>
      <div className={`ai-shell${historyOpen?' history-open':''}`}>
        <aside className="ai-side">
          <div className="ai-side-title"><Icon name="ai" size={20}/><b>校园问答</b><span>AI</span></div>
          <button
            className="btn primary full-width"
            disabled={busy}
            onClick={() => {
              historyRead.current?.abort();
              historyRead.current = null;
              setHistoryLoading(false);
              setConversation("");
              setAnswer("");
              setQuestion("");
              setError("");
              setSources([]);
              setHistoryOpen(false);
            }}
          >
            ＋ 新建会话
          </button>
          <div className="ai-history-heading">最近会话<span>{auth.user?conversations.length:''}</span></div>
          <nav className="ai-history" aria-label="历史会话">{auth.user ? (
            <QueryState query={history}>
              {conversations.map((c) => (
                <button
                  className="ai-history-item"
                  type="button"
                  disabled={busy}
                  key={c.id}
                  title={c.title||'校园问答'}
                  aria-pressed={conversation === String(c.id)}
                  onClick={() => void readConversation(String(c.id))}
                >
                  <Icon name="community" size={17}/><span>{c.title || "校园问答"}</span>
                </button>
              ))}
              {!conversations.length&&<p className="ai-history-empty">还没有会话，试着问一个校园问题吧。</p>}
            </QueryState>
          ):<div className="ai-history-empty"><Icon name="lock" size={22}/><p>登录后，随时继续之前的校园问答。</p><button className="btn" onClick={auth.login}>登录</button></div>}</nav>
          <p className="ai-side-note"><Icon name="info" size={14}/>回答仅供参考，请核对官方信息。</p>
        </aside>
        <div className="ai-main">
          <div className="ai-conversation-heading"><Icon name="ai" size={18}/><b>{conversations.find(c=>String(c.id)===conversation)?.title||'新的校园问答'}</b><span>{busy?'正在生成':historyLoading?'读取中':'校园公共信息'}</span></div>
          <div className="ai-content" aria-busy={historyLoading || busy}>
            {historyLoading && <p role="status">正在读取历史会话…</p>}
            {!answer && !busy ? (
              <div className="ai-welcome">
                <span className="ai-welcome-symbol"><Icon name="ai" size={34}/></span>
                <h2 className="ai-title">有什么校园问题？</h2>
                <p className="muted">可以问校园服务、活动与公开信息。</p>
                <div className="ai-suggest">
                  {[
                    "如何查询学校通知？",
                    "帮我规划竞赛准备步骤",
                    "校园有哪些常用服务？",
                    "如何高效安排复习？",
                  ].map((s) => (
                    <button type="button" key={s} onClick={() => setQuestion(s)}>
                      <Icon name="community" size={17}/><span>{s}</span><Icon name="chevron" size={14}/>
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              <div className="ai-output">{answer || "正在等待回答…"}</div>
            )}
            {error && (
              <p role="alert" className="field-error">
                {error}
              </p>
            )}
            {sources.length>0&&<div className="ai-sources"><b>参考来源</b>{sources.map((s, i) => (
              <p key={i}>{s.title || s.name}</p>
            ))}</div>}
          </div>
          <form
            className="ai-input"
            onSubmit={(e) => {
              e.preventDefault();
              void ask();
            }}
          >
            <textarea
              aria-label="问题"
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              placeholder="输入校园问题…"
              required
              maxLength={4000}
            />
            <div className="inline-actions">
              {busy ? (
                <button className="btn" type="button" disabled={stopping} onClick={event => {event.preventDefault(); void cancel();}}>
                  {stopping ? "正在停止…" : "停止生成"}
                </button>
              ) : (
                <button className="btn primary" disabled={historyLoading || stopping}>
                  {error ? "重试" : "发送"}
                </button>
              )}
              <span className="tiny muted">
                当前使用公共会话，请勿输入个人教务资料。
              </span>
            </div>
          </form>
        </div>
      </div>
    </>
  );
}

function PersonalAnalysis() {
  const store = useAcademic(),
    settings = useApi("/api/ai/local-analysis/settings");
  const [question, setQuestion] = useState(""),
    [review, setReview] = useState(false),
    [busy, setBusy] = useState(false),
    [answer, setAnswer] = useState(""),
    [error, setError] = useState("");
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  const stats = gradeStats(store.data.grades);
  const summary = {
    kind: "grade_statistics",
    course_count: store.data.grades.length,
    credits: stats.credits,
    average: stats.average,
    gpa: stats.gpa,
  };
  async function send() {
    setBusy(true);
    setReview(false);
    setAnswer("");
    setError("");
    const abort = new AbortController();
    controller.current = abort;
    try {
      const response = await fetch("/api/ai/local-analysis", {
        method: "POST",
        credentials: "same-origin",
        signal: abort.signal,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          question,
          model: settings.data?.default_model || "",
          summary,
          data_time: store.updated || new Date().toISOString(),
          consent: {
            accepted: true,
            accepted_at: new Date().toISOString(),
            request_id: crypto.randomUUID(),
          },
        }),
      });
      if (!response.ok) {
        const data = await response.json();
        throw new Error(data.message || "个人分析请求未完成");
      }
      await consumeSSE(response, (event, raw) => {
        const payload = (raw as Entity).payload || {};
        if (event === "answer.delta")
          setAnswer((s) => s + String(payload.text || ""));
        if (event === "run.failed") setError(payload.message || "个人分析中断");
      });
    } catch (e) {
      setError(
        abort.signal.aborted ? "已停止，重试需要再次确认摘要" : errorText(e),
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="dialog-form">
      <p className="muted">
        原始成绩仅在本机汇总。确认后，本次问题和以下统计摘要会发送给本服务配置的模型提供方；
        不会发送姓名、学号、课程名称、单科成绩或学校凭据。第三方留存以其政策为准。
      </p>
      <QueryState query={settings}>
        <p>模型：{settings.data?.default_model}</p>
        <div className="info-box">
          <p>课程数：{summary.course_count}</p>
          <p>已获学分：{summary.credits}</p>
          <p>加权平均分：{summary.average?.toFixed(2) || "暂无"}</p>
          <p>加权绩点：{summary.gpa?.toFixed(2) || "暂无"}</p>
          <p>
            数据时间：
            {store.updated
              ? new Date(store.updated).toLocaleString("zh-CN")
              : "本次导入 / 本地录入"}
          </p>
        </div>
        <label className="field">
          分析问题
          <textarea
            disabled={busy}
            maxLength={500}
            value={question}
            onChange={(e) => {
              setQuestion(e.target.value);
              setReview(false);
            }}
          />
        </label>
        {busy ? (
          <button className="btn" onClick={() => controller.current?.abort()}>
            停止生成
          </button>
        ) : review ? (
          <div className="inline-actions">
            <button className="btn primary" onClick={send}>
              确认发送问题和以上摘要
            </button>
            <button className="btn" onClick={() => setReview(false)}>
              取消
            </button>
          </div>
        ) : (
          <button
            className="btn"
            disabled={!question.trim() || !summary.course_count}
            onClick={() => setReview(true)}
          >
            {answer || error ? "再次核对并重试" : "核对本次摘要"}
          </button>
        )}
      </QueryState>
      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}
      {answer && <div className="ai-output section">{answer}</div>}
    </div>
  );
}
