import { useEffect, useMemo, useState } from "react";
import { useLocation } from "react-router-dom";
import qrcode from "qrcode-generator";
import { ApiError, errorText, isNetworkError, request } from "./api";
import { useAuth } from "./auth";
import { Icon } from "./ui";
import {
  TransferError,
  createTransferKeys,
  decryptTransfer,
  parseTransferPayload,
  transferQrText,
  transferSummary,
  type TransferEnvelope,
  type TransferPayload,
} from "./academic-transfer";

/** 二维码固定用黑白两色并自带留白：深色主题下反色的码很多手机扫不出来。 */
export function QrCode({ text, label }: { text: string; label: string }) {
  const { size, path } = useMemo(() => {
    const code = qrcode(0, "M");
    code.addData(text);
    code.make();
    const count = code.getModuleCount();
    let d = "";
    for (let row = 0; row < count; row += 1)
      for (let column = 0; column < count; column += 1)
        if (code.isDark(row, column)) d += `M${column + 4} ${row + 4}h1v1h-1z`;
    return { size: count + 8, path: d };
  }, [text]);
  return (
    <svg className="qr-code" viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label} shapeRendering="crispEdges">
      <rect width={size} height={size} fill="#fff" />
      <path d={path} fill="#000" />
    </svg>
  );
}

type Phase = "preparing" | "waiting" | "claimed" | "receiving" | "done" | "empty" | "expired" | "error";
type SessionView = { session_id: string; status: string; ttl_seconds: number; payload?: TransferEnvelope };

const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
  });

const phaseText: Record<Phase, string> = {
  preparing: "正在生成二维码…",
  waiting: "等待手机扫码",
  claimed: "手机已扫码，请在 App 上核对并确认",
  receiving: "正在接收并解密资料…",
  done: "同步完成",
  empty: "手机上还没有可同步的资料",
  expired: "二维码已失效",
  error: "同步没有完成",
};

/**
 * 手机 App 扫码同步弹窗。只负责出码、等待和解密；
 * 资料如何写入页面由调用方的 onPayload 决定，返回值是需要一并告知用户的补充说明。
 */
