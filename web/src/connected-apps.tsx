import { useEffect, useRef, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useAuth } from "./auth";
import { ApiError, captureAuthSession, useApi, write } from "./api";
import { Empty, Head, QueryState } from "./ui";
import "./connected-apps.css";
import { integrationScopeLabels as labels } from "./integration-scopes";
import { IntegrationPersonalSync } from "./integration-personal-sync";
import { PasswordReauthentication } from "./reauthenticate";

type Binding = {
  binding_id: string;
  installation_name: string;
  installation_id: string;
  state: string;
  scopes: string;
  epoch: number;
};
type Consent = {
  consent_id: string;
  installation_name: string;
  installation_id: string;
  user_code: string;
  requested_scopes: string[];
  confirmation_nonce: string;
  expires_at: string;
  existing_binding?: Binding;
};
type Action = {
  action_id: string;
  kind: string;
  state: string;
  draft_version: number;
  payload_hash: string;
  post_id?: number;
  reply_id?: number;
  expires_at: string;
  payload: {
    title?: string;
    content?: string;
    post_id?: number;
    post_type?: string;
    reply_to_reply_id?: number;
    sticker_id?: string;
  };
};
type Preview = {
  action: Action;
  confirmation_nonce?: string;
  confirmation_expires_at?: string;
};
const errors: Record<string, string> = {
  recent_authentication_required:
    "继续前请验证当前账号的密码。验证成功后可继续本次操作，无需重新登录。",
  academic_verification_required:
    "当前账号尚无符合要求的教务核验。请在账号设置完成受支持的身份核验；本地自报资料不能用于此授权。",
  source_changed: "原帖或回复内容已变化，请让助手重新读取并生成草稿。",
  source_unavailable: "原帖或回复已不可用，此草稿不能发布。",
  draft_expired: "草稿已过期，请让助手重新生成。",
  confirmation_expired:
    "确认窗口已过期或已在另一页面打开，请重新加载草稿后确认。",
  binding_conflict: "已有一个有效助手授权，请明确勾选替换旧授权。",
  installation_conflict: "这份机器人连接已被另一个校园账号授权。请先在原账号撤销连接，不能直接挪用他人的绑定。",
  proposals_disabled: "服务端尚未开放草稿提案，请仅选择读取权限。",
  personal_queries_disabled: "服务端尚未开放成绩和二课查询，当前可只授权其他已开放能力。",
  owner_publish_disabled: "服务端尚未开放正式发布，此草稿尚未发布。",
  section_muted: "当前账号已被该版块禁言。",
  community_rules_required: "请先在校园社区阅读并接受现行社区规则。",
  invalid_token: "授权已失效，请在 AstrBot 重新连接。",
};
function explain(error: unknown) {
  return error instanceof ApiError
    ? errors[error.code] || `操作未完成（${error.code}），请重试或联系维护者。`
    : "网络请求未完成，请重试；发布结果可通过重新加载查询。";
}
function useGuard() {
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  return () => {
    const current = captureAuthSession();
    return () => mounted.current && current();
  };
}
function SignIn() {
  const auth = useAuth();
  return (
    <Empty title={auth.loading ? "正在确认登录状态" : "请先登录 SYLUlive"}>
      <button
        className="btn primary"
        disabled={auth.loading}
        onClick={auth.login}
      >
        登录
      </button>
    </Empty>
  );
}
function Problem({ message, onVerified }: { message: string; onVerified?: () => Promise<unknown> }) {
  return message ? (
    <div role="alert">
      <p>{message}</p>
      {message === errors.recent_authentication_required && onVerified && <PasswordReauthentication onVerified={onVerified} />}
    </div>
  ) : null;
}

