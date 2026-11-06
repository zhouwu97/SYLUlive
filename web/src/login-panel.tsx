import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { beginAuthTransition, entity, errorText, request, type Entity } from "./api";
import { Icon, useUI } from "./ui";
import { ServerAvatar } from "./server-avatar";
import { accountKey, canRememberPassword, clearSavedAccounts, forgetSavedPasswords, historyRevision, LOGIN_HISTORY_CHANNEL, rememberLogin, removeSavedAccount, savedAccounts, savedPassword, type SavedAccount } from "./login-history";

export function LoginPanel({ initialAccount = "", onAuthenticated, onRegister, onReset }: {
  initialAccount?: string;
  onAuthenticated: (isCurrent: () => boolean) => Promise<void>;
  onRegister: (account: string) => void;
  onReset: (account: string) => void;
}) {
  const ui = useUI(), id = useId();
  const [account, setAccount] = useState(initialAccount), [password, setPassword] = useState("");
  const [rememberAccount, setRememberAccount] = useState(true), [rememberPassword, setRememberPassword] = useState(false);
  const [showPassword, setShowPassword] = useState(false), [historyOpen, setHistoryOpen] = useState(false);
  const [history, setHistory] = useState<SavedAccount[]>([]), [historyState, setHistoryState] = useState<"loading" | "ready" | "failed">("loading");
  const [busy, setBusy] = useState(false), [readingPassword, setReadingPassword] = useState(false), [editingHistory, setEditingHistory] = useState(false);
  const [error, setError] = useState(""), [storageMessage, setStorageMessage] = useState("");
  const accountInput = useRef<HTMLInputElement>(null), historyPanel = useRef<HTMLDivElement>(null);
  const mounted = useRef(true), edited = useRef(false), selection = useRef(0), loadVersion = useRef(0), lock = useRef(false);
  const fromSaved = useRef<{ key: string; lastUsedAt: number } | undefined>(undefined);
  const controller = useRef<AbortController | undefined>(undefined), accepted = useRef(false), focusHistory = useRef(false);
  const passwordSupported = canRememberPassword();

  async function choose(record: SavedAccount) {
    const version = ++selection.current;
    edited.current = true;
    fromSaved.current = { key: record.key, lastUsedAt: record.lastUsedAt };
    setAccount(record.account); setPassword(""); setShowPassword(false); setError(""); setStorageMessage("");
    setHistoryOpen(false); setReadingPassword(record.hasPassword); setRememberPassword(false);
    accountInput.current?.focus();
    if (!record.hasPassword) return;
    try {
      const value = await savedPassword(record.key);
      if (!mounted.current || version !== selection.current) return;
      setPassword(value); setRememberPassword(!!value); setRememberAccount(true);
    } catch (e) {
      if (mounted.current && version === selection.current) setStorageMessage(errorText(e));
    } finally { if (mounted.current && version === selection.current) setReadingPassword(false); }
  }

  async function readHistory(autofill = false) {
    const version = ++loadVersion.current;
    setHistoryState("loading");
    try {
      const records = await savedAccounts();
      if (!mounted.current || version !== loadVersion.current) return;
      setHistory(records); setHistoryState("ready");
      if (!records.length) setHistoryOpen(false);
      const selected = fromSaved.current;
      if (selected && !records.some(record => record.key === selected.key && record.lastUsedAt === selected.lastUsedAt && record.hasPassword)) {
        selection.current++; fromSaved.current = undefined;
        setPassword(""); setReadingPassword(false); setRememberPassword(false);
      }
      if (autofill && !initialAccount && !edited.current && !accountInput.current?.value && records[0]) void choose(records[0]);
    } catch {
      if (mounted.current && version === loadVersion.current) {
        setHistoryState("failed"); setRememberAccount(false); setRememberPassword(false);
        setStorageMessage("本机账号记录暂不可用，你仍可手动登录。");
      }
    }
  }

  useEffect(() => {
    mounted.current = true;
    // 注册／重置与登录共用弹窗；在弹窗记录返回焦点后，再聚焦新表单。
    const focusFrame = requestAnimationFrame(() => accountInput.current?.focus());
    void readHistory(true);
    let channel: BroadcastChannel | undefined;
    try {
      channel = new BroadcastChannel(LOGIN_HISTORY_CHANNEL);
      channel.onmessage = () => { selection.current++; setReadingPassword(false); void readHistory(); };
    } catch {}
    return () => {
      cancelAnimationFrame(focusFrame);
      mounted.current = false; selection.current++; loadVersion.current++;
      // 服务端已确认成功后的本机保存继续完成；显式删除通过存储版本阻止旧写回。
      if (!accepted.current) controller.current?.abort();
      channel?.close();
    };
  }, []);

  useEffect(() => {
    if (historyOpen && focusHistory.current) {
      focusHistory.current = false;
      historyPanel.current?.querySelector<HTMLButtonElement>("[data-account-choice]")?.focus();
    }
  }, [historyOpen]);

  async function editRecords(action: () => Promise<void>, removedKey?: string, clearDraft = true) {
    setEditingHistory(true); setStorageMessage("");
    try {
      await action();
      if (!mounted.current) return;
      if (clearDraft && (!removedKey || accountKey(accountInput.current?.value || "") === removedKey)) {
        selection.current++; fromSaved.current = undefined;
        setAccount(""); setPassword(""); setRememberPassword(false); setReadingPassword(false);
      }
      await readHistory();
    } catch (e) { if (mounted.current) setStorageMessage(errorText(e)); }
    finally { if (mounted.current) setEditingHistory(false); }
  }

  async function forgetPassword() {
    selection.current++; fromSaved.current = undefined;
    setRememberPassword(false); setReadingPassword(false);
    try { await forgetSavedPasswords({ account: accountInput.current?.value || account }); if (mounted.current) await readHistory(); }
    catch { if (mounted.current) setStorageMessage("保存的密码未能清除，请在历史账号中重试移除。"); }
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (lock.current || readingPassword || editingHistory) return;
    const form = new FormData(event.currentTarget);
    const submittedAccount = String(form.get("account") || "").trim(), submittedPassword = String(form.get("password") || "");
    if (!submittedAccount || !submittedPassword) { setError("请输入账号和密码"); return; }
    lock.current = true; accepted.current = false;
    const current = new AbortController(); controller.current = current;
    const isCurrent = () => mounted.current && controller.current === current && !current.signal.aborted;
    const loginStartedAt = Date.now();
    setBusy(true); setError(""); setHistoryOpen(false);
    let revision: number | undefined;
    try {
      if (rememberAccount && historyState === "ready") {
        try { revision = await historyRevision(current.signal); } catch { /* 本机保存失败不能阻断登录。 */ }
      }
      if (!isCurrent()) return;
      beginAuthTransition();
      const response = await request<Entity>("/api/login", { method: "POST", body: JSON.stringify({ account: submittedAccount, password: submittedPassword }), signal: current.signal });
      if (!isCurrent()) return;
      accepted.current = true;
      const user = entity(response, "user", "data");
      // 会话立即刷新，不等待加密或本机磁盘；仅保存成功登录时已明确选择的字段。
      const save = rememberAccount ? revision !== undefined
        ? rememberLogin({ account: submittedAccount, password: submittedPassword, nickname: typeof user.nickname === "string" ? user.nickname : "", userId: typeof user.id === "number" ? user.id : undefined, email: typeof user.email === "string" ? user.email : submittedAccount.includes("@") ? submittedAccount : undefined, rememberPassword, revision, loginStartedAt })
        : Promise.reject(new Error("本机记录不可用")) : Promise.resolve();
      const saving = save.then(() => false, () => true);
      await onAuthenticated(isCurrent);
      if (await saving) ui.notify("本机账号记录未能保存，可在下次登录时重试");
    } catch (e) {
      if (isCurrent()) setError(errorText(e));
    } finally {
      lock.current = false;
      if (isCurrent()) setBusy(false);
    }
  }

  return <section className="auth-panel">
    <header className="auth-intro"><span className="auth-brand"><ServerAvatar src="/web/assets/app-icon.png" name="沈理校园" /></span><div><h2>欢迎回来</h2><p>登录后，继续你的校园日常。</p></div></header>
    <form className="auth-form" name="sylulive-login" autoComplete="on" onSubmit={submit} onKeyDown={event => {
      if (event.key === "Escape" && historyOpen) { event.stopPropagation(); event.preventDefault(); setHistoryOpen(false); accountInput.current?.focus(); }
    }}>
      <fieldset disabled={busy}>
        <div className="auth-field" onBlur={event => { if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget)) setHistoryOpen(false); }}>
          <label htmlFor={`${id}-account`}>邮箱或账号</label>
          <div className="auth-input"><Icon name="profile" size={18} /><input ref={accountInput} id={`${id}-account`} data-autofocus name="account" autoComplete="username" autoCapitalize="none" spellCheck={false} placeholder="请输入邮箱或账号" required maxLength={320} aria-invalid={!!error} aria-describedby={error ? `${id}-error` : undefined} value={account} onChange={event => {
            edited.current = true; selection.current++; setReadingPassword(false);
            if (fromSaved.current) { fromSaved.current = undefined; setPassword(""); setRememberPassword(false); }
            setAccount(event.target.value); setShowPassword(false); setError("");
          }} onKeyDown={event => { if (event.key === "ArrowDown" && history.length) { event.preventDefault(); focusHistory.current = true; setHistoryOpen(true); } }} />
            {history.length > 0 && <button className="auth-input-action" type="button" aria-label="选择历史账号" aria-expanded={historyOpen} aria-controls={`${id}-history`} onClick={() => setHistoryOpen(value => !value)}><Icon name="chevron" size={17} /></button>}
          </div>
          {historyOpen && <div id={`${id}-history`} className="auth-history" ref={historyPanel} role="group" aria-label="历史账号" onKeyDown={event => {
            const choices = Array.from(historyPanel.current?.querySelectorAll<HTMLButtonElement>("[data-account-choice]:not(:disabled)") || []);
            const index = choices.indexOf(event.target as HTMLButtonElement);
            if (index < 0 || !["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
            event.preventDefault();
            const next = event.key === "Home" ? 0 : event.key === "End" ? choices.length - 1 : (index + (event.key === "ArrowDown" ? 1 : -1) + choices.length) % choices.length;
            choices[next]?.focus();
          }}>
            <div className="auth-history-heading"><span>此浏览器的账号<small>{history.length}</small></span><button type="button" className="link-btn" disabled={editingHistory} onClick={() => editRecords(clearSavedAccounts)}>清空记录</button></div>
            <div className="auth-history-list">{history.map(record => <div className="auth-history-row" key={record.key}>
              <button type="button" data-account-choice className="auth-history-choice" aria-label={`使用账号 ${record.account}`} aria-current={accountKey(account) === record.key ? "true" : undefined} title={record.account} disabled={editingHistory} onClick={() => choose(record)}><span className="auth-history-avatar" aria-hidden="true">{Array.from(record.nickname || record.account)[0]}</span><span className="auth-history-identity"><b>{record.nickname || record.account}</b><small>{record.nickname ? record.account : "上次使用的账号"}{record.hasPassword && <span> · 已记住密码</span>}</small></span>{accountKey(account) === record.key && <span className="auth-history-current"><Icon name="check" size={14} />当前</span>}</button>
              <button type="button" className="auth-history-remove" aria-label={`移除账号记录 ${record.account}`} title="移除此浏览器的账号记录" disabled={editingHistory} onClick={() => editRecords(() => removeSavedAccount(record.key), record.key)}><Icon name="close" size={15} /></button>
            </div>)}</div>
          </div>}
        </div>
        <div className="auth-field">
          <label htmlFor={`${id}-password`}>密码</label>
          <div className="auth-input"><Icon name="lock" size={18} /><input id={`${id}-password`} name="password" type={showPassword ? "text" : "password"} autoComplete="current-password" required maxLength={1024} aria-invalid={!!error} aria-describedby={error ? `${id}-error` : undefined} placeholder={readingPassword ? "正在读取保存的密码…" : "请输入密码"} value={password} onChange={event => { selection.current++; fromSaved.current = undefined; setReadingPassword(false); setPassword(event.target.value); setError(""); }} />
            <button className="auth-input-action" type="button" aria-label={showPassword ? "隐藏密码" : "显示密码"} aria-pressed={showPassword} onClick={() => setShowPassword(value => !value)}><Icon name={showPassword ? "eye-off" : "eye"} size={18} /></button>
          </div>
        </div>
        {error && <p id={`${id}-error`} className="auth-error" role="alert"><Icon name="info" size={16} /><span>{error}</span></p>}
        <div className="auth-options"><div>
          <label><input type="checkbox" checked={rememberAccount} disabled={historyState !== "ready" || editingHistory} onChange={event => {
            const checked = event.target.checked; setRememberAccount(checked);
            if (!checked) { fromSaved.current = undefined; setRememberPassword(false); selection.current++; setReadingPassword(false); if (history.some(item => item.key === accountKey(account))) void editRecords(() => removeSavedAccount(accountKey(account)), accountKey(account), false); }
          }} />记住账号</label>
          <label><input type="checkbox" checked={rememberPassword} disabled={!rememberAccount || !passwordSupported || editingHistory} onChange={event => event.target.checked ? setRememberPassword(true) : void forgetPassword()} />记住密码</label>
        </div><button type="button" className="link-btn" onClick={() => onReset(account)}>忘记密码</button></div>
        <p className="auth-storage-note"><Icon name="lock" size={14} /><span>{historyState === "failed" ? "本次仅登录，不保存账号和密码。" : !passwordSupported ? "当前浏览器可记住账号，密码请手动填写。" : rememberPassword ? "密码加密保存在此浏览器，公用设备请勿勾选。" : "保存仅对当前浏览器有效，可随时移除记录。"}</span></p>
        <button className="btn primary auth-submit" type="submit" disabled={busy || readingPassword || editingHistory}><span>{busy ? "正在登录…" : readingPassword ? "正在读取密码…" : "登录"}</span>{!busy && !readingPassword && <Icon name="arrow" size={17} />}</button>
      </fieldset>
    </form>
    {storageMessage && <div className="auth-storage-status" role="status"><span>{storageMessage}</span>{historyState === "failed" && <button className="link-btn" type="button" disabled={busy} onClick={() => readHistory()}>重试读取</button>}</div>}
    <footer className="auth-footer"><span>还没有账号？</span><button className="link-btn" type="button" disabled={busy} onClick={() => onRegister(account)}>注册账号</button></footer>
  </section>;
}
