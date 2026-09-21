import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
  type FormEvent,
} from "react";
import { useQueryClient } from "@tanstack/react-query";
import { paths } from "./icons";
import { ApiError, write, errorText, type Entity } from "./api";
export function Icon({ name, size = 20 }: { name: string; size?: number }) {
  return (
    <svg
      className="svg-icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      aria-hidden="true"
      dangerouslySetInnerHTML={{ __html: paths[name] || paths.dashboard }}
    />
  );
}
type Dialog = { title: string; body: ReactNode };
const UIContext = createContext<{
  dialog: Dialog | null;
  open: (title: string, body: ReactNode) => void;
  close: () => void;
  notify: (s: string) => void;
  act: (fn: () => Promise<unknown>, success?: string) => Promise<boolean>;
}>({} as never);
export const useUI = () => useContext(UIContext);
export function UIProvider({ children }: { children: ReactNode }) {
  const [dialog, setDialog] = useState<Dialog | null>(null),
    [toast, setToast] = useState("");
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const qc = useQueryClient();
  function notify(s: string) {
    setToast(s);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setToast(""), 4200);
  }
  const close = () => setDialog(null);
  async function act(fn: () => Promise<unknown>, success = "操作已完成") {
    try {
      await fn();
      await qc.invalidateQueries({ queryKey: ["api"] });
      notify(success);
      return true;
    } catch (e) {
      notify(errorText(e));
      return false;
    }
  }
  return (
    <UIContext.Provider
      value={{
        dialog,
        open: (title, body) => setDialog({ title, body }),
        close,
        notify,
        act,
      }}
    >
      {children}
      <div
        role="status"
        aria-live="polite"
        className={`toast ${toast ? "show" : ""}`}
      >
        {toast}
      </div>
    </UIContext.Provider>
  );
}
export function Modal({
  title,
  close,
  children,
}: {
  title: string;
  close: () => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement;
    const old = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    ref.current
      ?.querySelector<HTMLElement>("input,button,textarea,select")
      ?.focus();
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      }
      if (e.key === "Tab") {
        const all = ref.current?.querySelectorAll<HTMLElement>(
          'button:not(:disabled),a[href],input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]',
        );
        if (!all?.length) return;
        const first = all[0],
          last = all[all.length - 1];
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("keydown", key);
      document.body.style.overflow = old;
      previous?.focus();
    };
  }, []);
  return (
    <div
      className="overlay open"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) close();
      }}
    >
      <div
        ref={ref}
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <div className="modal-head">
          <b>{title}</b>
          <button className="icon-btn" aria-label="关闭" onClick={close}>
            ×
          </button>
        </div>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}