export function ConnectedApps() {
  const auth = useAuth();
  return auth.user ? (
    <ConnectionPanel key={auth.user.id} nickname={auth.user.nickname} />
  ) : (
    <SignIn />
  );
}
function ConnectionPanel({ nickname }: { nickname: string }) {
  const [params] = useSearchParams(),
    [code, setCode] = useState(params.get("user_code") || ""),
    [consent, setConsent] = useState<Consent | null>(null),
    [selected, setSelected] = useState<string[]>([]),
    [checked, setChecked] = useState(false),
    [replace, setReplace] = useState(false),
    [busy, setBusy] = useState(false),
    [message, setMessage] = useState(""),
    [success, setSuccess] = useState("");
  const q = useApi<{ bindings: Binding[]; personal_data_enabled?: boolean }>("/api/connected-apps"),
    guard = useGuard();
  const personalEnabled = q.error || q.isFetching ? undefined : q.data?.personal_data_enabled;
  const lookupHint = busy ? "正在处理当前请求，请等待结果后再操作。"
    : !code.trim() ? "请先在 AstrBot 私聊发送 /sylu-connect，取得设备代码后填写到这里，再查看授权请求。"
      : "设备代码已填写，可以查看请求；请先核对它来自你自己的 AstrBot 私聊。";
  const consentHint = busy ? "正在处理当前授权，请等待结果，暂不能重复提交。"
    : !selected.length ? "请至少选择一项你愿意授予的权限。"
      : personalEnabled !== true && selected.some(scope => ["academic:grades:read", "academic:erke:read"].includes(scope))
        ? "个人查询尚未开放或状态未确认，请取消成绩、二课权限，或重新检查服务状态后再授权。"
        : !checked ? "请先核对设备代码与账号，再勾选「我已核对设备代码与当前账号」。"
          : consent?.existing_binding && !replace ? "当前账号已有助手连接。确认要换成这个助手时，请勾选撤销并替换已有授权。"
            : selected.includes("community:propose") && (!selected.includes("community:read") || !selected.includes("actions:read_own"))
              ? "创建草稿还需要公开内容读取与本人动作记录权限，请补选这两项，或取消创建草稿。"
              : "核对已完成，可以授权此助手。";
  async function lookup() {
    const current = guard();
    setBusy(true);
    setMessage("");
    setSuccess("");
    setConsent(null);
    setChecked(false);
    setReplace(false);
    try {
      const result = await write<Consent>(
        "/api/connected-apps/device-requests/lookup",
        { user_code: code.trim() },
      );
      if (current()) {
        setConsent(result);
        setSelected(
          result.requested_scopes.filter(
            (s) => !["community:propose", "checkin:write", "academic:grades:read", "academic:erke:read"].includes(s),
          ),
        );
      }
    } catch (e) {
      if (current()) setMessage(explain(e));
    } finally {
      if (current()) setBusy(false);
    }
  }
  async function decide(allow: boolean) {
    if (!consent) return;
    const current = guard();
    setBusy(true);
    setMessage("");
    try {
      await write(
        `/api/connected-apps/device-requests/${encodeURIComponent(consent.consent_id)}/decision`,
        {
          allow,
          scopes: allow ? selected : [],
          confirmation_nonce: consent.confirmation_nonce,
          replace_binding_id: replace
            ? consent.existing_binding?.binding_id
            : "",
          expected_epoch: replace ? consent.existing_binding?.epoch : 0,
        },
      );
      if (current()) {
        setConsent(null);
        setSuccess(
          allow
            ? "已授权。返回 AstrBot，等待插件完成连接。"
            : "已拒绝本次授权。",
        );
        await q.refetch();
      }
    } catch (e) {
      if (current()) setMessage(explain(e));
    } finally {
      if (current()) setBusy(false);
    }
  }
  async function revoke(id: string) {
    const current = guard();
    setBusy(true);
    setMessage("");
    try {
      await write(`/api/connected-apps/${encodeURIComponent(id)}/revoke`);
      if (current()) {
        setSuccess("已撤销该助手授权，旧凭证及待发布草稿不能继续使用。");
        await q.refetch();
      }
    } catch (e) {
      if (current()) setMessage(explain(e));
    } finally {
      if (current()) setBusy(false);
    }
  }
  return (
    <div className="connected-apps-page">
      <Head
        title="已授权助手"
        subtitle="向 AstrBot 授权本人数据；每个校园账号只保留一个有效助手授权。"
      />
      <section className="panel panel-pad integration-panel">
        <h2>核对连接请求</h2>
        <p>
          当前账号：{nickname}。只为自己刚刚在 AstrBot
          发起的请求授权。不要替他人输入设备代码。
        </p>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void lookup();
          }}
        >
          <label className="field">
            设备代码
            <input
              value={code}
              maxLength={16}
              onChange={(e) => {
                setCode(e.target.value);
                setConsent(null);
              }}
              autoComplete="off"
              aria-describedby="integration-code-hint"
              required
            />
          </label>
          <p id="integration-code-hint" className="control-hint" role="status">{lookupHint}</p>
          <button className="btn" disabled={busy || !code.trim()} aria-describedby="integration-code-hint">
            查看授权请求
          </button>
        </form>
        <Problem message={message} onVerified={async () => {
          setMessage("");
          if (code.trim()) await lookup();
          else await q.refetch();
        }} />
        {success && <p role="status">{success}</p>}
        {consent && (
          <div>
            <h3>授权给 {consent.installation_name}</h3>
            <p>安装标识：{consent.installation_id}（名称和标识由插件提供）</p>
            <p>
              请与 AstrBot 中显示的代码 <strong>{consent.user_code}</strong>{" "}
              核对。请求有效至 {new Date(consent.expires_at).toLocaleString()}。
            </p>
            {consent.requested_scopes.map((scope) => (
              <label className="field" key={scope}>
                <span>
                  <input
                    type="checkbox"
                    checked={selected.includes(scope)}
                    disabled={busy || (["academic:grades:read", "academic:erke:read"].includes(scope) && !selected.includes(scope) && personalEnabled !== true)}
                    onChange={(e) =>
                      setSelected((v) =>
                        e.target.checked
                          ? [...v, scope]
                          : v.filter((s) => s !== scope),
                      )
                    }
                  />
                  {labels[scope] || scope}
                </span>
              </label>
            ))}
            {personalEnabled !== true && consent.requested_scopes.some(scope => ["academic:grades:read", "academic:erke:read"].includes(scope)) && <p>个人查询尚未开放或状态未确认，暂不能批准成绩、二课权限；可取消选择，只授权其他已开放能力。</p>}
            <p>
              获准读取的公开文字、作者昵称、互动统计和图片会交给你部署的
              AstrBot，可能继续发送至你选择的模型、记忆插件或部署者允许的群。SYLUlive
              无法收回已经外发的数据。本连接不提供站内私信、课表、学校密码或学校登录会话。
            </p>
            <p>成绩和二课为独立可选权限，默认不勾选。授权后仅通过本人私聊命令返回已同步数据，标明同步时间；不是学校实时查询，不会直接交给群模型。绑定不会自动完成学校登录或数据同步。</p>
            <p>如果连接共享机器人，QQ、机器人部署者及其安装的其他插件可能保存私聊和返回结果；请确认你信任部署者。SYLUlive 后台管理员不会仅凭管理身份获得他人成绩读取接口。</p>
            <label className="field">
              <span>
                <input
                  type="checkbox"
                  checked={checked}
                  onChange={(e) => setChecked(e.target.checked)}
                />
                我已核对设备代码与当前账号，并了解外发范围
              </span>
            </label>
            {consent.existing_binding && (
              <label className="field">
                <span>
                  <input
                    type="checkbox"
                    checked={replace}
                    onChange={(e) => setReplace(e.target.checked)}
                  />
                  撤销并替换已有授权「
                  {consent.existing_binding.installation_name}」
                </span>
              </label>
            )}
            <div className="form-actions">
              <button
                className="btn"
                disabled={busy}
                onClick={() => void decide(false)}
              >
                拒绝
              </button>
              <button
                className="btn primary"
                disabled={
                  busy ||
                  !checked ||
                  !selected.length ||
                  (personalEnabled !== true && selected.some(scope => ["academic:grades:read", "academic:erke:read"].includes(scope))) ||
                  (!!consent.existing_binding && !replace) ||
                  (selected.includes("community:propose") &&
                    (!selected.includes("community:read") ||
                      !selected.includes("actions:read_own")))
                }
                aria-describedby="integration-consent-hint"
                onClick={() => void decide(true)}
              >
                {busy ? "正在处理…" : "授权此助手"}
              </button>
            </div>
            <p id="integration-consent-hint" className="control-hint" role="status">{consentHint}</p>
          </div>
        )}
      </section>
      <IntegrationPersonalSync enabled={personalEnabled} refreshing={q.isFetching} onRefresh={() => void q.refetch()} />
      <section className="panel panel-pad integration-panel">
        <div className="integration-connections-heading"><h2>连接管理</h2><button className="btn" disabled={busy || q.isFetching} onClick={() => void q.refetch()}>刷新连接列表</button></div>
        <p>
          App 的手机、电脑或平板登录与助手授权分别管理。安装名称可能包含插件自报的 QQ
          号，便于核对请求；名称和安装标识不证明 QQ 归属。
        </p>
        <QueryState query={q}>
          {q.data?.bindings?.length ? (
            q.data.bindings.map((b) => (
              <div className="list-row" key={b.binding_id}>
                <div className="list-main">
                  <b>{b.installation_name}</b>
                  <p>
                    {b.state === "active"
                      ? "有效"
                      : b.state === "revoked"
                        ? "已撤销"
                        : "资格已变化，需重新连接"}
                  </p>
                  <p>
                    {b.scopes
                      .split(" ")
                      .map((s) => labels[s] || s)
                      .join("；")}
                  </p>
                </div>
                {b.state !== "revoked" && (
                  <button
                    className="btn"
                    disabled={busy}
                    onClick={() => void revoke(b.binding_id)}
                  >
                    撤销授权
                  </button>
                )}
              </div>
            ))
          ) : (
            <Empty title="暂无助手授权" />
          )}
        </QueryState>
      </section>
    </div>
  );
}

