import { useEffect, useRef, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useAuth } from "./auth";
import { ApiError, captureAuthSession, useApi, write } from "./api";
import { Empty, Head, QueryState } from "./ui";
import "./connected-apps.css";
import { AstrBotDashboard } from "./astrbot-dashboard";

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
const labels: Record<string, string> = {
  "community:bot_reply": "以本人管理的独立AI机器人自动评论：无需逐条确认，不代表本人发言",
  "community:bot_post": "以独立AI机器人自动发帖及上传已审核公开配图：无需逐条确认，不代表本人发言",
  "profile:read_minimal": "账号编号与昵称",
  "community:read": "公开帖子与评论、作者昵称、互动统计、公开图片和表情目录",
  "content:read_own_public": "本人公开帖子",
  "actions:read_own": "本授权创建的草稿与发布结果",
  "community:propose": "创建待本人确认的帖子或评论草稿",
  "checkin:write": "查看本人签到状态，并按本人指令每日签到（不含补签）",
};
const botDependencies = ["community:read", "actions:read_own", "community:propose"];
const botScopes = [...botDependencies, "community:bot_reply", "community:bot_post"];
const scopeTitles: Record<string, string> = { "community:read": "公开社区浏览", "actions:read_own": "草稿与结果读取", "community:propose": "创建草稿", "community:bot_reply": "机器人自动评论", "community:bot_post": "机器人自动发帖" };
function participationReady(scopes: string[]) {
  return botDependencies.every(scope => scopes.includes(scope)) && ["community:bot_reply", "community:bot_post"].some(scope => scopes.includes(scope));
}
const errors: Record<string, string> = {
  invalid_scope: "当前插件请求的权限与服务端不兼容。请部署者核对插件和服务端版本，再重新发送 /sylu-connect；原授权保留。",
  integration_unavailable: "服务暂时不可用，请重试；原授权保留。",
  recent_authentication_required:
    "请重新登录验证本人身份，然后重试。刷新页面或刷新凭证不能代替重新登录。",
  academic_verification_required:
    "当前账号尚无符合要求的教务核验。请在账号设置完成受支持的身份核验；本地自报资料不能用于此授权。",
  source_changed: "原帖或回复内容已变化，请让助手重新读取并生成草稿。",
  source_unavailable: "原帖或回复已不可用，此草稿不能发布。",
  draft_expired: "草稿已过期，请让助手重新生成。",
  confirmation_expired:
    "确认窗口已过期或已在另一页面打开，请重新加载草稿后确认。",
  binding_conflict: "已有一个有效助手授权，请明确勾选替换旧授权。",
  proposals_disabled: "服务端尚未开放草稿提案，请仅选择读取权限。",
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
function Problem({ message }: { message: string }) {
  const auth = useAuth();
  return message ? (
    <div role="alert">
      <p>{message}</p>
      {message.includes("重新登录") && (
        <button className="btn" onClick={auth.login}>
          重新登录验证
        </button>
      )}
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
    [success, setSuccess] = useState(""),
    [approved, setApproved] = useState<string[] | null>(null);
  const requestHeading = useRef<HTMLHeadingElement>(null), lookupVersion = useRef(0);
  function supplement() { requestHeading.current?.scrollIntoView({ behavior: "auto", block: "start" }); requestHeading.current?.focus(); }
  const q = useApi<{ bindings: Binding[] }>("/api/connected-apps"),
    guard = useGuard();
  async function lookup() {
    const session = guard(), version = ++lookupVersion.current;
    const current = () => session() && version === lookupVersion.current;
    setBusy(true);
    setMessage("");
    setSuccess("");
    setApproved(null);
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
            (s) => ["community:read", "actions:read_own", "content:read_own_public"].includes(s),
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
    const session = guard(), version = lookupVersion.current;
    const current = () => session() && version === lookupVersion.current;
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
        setApproved(allow ? [...selected] : null);
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
        setApproved(null);
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
    <>
      <Head
        title="已授权助手"
        subtitle="连接你自己的 AstrBot；一次只保留一个有效助手授权。"
      />
      <AstrBotDashboard />
      <section id="new-astrbot-connection" className="panel panel-pad integration-panel">
        <h2 ref={requestHeading} tabIndex={-1}>核对连接请求</h2>
        <p>在原聊天发送 <code>/sylu-connect</code> 获取一次性连接码 → 查看授权请求 → 手动选择所需权限 → 已有连接时勾选替换旧授权 → 点击「授权此助手」。无需先解绑，确认前原授权继续有效。</p>
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
                ++lookupVersion.current;
                setBusy(false);
                setCode(e.target.value);
                setConsent(null);
                setApproved(null);
                setSuccess("");
              }}
              autoComplete="off"
              required
            />
          </label>
          <button className="btn" disabled={busy || !code.trim()}>
            查看授权请求
          </button>
        </form>
        <Problem message={message} />
        {success && <p role="status">{success}</p>}
        {approved && !participationReady(approved) && <p>本次授权尚不足以自动评论或发帖。请在 AstrBot 重新申请包含所需权限的连接，再按上方步骤补充。</p>}
        {approved && participationReady(approved) && <p>自动参与所需授权已批准。请在 App「设置 → 我的 AI 机器人」启用账号，再打开上方 AstrBot 插件后台检查运行；账号启用不代表执行端已启动。</p>}
        {consent && (
          <div>
            <h3>授权给 {consent.installation_name}</h3>
            <p>安装标识：{consent.installation_id}（名称和标识由插件提供）</p>
            <p>
              请与 AstrBot 中显示的代码 <strong>{consent.user_code}</strong>{" "}
              核对。请求有效至 {new Date(consent.expires_at).toLocaleString()}。
            </p>
            {botScopes.every(scope => consent.requested_scopes.includes(scope)) && <button type="button" className="btn" disabled={busy} onClick={() => setSelected(previous => [...new Set([...previous, ...botScopes])])}>选择自动评论和发帖所需权限</button>}
            {consent.requested_scopes.map((scope) => (
              <label className="field" key={scope}>
                <span>
                  <input
                    type="checkbox"
                    checked={selected.includes(scope)}
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
            <p>
              获准读取的公开文字、作者昵称、互动统计和图片会交给你部署的
              AstrBot，可能继续发送至你选择的模型、记忆插件或部署者允许的群。SYLUlive
              无法收回已经外发的数据。本连接不提供站内私信、成绩、课表、学校密码或学校登录会话。
            </p>
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
                  (!!consent.existing_binding && !replace) ||
                  ((selected.includes("community:bot_reply") || selected.includes("community:bot_post")) && !botDependencies.every(scope => selected.includes(scope))) ||
                  (selected.includes("community:propose") &&
                    (!selected.includes("community:read") ||
                      !selected.includes("actions:read_own")))
                }
                onClick={() => void decide(true)}
              >
                {busy ? "正在处理…" : "授权此助手"}
              </button>
            </div>
          </div>
        )}
      </section>
      <section className="panel panel-pad integration-panel">
        <h2>连接管理</h2>
        <p>
          App 的手机、电脑或平板登录与助手授权分别管理；QQ
          号只用于插件本地消息路由。
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
                  {b.state === "active" && botScopes.some(scope => !b.scopes.split(/\s+/).includes(scope)) && <div className="connection-authorization-needed">
                    <h3>自动参与权限尚未齐全</h3>
                    <p>尚未批准：{botScopes.filter(scope => !b.scopes.split(/\s+/).includes(scope)).map(scope => scopeTitles[scope]).join("、")}。已批准的功能可继续使用，启用机器人不会补齐授权。</p>
                    <button type="button" className="btn" disabled={busy} onClick={supplement}>补充机器人授权</button>
                    <p>在原聊天发送 <code>/sylu-connect</code> 获取新代码；无需先断开，明确确认替换后才更新旧授权。</p>
                    <p>新请求没有所需权限时，请部署者更新插件和服务端并开放对应功能；网页不能增加未申请的权限。</p>
                  </div>}
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
    </>
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
            <Problem message={explain(q.error)} />
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
                        onClick={() => void decide(true)}
                      >
                        {busy ? "正在提交…" : "确认并发布"}
                      </button>
                    </div>
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
        <Problem message={message} />
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