export interface Field {
  name: string;
  label: string;
  type?: string;
  required?: boolean;
  value?: string | number;
  defaultValue?: string | number;
  options?: [string, string][];
  min?: number;
  max?: number;
  help?: string;
  multiple?: boolean;
}
export function Form({
  fields,
  onSubmit,
  submit = "保存",
  children,
}: {
  fields: Field[];
  onSubmit: (data: Entity, form: FormData) => Promise<void>;
  submit?: string;
  children?: ReactNode;
}) {
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [rulesRequired, setRulesRequired] = useState(false);
  async function send(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (busy) return;
    const fd = new FormData(e.currentTarget);
    setBusy(true);
    setError("");
    try {
      await onSubmit(Object.fromEntries(fd), fd);
    } catch (err) {
      setError(errorText(err));
      if (err instanceof ApiError && err.code === 'community_rules_required') setRulesRequired(true);
    } finally {
      setBusy(false);
    }
  }
  return (
    <form className="dialog-form" onSubmit={send}>
      {fields.map((f) => (
        <label className="field" key={f.name}>
          {f.label}
          {f.options ? (
            <select
              name={f.name}
              defaultValue={f.value ?? f.defaultValue}
              required={f.required}
            >
              {f.options.map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </select>
          ) : f.type === "textarea" ? (
            <textarea
              rows={4}
              name={f.name}
              required={f.required}
              defaultValue={f.value ?? f.defaultValue}
            />
          ) : (
            <input
              name={f.name}
              type={f.type || "text"}
              required={f.required}
              defaultValue={
                f.type === "file" ? undefined : (f.value ?? f.defaultValue)
              }
              min={f.min}
              max={f.max}
              multiple={f.multiple}
              autoComplete={
                f.type === "password" ? "current-password" : undefined
              }
            />
          )}{" "}
          {f.help && <small className="muted">{f.help}</small>}
        </label>
      ))}
      {children}
      {rulesRequired && <div className="panel panel-pad"><b>社区规则 · 2026-07-18</b><p>不得发布违法违规、侵犯隐私、侮辱诽谤、诈骗、色情低俗、暴力恐怖、违禁交易或侵犯知识产权的内容。发布他人信息、照片、联系方式或试卷资料前，应取得合法授权。</p><p>二手交易仅用于信息交流。请自行核验交易对象与商品，不要在平台外泄露密码、验证码或支付凭证。平台可依据举报和审核规则处理违规内容，并向内容发布者说明处置理由和申诉渠道。</p><button className="btn" type="button" disabled={busy} onClick={async()=>{setBusy(true);try{await write('/api/user/community-rules',{accepted:true});setRulesRequired(false);setError('规则已确认，请重新提交当前内容');}catch(error){setError(errorText(error))}finally{setBusy(false)}}}>我已阅读并同意社区规则</button></div>}
      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}
      <div className="form-actions">
        <button className="btn primary" disabled={busy}>
          {busy ? "正在提交…" : submit}
        </button>
      </div>
    </form>
  );
}
export function Head({
  title,
  description,
  subtitle,
  action,
  children,
}: {
  title: string;
  description?: string;
  subtitle?: string;
  action?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className="page-head">
      <div className="page-title">
        <h1>{title}</h1>
        {(description || subtitle) && <p>{description || subtitle}</p>}
      </div>
      <div className="head-actions">
        {action}
        {children}
      </div>
    </div>
  );
}
export function Empty({
  title = "暂无内容",
  description,
  text,
  children,
}: {
  title?: string;
  description?: string;
  text?: string;
  children?: ReactNode;
}) {
  return (
    <div className="empty-state">
      <Icon name="search" />
      <h3>{text || title}</h3>
      {description && <p>{description}</p>}
      {children}
    </div>
  );
}
export function QueryState({
  query,
  children,
  empty = false,
}: {
  query: { isPending: boolean; error: Error | null; refetch: () => unknown };
  children: ReactNode;
  empty?: boolean;
}) {
  if (query.isPending)
    return (
      <div className="loading-state" role="status">
        正在加载…
      </div>
    );
  if (query.error)
    return (
      <Empty title="加载未完成" description={query.error.message}>
        <button className="btn" onClick={() => query.refetch()}>
          重试
        </button>
      </Empty>
    );
  if (empty) return <Empty />;
  return <>{children}</>;
}
export function Tabs({
  tabs,
  items,
  value,
  onChange,
}: {
  tabs?: [string, string][];
  items?: string[];
  value: string;
  onChange: (s: string) => void;
}) {
  const list = tabs || items?.map((x) => [x, x] as [string, string]) || [];
  return (
    <div className="tabs" role="tablist">
      {list.map(([v, l]) => (
        <button
          key={v}
          className={`tab ${v === value ? "active" : ""}`}
          role="tab"
          aria-selected={v === value}
          onClick={() => onChange(v)}
        >
          {l}
        </button>
      ))}
    </div>
  );
}
export function Stats({ items }: { items: [string | number, string][] }) {
  return (
    <div className="split-stats">
      {items.map(([n, l]) => (
        <div className="stat" key={l}>
          <b>{n}</b>
          <span>{l}</span>
        </div>
      ))}
    </div>
  );
}
export function Pagination({
  page,
  onChange,
  hasMore,
  total,
}: {
  page: number;
  onChange?: (n: number) => void;
  hasMore?: boolean;
  total?: number;
}) {
  const next = hasMore ?? (total || 0) >= 20;
  return (
    <div className="pagination">
      <button
        className="btn"
        disabled={page <= 1}
        onClick={() => onChange?.(page - 1)}
      >
        上一页
      </button>
      <span>第 {page} 页</span>
      <button
        className="btn"
        disabled={!next}
        onClick={() => onChange?.(page + 1)}
      >
        下一页
      </button>
    </div>
  );
}

export function DialogOutlet() {
  const { dialog, close } = useUI();
  return dialog ? (
    <Modal title={dialog.title} close={close}>
      {dialog.body}
    </Modal>
  ) : null;
}