export function ConnectedAction() {
  const auth = useAuth(),
    { id } = useParams();
  return auth.user && id ? (
    <ActionPanel
      key={`${auth.user.id}:${id}`}
      id={id}
      nickname={auth.user.nickname}
    />
  ) : (
    <SignIn />
  );
}
function ActionPanel({ id, nickname }: { id: string; nickname: string }) {
  const q = useApi<Preview>(
      `/api/connected-apps/actions/${encodeURIComponent(id)}`,
    ),
    [busy, setBusy] = useState(false),
    [checked, setChecked] = useState(false),
    [message, setMessage] = useState(""),
    [result, setResult] = useState<Action | null>(null),
    [stickerState, setStickerState] = useState("loading"),
    [imageAttempt, setImageAttempt] = useState(0),
    guard = useGuard();
  const action = result || q.data?.action,
    payload = action?.payload;
  const publishHint = busy ? "正在提交决定，请等待结果，暂不能重复发布。"
    : payload?.sticker_id && stickerState === "error" ? "表情未能加载，暂不能发布。请先点「重新加载表情」，看清图片后再确认。"
      : payload?.sticker_id && stickerState !== "ready" ? "表情正在加载，看清图片后才能发布，请稍候。"
        : !checked ? "请先核对全文、回复目标和发布账号，再勾选确认项，发布按钮才会可用。"
          : "核对已完成，可以确认并发布这份草稿。";
  async function decide(allow: boolean) {
    if (!q.data) return;
    const snapshot = q.data,
      current = guard();
    setBusy(true);
    setMessage("");
    try {
      const response = await write<{ action: Action }>(
        `/api/connected-apps/actions/${encodeURIComponent(id)}/decision`,
        {
          allow,
          confirmation_nonce: snapshot.confirmation_nonce,
          draft_version: snapshot.action.draft_version,
          payload_hash: snapshot.action.payload_hash,
        },
      );
      if (current()) setResult(response.action);
    } catch (e) {
      if (current()) setMessage(explain(e));
    } finally {
      if (current()) setBusy(false);
    }
  }
  return (
    <>
      <Head title="确认助手草稿">
        <Link className="btn" to="/connected-apps">
          连接管理
        </Link>
      </Head>
      <section className="panel panel-pad integration-panel">
        <p>
          发布账号：{nickname}
          。只有你在此页确认后才会发布，内容会显示「助手代发」。
        </p>
        {q.error ? (
          <>
            <Problem message={explain(q.error)} onVerified={async () => { setChecked(false); await q.refetch(); }} />
            <button className="btn" onClick={() => void q.refetch()}>
              重新加载
            </button>
          </>
        ) : (
          <QueryState query={q}>
            {action && (
              <>
                <p>
                  状态：
                  {(
                    {
                      pending: "待确认",
                      published: "已发布",
                      rejected: "已拒绝",
                      invalidated: "已失效",
                    } as Record<string, string>
                  )[action.state] || action.state}
                </p>
                {action.state === "pending" && (
                  <>
                    <p>
                      类型：
                      {action.kind === "post"
                        ? `新帖子 · ${payload?.post_type}`
                        : `评论 · 帖子 #${payload?.post_id}`}
                      {payload?.reply_to_reply_id
                        ? ` · 回复 #${payload.reply_to_reply_id}`
                        : ""}
                    </p>
                    {payload?.post_id && (
                      <Link to={`/post/${payload.post_id}`}>打开原帖核对</Link>
                    )}
                    {payload?.title && <h2>{payload.title}</h2>}
                    <p
                      style={{
                        whiteSpace: "pre-wrap",
                        overflowWrap: "anywhere",
                      }}
                    >
                      {payload?.content || "（纯表情评论）"}
                    </p>
                    {payload?.sticker_id && (
                      <p>
                        内置表情：<strong>{payload.sticker_id}</strong>
                        <img
                          key={imageAttempt}
                          className="integration-sticker"
                          onLoad={() => setStickerState("ready")}
                          onError={() => setStickerState("error")}
                          src={`/stickers/${encodeURIComponent(payload.sticker_id)}`}
                          alt={`内置表情 ${payload.sticker_id}`}
                        />
                        {stickerState === "error" && (
                          <>
                            <span role="alert">
                              表情未能加载，请重试并核对后再发布。
                            </span>
                            <button
                              className="btn"
                              onClick={() => {
                                setStickerState("loading");
                                setImageAttempt((v) => v + 1);
                              }}
                            >
                              重新加载表情
                            </button>
                          </>
                        )}
                      </p>
                    )}
                    <p>
                      草稿保留至 {new Date(action.expires_at).toLocaleString()}
                      。本次确认窗口有效至{" "}
                      {q.data?.confirmation_expires_at
                        ? new Date(
                            q.data.confirmation_expires_at,
                          ).toLocaleTimeString()
                        : ""}
                      。
                    </p>
                    <label className="field">
                      <span>
                        <input
                          type="checkbox"
                          checked={checked}
                          disabled={busy}
                          aria-describedby="integration-publish-hint"
                          onChange={(e) => setChecked(e.target.checked)}
                        />
                        我已核对全文、回复目标和发布账号
                      </span>
                    </label>
                    <div className="form-actions">
                      <button
                        className="btn"
                        disabled={busy}
                        onClick={() => void decide(false)}
                      >
                        拒绝草稿
                      </button>
                      <button
                        className="btn primary"
                        disabled={
                          busy ||
                          !checked ||
                          (!!payload?.sticker_id && stickerState !== "ready")
                        }
                        aria-describedby="integration-publish-hint"
                        onClick={() => void decide(true)}
                      >
                        {busy ? "正在提交…" : "确认并发布"}
                      </button>
                    </div>
                    <p id="integration-publish-hint" className="control-hint" role="status">{publishHint}</p>
                  </>
                )}
                {action.state === "published" && action.post_id && (
                  <p role="status">
                    发布已完成
                    {action.reply_id ? `，评论 #${action.reply_id}` : ""}。
                    <Link to={`/post/${action.post_id}`}>查看真实帖子</Link>
                  </p>
                )}
              </>
            )}
          </QueryState>
        )}
        <Problem message={message} onVerified={async () => { setChecked(false); setMessage(""); await q.refetch(); }} />
        {message && (
          <button
            className="btn"
            disabled={busy}
            onClick={() => {
              setChecked(false);
              void q.refetch();
            }}
          >
            重新加载并查询结果
          </button>
        )}
      </section>
    </>
  );
}