export function PhoneScanForm({ onPayload, onClose }: { onPayload: (payload: TransferPayload) => string[]; onClose: () => void }) {
  const { user, requireUser } = useAuth();
  const [attempt, setAttempt] = useState(0);
  const [phase, setPhase] = useState<Phase>("preparing");
  const [qr, setQr] = useState("");
  const [deadline, setDeadline] = useState(0);
  const [remaining, setRemaining] = useState(0);
  const [detail, setDetail] = useState("");
  const [result, setResult] = useState<string[]>([]);
  const userId = user?.id;

  useEffect(() => {
    if (!userId) return;
    const controller = new AbortController(), { signal } = controller;
    let sessionId = "", settled = false;
    const path = () => `/api/academic-transfer/sessions/${encodeURIComponent(sessionId)}`;
    const headers = { "X-Expected-App-User": String(userId) };
    setPhase("preparing"); setQr(""); setDetail(""); setResult([]);
    (async () => {
      const keys = await createTransferKeys();
      const created = await request<SessionView>("/api/academic-transfer/sessions", { method: "POST", body: "{}", headers, signal });
      if (signal.aborted) return;
      sessionId = created.session_id;
      setQr(transferQrText(location.origin, sessionId, keys.publicKey));
      setDeadline(Date.now() + created.ttl_seconds * 1000);
      setPhase("waiting");
      while (!signal.aborted) {
        await sleep(1500, signal);
        if (signal.aborted) return;
        let view: SessionView;
        try {
          view = await request<SessionView>(path(), { headers, signal });
        } catch (error) {
          if (signal.aborted) return;
          // 断网只是暂时看不到进度，手机那边可能已经上传；继续轮询而不是丢掉这张码。
          if (isNetworkError(error) || (error instanceof ApiError && error.status >= 500)) { setDetail("网络不稳定，正在重试…"); continue; }
          settled = true;
          if (error instanceof ApiError && error.status === 404) { setPhase("expired"); setDetail("二维码已过期，或手机端取消了本次同步。"); return; }
          throw error;
        }
        setDetail("");
        if (view.status === "claimed") setPhase("claimed");
        if (view.status !== "ready" || !view.payload) continue;
        setPhase("receiving");
        const payload = parseTransferPayload(await decryptTransfer(keys.privateKey, sessionId, view.payload));
        if (signal.aborted) return;
        settled = true;
        // 解密成功后立刻让服务器丢掉密文，不等它自然过期。
        void request(path(), { method: "DELETE", headers }).catch(() => undefined);
        const summary = transferSummary(payload);
        if (!summary.length) { setPhase("empty"); setDetail("请先在 App 里读取课表、成绩等资料，再回到这里重新扫码。"); return; }
        setResult([`已同步：${summary.join("、")}`, ...onPayload(payload)]);
        setPhase("done");
        return;
      }
    })().catch((error) => {
      if (signal.aborted) return;
      setPhase("error");
      setDetail(error instanceof TransferError ? error.message : errorText(error));
    });
    return () => {
      controller.abort();
      // 关闭弹窗或重新出码时作废旧会话：手机即使已经扫到旧码，也不会再把资料传上来。
      if (sessionId && !settled) void request(path(), { method: "DELETE", headers }).catch(() => undefined);
    };
    // onPayload 只在收到资料的那一刻调用，不应因父组件重渲染而重新出码。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [attempt, userId]);

  const live = phase === "waiting" || phase === "claimed";
  useEffect(() => {
    if (!live) return;
    const tick = () => {
      const left = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
      setRemaining(left);
      if (!left) { setPhase("expired"); setDetail("二维码有效期为 5 分钟，请重新生成。"); }
    };
    tick();
    const timer = setInterval(tick, 1000);
    return () => clearInterval(timer);
  }, [live, deadline]);

  if (!user)
    return (
      <div className="dialog-form phone-scan">
        <p>登录沈理校园后才能生成同步二维码，手机 App 需要登录同一个账号。</p>
        <button className="btn primary" onClick={() => requireUser()}>登录</button>
      </div>
    );
  const masked = phase !== "waiting";
  const retry = phase === "expired" || phase === "error" || phase === "empty";
  return (
    <div className="dialog-form phone-scan">
      <div className="phone-scan-body">
        <div className="phone-scan-code" data-phase={phase}>
          {qr ? <QrCode text={qr} label="手机 App 扫码同步二维码" /> : <div className="qr-code qr-placeholder" aria-hidden="true" />}
          {masked && (
            <div className="phone-scan-mask">
              {phase === "done" ? <Icon name="check" size={30} /> : phase === "claimed" ? <Icon name="phone" size={30} /> : retry ? <Icon name="clock" size={30} /> : <span className="phone-scan-spinner" aria-hidden="true" />}
              <b>{phaseText[phase]}</b>
              {retry && <button className="btn primary" onClick={() => setAttempt((value) => value + 1)}>重新生成二维码</button>}
            </div>
          )}
        </div>
        <div className="phone-scan-guide">
          <ol className="phone-scan-steps">
            <li><b>1</b><span>打开手机上的<strong>沈理校园 App</strong>，登录与本页相同的账号</span></li>
            <li><b>2</b><span>进入<strong>课表</strong>，点右上角设置，选择<strong>扫码同步到网页</strong></span></li>
            <li><b>3</b><span>扫描这张二维码，在手机上核对要同步的资料后确认</span></li>
          </ol>
          <p className="phone-scan-status" role="status" data-phase={phase}>
            {phaseText[phase]}
            {live && remaining > 0 && <small> · {Math.floor(remaining / 60)}:{String(remaining % 60).padStart(2, "0")} 后失效</small>}
          </p>
          {detail && <p className="notice-line">{detail}</p>}
          {result.map((line) => <p className="phone-scan-result" key={line}>{line}</p>)}
        </div>
      </div>
      <p className="muted phone-scan-privacy">
        <Icon name="lock" size={14} />
        可同步手机上正在使用的课表、其他学期和存档课表，以及成绩、考试、二课、体测。资料在手机上加密后传到本页解密，服务器只做短暂中转、不保存内容；学校账号和密码不会传输。
      </p>
      <div className="inline-actions">
        {phase === "done"
          ? <button className="btn primary" onClick={onClose}>完成</button>
          : <button className="btn ghost" onClick={onClose}>取消</button>}
        {live && <button className="btn ghost" onClick={() => setAttempt((value) => value + 1)}>换一张二维码</button>}
      </div>
    </div>
  );
}

/**
 * 用系统相机、微信等其他工具扫到同步二维码时落到这里：
 * 说明应当用 App 扫，并提供直接唤起 App 的入口。参数在 # 之后，本页不会把它们发给服务器。
 */
export function AppScanLanding() {
  const { hash } = useLocation();
  const params = new URLSearchParams(hash.slice(1));
  const session = params.get("s") || "", key = params.get("k") || "";
  const valid = params.get("v") === "1" && /^[A-Za-z0-9_-]{16,64}$/.test(session) && /^[A-Za-z0-9_-]{80,96}$/.test(key);
  return (
    <div className="panel panel-pad app-scan-landing">
      <i><Icon name="scan" size={34} /></i>
      <h1>请用沈理校园 App 扫码</h1>
      <p>这是网页版课表的同步二维码，需要由沈理校园 App 扫描：打开 App → 课表 → 右上角设置 → 扫码同步到网页，再扫一次电脑上的二维码。</p>
      {valid
        ? <a className="btn primary" href={`sylulive://academic-transfer?v=1&s=${session}&k=${key}`}>在沈理校园 App 中打开</a>
        : <p className="notice-line">这个链接不完整或已经失效，请回到电脑网页重新生成二维码。</p>}
      <p className="muted">二维码 5 分钟内有效，且只能由与网页登录同一账号的 App 使用。</p>
    </div>
  );
}
