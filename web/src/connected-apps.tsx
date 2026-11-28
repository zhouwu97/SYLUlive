import { useEffect, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useAuth } from "./auth";
import { ApiError, asset, captureAuthSession, upload, useApi, write } from "./api";
import { Empty, Head, Icon, Modal, QueryState } from "./ui";
import { LegalConfirmation } from "./legal-consent";
import "./connected-apps.css";
import { IntegrationPersonalSync } from "./integration-personal-sync";
import { PasswordReauthentication } from "./reauthenticate";
import { AstrBotConnectionGuide } from "./astrbot-connection-guide";
import { AstrBotDashboard } from "./astrbot-dashboard";
import { integrationScopeTitles } from "./integration-scopes";

type Binding = {
  binding_id: string;
  installation_name: string;
  installation_id: string;
  state: string;
  scopes: string;
  epoch: number;
};
type ConnectionsResult = {
  bindings: Binding[];
  personal_data_enabled?: boolean;
  proposals_enabled?: boolean;
  auto_reply_enabled?: boolean;
  auto_post_enabled?: boolean;
};
// 站点未开放、且本连接尚未持有的权限不能新增；旧服务端未下发开关时不预判，交由服务端校验。
function unavailableScopes(data?: ConnectionsResult) {
  const blocked = new Set<string>();
  if (data?.personal_data_enabled !== true) blocked.add("academic:grades:read").add("academic:erke:read");
  if (data?.proposals_enabled === false) blocked.add("community:propose");
  if (data?.auto_reply_enabled === false) blocked.add("community:bot_reply");
  if (data?.auto_post_enabled === false) blocked.add("community:bot_post");
  return blocked;
}
type ConnectionsQuery = ReturnType<typeof useApi<ConnectionsResult>>;
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
  "community:bot_post": "以独立AI机器人自动发帖及上传已审核公开配图：每24小时最多1帖，无需逐条确认，不代表本人发言",
  "academic:grades:read": "读取本人主动同步的成绩（非学校实时查询）",
  "academic:erke:read": "读取本人主动同步的二课摘要（非完整活动记录）",
  "profile:read_minimal": "账号编号与昵称",
  "community:read": "公开帖子与评论、作者昵称、互动统计、公开图片和表情目录",
  "content:read_own_public": "本人公开帖子",
  "actions:read_own": "本授权创建的草稿与发布结果",
  "community:propose": "创建待本人确认的帖子或评论草稿",
  "checkin:write": "查看本人签到状态，并按本人指令每日签到（不含补签）",
  "community:bot_reply": "以本人管理的独立AI机器人自动评论/发表情：按本人设置，平台每24小时最多100条、至少间隔1分钟，不重复回复同一目标；不再逐条确认，不代表本人发言",
};
const scopeGroups = [
  { title: "公开浏览与连接", hint: "用于识别当前账号、阅读公开内容和查看本连接的结果。只选这些权限时，机器人不会自动发言。", scopes: ["profile:read_minimal", "community:read", "content:read_own_public", "actions:read_own"] },
  { title: "机器人自动参与", hint: "自动评论需要「创建草稿＋自动评论」；自动发帖需要「创建草稿＋自动发帖」。两者都需要上方的公开社区读取和草稿结果权限。", scopes: ["community:propose", "community:bot_reply", "community:bot_post"] },
  { title: "可选：本人查询与签到", hint: "自动浏览、评论和发帖都不需要这些权限。仅在你要通过 QQ 查询本人已同步资料或签到时选择，默认不勾选。", scopes: ["academic:grades:read", "academic:erke:read", "checkin:write"] },
];
type AssistantPurpose = "personal" | "bot";
const personalScopes = ["profile:read_minimal", "checkin:write", "academic:grades:read", "academic:erke:read"];
const personalScopeGroups = [
  { title: "账号识别", hint: "让 QQ 机器人识别你本人授权的校园账号。", scopes: ["profile:read_minimal"] },
  { title: "本人签到与查询", hint: "按需勾选。签到不需要同步成绩或二课，也不需要创建社区机器人。", scopes: ["checkin:write", "academic:grades:read", "academic:erke:read"] },
];
function groupsFor(purpose: AssistantPurpose) {
  return purpose === "personal" ? personalScopeGroups : scopeGroups.slice(0, 2);
}
function scopesFor(purpose: AssistantPurpose) {
  return groupsFor(purpose).flatMap(group => group.scopes);
}
function purposeLink(params: URLSearchParams, purpose: AssistantPurpose) {
  const next = new URLSearchParams(params);
  next.set("purpose", purpose);
  next.delete("guide");
  next.delete("view");
  return `/connected-apps?${next}`;
}
const botScopeDependencies = ["community:read", "actions:read_own", "community:propose"];
// 按分组顺序展示已批准权限，避免服务端字母序把成绩、二课排在最前面。
const scopeOrder = scopeGroups.flatMap(group => group.scopes);
function orderedScopes(raw: string) {
  const rank = (scope: string) => { const index = scopeOrder.indexOf(scope); return index < 0 ? scopeOrder.length : index; };
  return raw.split(/\s+/).filter(Boolean).sort((a, b) => rank(a) - rank(b));
}
const botParticipationScopes = [...botScopeDependencies, "community:bot_reply", "community:bot_post"];
function missingBotScopes(binding: Binding) {
  const scopes = new Set(binding.scopes.split(/\s+/));
  return botParticipationScopes.filter(scope => !scopes.has(scope));
}
type ScopeEdit = { id: string; epoch: number; selected: string[] };
// 与服务端 integrationScopes 的依赖规则一致，保存前就提示，避免提交后才被拒。
function scopeProblems(selected: string[]) {
  const problems: string[] = [];
  if (!selected.length) problems.push("请至少保留一项权限；不再需要时请改用「断开此连接」。");
  if ((selected.includes("community:bot_post") || selected.includes("community:bot_reply")) && !selected.includes("community:propose"))
    problems.push("自动评论或发帖还需要勾选「创建待本人确认的帖子或评论草稿」。");
  if (selected.includes("community:propose") && (!selected.includes("community:read") || !selected.includes("actions:read_own")))
    problems.push("创建草稿还需要勾选「公开帖子与评论」及「本授权创建的草稿与发布结果」。");
  return problems;
}
const errors: Record<string, string> = {
  invalid_user_code: "连接码无效，请核对后重试，或在 AstrBot 重新发送 /sylu-connect 获取新代码。",
  device_request_expired: "这份连接请求已过期。请在 AstrBot 重新发送 /sylu-connect 获取新代码，机器人设置和已有授权不受影响。",
  recent_authentication_required:
    "继续前请验证当前账号的密码。验证成功后可继续本次操作，无需重新登录。",
  academic_verification_required:
    "连接本站账号和签到不需要教务核验。当前请求仍被此限制拦住，请联系维护者处理；无需重新绑定教务。",
  source_changed: "原帖或回复内容已变化，请让助手重新读取并生成草稿。",
  source_unavailable: "原帖或回复已不可用，此草稿不能发布。",
  draft_expired: "草稿已过期，请让助手重新生成。",
  confirmation_expired:
    "确认窗口已过期或已在另一页面打开，请重新加载草稿后确认。",
  installation_conflict: "这份机器人连接已被另一个校园账号授权。请先在原账号撤销连接，不能直接挪用他人的绑定。",
  personal_queries_disabled: "服务端尚未开放成绩和二课查询，当前可只授权其他已开放能力。",
  binding_conflict: "已有有效连接或连接状态已变化。请刷新连接列表后重新核对；替换新执行端时需勾选替换旧授权。",
  binding_unavailable: "未找到这条连接，请刷新连接列表。",
  invalid_scope: "所选权限组合无效，请检查依赖项后重试。",
  proposals_disabled: "服务端尚未开放草稿提案，请仅选择读取权限。",
  owner_publish_disabled: "服务端尚未开放正式发布，此草稿尚未发布。",
  section_muted: "当前账号已被该版块禁言。",
  community_rules_required: "请先在校园社区阅读并接受现行社区规则。",
  invalid_token: "授权已失效，请在 AstrBot 重新连接。",
  bot_reply_disabled: "服务端尚未开放机器人自动评论，可先管理机器人。",
  bot_disabled: "机器人已暂停，请先启用后再重试。",
  invalid_bot_name: "请输入1–24个字符的机器人名称。",
  invalid_bot_avatar: "头像不可用，请重新选择并上传自己的图片。",
  invalid_bot_policy: "权限或发言规则不符合要求，请检查板块、屏蔽词与参与频率。",
  bot_policy_denied: "这项操作已被机器人的社区权限或发言规则禁止。",
  bot_post_disabled: "服务端尚未开放机器人自动发帖，请先保持只读。",
  bot_permission_denied: "机器人当前未获准执行这项操作，请本人检查社区权限。",
  account_unavailable: "当前账号不可用，请检查账号状态。",
  integration_unavailable: "服务暂时不可用，请稍后重试。",
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
function SignIn({ children }: { children?: ReactNode }) {
  const auth = useAuth();
  return (
    <Empty icon={auth.loading ? "search" : "lock"} title={auth.loading ? "正在确认登录状态" : "请先登录 SYLUlive"}>
      <div className="empty-actions">
        <button
          className="btn primary"
          disabled={auth.loading}
          onClick={auth.login}
        >
          登录
        </button>
        {children}
      </div>
    </Empty>
  );
}
function Problem({ message, onVerified, onCancel }: { message: string; onVerified?: () => Promise<unknown>; onCancel?: () => void }) {
  const [verificationOpen, setVerificationOpen] = useState(true);
  useEffect(() => { setVerificationOpen(true); }, [message]);
  return message ? (
    <div className="integration-feedback integration-feedback--error" role="alert">
      <p>{verificationOpen ? message : "已取消密码验证，本次操作未提交。"}</p>
      {message === errors.recent_authentication_required && onVerified && (verificationOpen
        ? <PasswordReauthentication onVerified={onVerified} onCancel={() => { setVerificationOpen(false); onCancel?.(); }} />
        : <button className="btn" type="button" onClick={() => setVerificationOpen(true)}>重新验证密码</button>)}
    </div>
  ) : null;
}

function IntegrationFrame({ title, subtitle, action, children }: {
  title: string;
  subtitle?: string;
  action?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="integration-workspace">
      <Head title={title} subtitle={subtitle}>{action}</Head>
      {children}
    </div>
  );
}

type BotPolicy = {
  post_enabled: boolean;
  image_enabled: boolean;
  public_read_enabled: boolean;
  reply_enabled: boolean;
  sticker_enabled: boolean;
  allowed_post_types: string[];
  blocked_terms: string[];
  block_links: boolean;
  daily_reply_limit: number;
  hourly_reply_limit?: number;
  min_reply_interval_minutes: number;
};
type ManagedBot = {
  bot_user_id: number;
  name: string;
  avatar: string;
  enabled: boolean;
  owner: { id: number; nickname: string };
  policy: BotPolicy;
};
type BotStatus = {
  bot: ManagedBot | null;
  default_policy?: BotPolicy;
  policy_supported?: boolean;
  sections?: { slug: string; name: string }[];
  auto_reply_server_enabled: boolean;
  auto_reply_authorized: boolean;
  auto_post_server_enabled?: boolean;
  auto_post_authorized?: boolean;
  runtime_supported?: boolean;
  runtime?: BotRuntime;
};
type BotRuntime = {
  state: string;
  error_code?: string;
  last_seen_at?: string;
  last_read_at?: string;
  next_run_at?: string;
  last_action?: { kind: string; completed_at: string; post_id?: number; reply_id?: number };
};
const runtimeLabels: Record<string, string> = {
  not_created: "尚未创建", paused: "已暂停", read_disabled: "公开浏览未开放",
  scope_required: "AstrBot 尚未获得公开社区读取权限", offline: "执行端离线或尚未连接", syncing: "正在同步新权限",
  idle: "等待下一轮", waiting: "排队中", loading: "正在浏览", completed: "本轮已完成",
  empty: "暂无符合条件的帖子", error: "执行失败", disabled: "执行端未开启自动浏览", cooldown: "等待下次执行",
};
function BotRuntimePanel({ initial, supported, enabled, onConnect }: { initial?: BotRuntime; supported: boolean; enabled: boolean; onConnect: () => void }) {
  const q = useApi<{runtime: BotRuntime}>(supported ? "/api/connected-apps/bot/runtime" : null);
  const refetch = useRef(q.refetch);
  refetch.current = q.refetch;
  useEffect(() => {
    if (!supported) return;
    void refetch.current();
    const timer = window.setInterval(() => { if (!document.hidden) void refetch.current(); }, 30000);
    return () => window.clearInterval(timer);
  }, [supported, initial]);
  const runtime = q.data?.runtime || initial;
  let state = runtime?.state || "unknown";
  if (!enabled) state = "paused";
  if (runtime?.last_seen_at && Date.now() - Date.parse(runtime.last_seen_at) > 120000 && !["paused", "read_disabled", "scope_required", "not_created"].includes(state)) state = "offline";
  const verified = supported && !q.isError && !q.isFetching;
  function date(value?: string) {
    const time = value ? new Date(value) : null;
    return time && Number.isFinite(time.getTime()) ? time.toLocaleString("zh-CN", {month:"numeric", day:"numeric", hour:"2-digit", minute:"2-digit"}) : "暂无记录";
  }
  return <section className="bot-policy-section" aria-label="后台运行状态">
    <h3>后台运行</h3>
    <p role="status">{!supported ? "服务端尚未提供运行状态" : !verified ? "运行状态尚未核验" : runtimeLabels[state] || "运行状态尚未核验"}</p>
    {verified && <>
      {state === "scope_required" && <div className="integration-feedback">
        <p>绑定只建立连接，后台浏览还需要你批准「公开社区浏览」；已有的「本人公开帖子」是另一项权限，不能代替它。在「连接 AstrBot」的当前连接卡片点「修改权限」，勾选公开浏览并保存即可；无需重新连接，也不需要成绩、二课或签到权限。</p>
        <button className="btn" type="button" onClick={onConnect}>查看连接与补充授权</button>
      </div>}
      <dl className="bot-conditions">
        <div><dt>最近浏览</dt><dd>{date(runtime?.last_read_at)}</dd></div>
        <div><dt>最近发言</dt><dd>{runtime?.last_action ? `${runtime.last_action.kind === "post" ? "帖子" : "评论"} · ${date(runtime.last_action.completed_at)}` : "暂无成功记录"}</dd></div>
      </dl>
      {runtime?.next_run_at && !["offline", "paused", "read_disabled", "scope_required", "disabled", "syncing"].includes(state) && <p className="integration-hint">下次计划：{date(runtime.next_run_at)}</p>}
      {state === "error" && <p className="integration-hint">{runtime?.error_code === "provider_required" ? "执行端尚未配置浏览模型，请联系部署者。" : "本轮未完成，执行端将按间隔重新检查。"}</p>}
    </>}
    {supported && <button className="btn" type="button" disabled={q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在核验运行状态…" : "刷新运行状态"}</button>}
    <p className="integration-hint">状态来自执行端心跳；超过两分钟未收到心跳会显示离线。最近发言以服务端成功记录为准。</p>
  </section>;
}
const initialBotPolicy = (): BotPolicy => ({
  public_read_enabled: true, reply_enabled: false, sticker_enabled: false, post_enabled: false, image_enabled: false,
  allowed_post_types: ["campus_life", "course_study"], blocked_terms: [],
  block_links: true, daily_reply_limit: 100, min_reply_interval_minutes: 1,
});
function botAvatar(value: string) {
  const source = asset(value);
  if (!source) return undefined;
  const url = new URL(source, location.origin);
  return url.origin === location.origin && url.pathname.startsWith("/uploads/") ? source : undefined;
}
function botProblem(error: unknown) {
  return error instanceof ApiError && error.status === 404
    ? "当前服务端尚未支持机器人管理，请升级服务后重试。账号和权限尚未创建。"
    : explain(error);
}
function BotPanel({ active, onConnect }: { active: boolean; onConnect: () => void }) {
  const auth = useAuth(), q = useApi<BotStatus>("/api/connected-apps/bot");
  const guard = useGuard(), picker = useRef<HTMLInputElement>(null), pending = useRef(false), dirty = useRef(false);
  const [name, setName] = useState("大肥鱼"), [avatar, setAvatar] = useState("");
  const [avatarFailed, setAvatarFailed] = useState(false);
  const [policy, setPolicy] = useState<BotPolicy>(initialBotPolicy);
  const [terms, setTerms] = useState("");
  const [busy, setBusy] = useState(false), [uploading, setUploading] = useState(false);
  const [paused, setPaused] = useState(false);
  const [message, setMessage] = useState(""), [notice, setNotice] = useState("");
  useEffect(() => {
    const bot = q.data?.bot;
    if (!q.data || dirty.current) return;
    setName(bot?.name || "大肥鱼");
    setAvatar(bot?.avatar || "");
    setAvatarFailed(false);
    const savedPolicy = {...initialBotPolicy(),...(bot?.policy || q.data.default_policy)};
    setPolicy(savedPolicy);
    setTerms(savedPolicy.blocked_terms.join("\n"));
    setPaused(false);
  }, [q.data]);
  function edited() { dirty.current = true; setNotice(""); }
  function changePolicy<K extends keyof BotPolicy>(key: K, value: BotPolicy[K]) {
    setPolicy(previous => ({ ...previous, [key]: value }));
    edited();
  }
  async function chooseAvatar(file: File | undefined) {
    if (!file || pending.current) return;
    if (!["image/png", "image/jpeg", "image/gif"].includes(file.type) || file.size > 10 * 1024 * 1024) {
      setMessage("请选择不超过 10 MiB 的 JPG、PNG 或 GIF 图片。"); return;
    }
    const current = guard();
    pending.current = true; setUploading(true); setMessage(""); setNotice("");
    let preview = "";
    try {
      preview = URL.createObjectURL(file);
      const image = new Image();
      image.src = preview;
      await image.decode();
      if (!image.naturalWidth || !image.naturalHeight) throw new Error("invalid_image");
      if (!current()) return;
      const source = await upload(file);
      if (current()) {
        if (!botAvatar(source)) throw new Error("invalid_avatar_url");
        setAvatar(source); setAvatarFailed(false);
        dirty.current = true;
        setNotice("头像已上传，保存机器人资料后会公开显示。");
      }
    } catch (error) {
      if (current()) setMessage(error instanceof ApiError ? explain(error) : "头像未能上传，请检查图片后重新选择。原头像仍保留。");
    } finally {
      if (preview) URL.revokeObjectURL(preview);
      if (current()) { pending.current = false; setUploading(false); }
    }
  }
  async function save(enabled: boolean, pause = false) {
    if (pending.current) return;
    const current = guard(), existed = !!q.data?.bot;
    const blocked = terms.split(/[\n，,]/).map(term => term.trim()).filter(Boolean);
    if (!pause && (blocked.length > 20 || blocked.some(term => Array.from(term).length > 24))) {
      setMessage("屏蔽词最多 20 个，每个最多 24 个字符。"); return;
    }
    pending.current = true; setBusy(true); setMessage(""); setNotice("");
    try {
      await write("/api/connected-apps/bot", pause ? { enabled: false } : {
        name: name.trim(), avatar, enabled, policy: { ...policy, blocked_terms: blocked },
      });
      if (current()) {
        // 暂停只改变运行开关，保留尚未保存的资料与规则草稿。
        if (pause && q.data?.bot) {
          setPaused(true);
          setNotice("机器人已暂停，不再接受新的自动发布。未保存的修改仍保留。");
        } else {
          dirty.current = false;
          await q.refetch();
          if (current()) setNotice(!existed ? "机器人已新建并暂停。核对权限后，可单独启用。" : enabled ? "资料与权限已保存，机器人已启用。" : "资料与权限已保存，机器人仍为暂停状态。");
        }
      }
    } catch (error) {
      if (current()) setMessage(botProblem(error));
    } finally {
      if (current()) { pending.current = false; setBusy(false); }
    }
  }
  const bot = q.data?.bot ? { ...q.data.bot, enabled: !paused && q.data.bot.enabled } : null;
  const supported = q.data?.policy_supported === true;
  const locked = busy || uploading, editable = supported && !locked;
  const valid = !!name.trim() && Number.isInteger(policy.daily_reply_limit) && policy.daily_reply_limit >= 1 && policy.daily_reply_limit <= 100 && Number.isInteger(policy.min_reply_interval_minutes) && policy.min_reply_interval_minutes >= 1 && policy.min_reply_interval_minutes <= 1440;
  const sections = q.data?.sections || [];
  return (
    <section className="panel panel-pad integration-panel bot-panel" aria-busy={busy || uploading}>
      <header className="integration-section-head">
        <Icon name="ai" size={26} />
        <div><p className="integration-eyebrow">一个账号，一位独立 AI</p><h2>我的 AI 机器人</h2></div>
      </header>
      <p className="integration-description">设置独立机器人在社区能做什么。这里保存的是你的管理规则；还需在「连接 AstrBot」中授权执行端，机器人才能自动参与。</p>
      {q.error ? <div className="integration-feedback integration-feedback--error" role="alert">
        <p>{botProblem(q.error)}</p><button className="btn" onClick={() => void q.refetch()}>重试读取机器人状态</button>
      </div> : <QueryState query={q}>
        <div className="bot-identity">
          <div className="bot-avatar" aria-label="机器人头像预览">
            {botAvatar(avatar) && !avatarFailed ? <img src={botAvatar(avatar)} alt="机器人头像" onError={() => setAvatarFailed(true)} /> : <Icon name="ai" size={32} />}
          </div>
          <div>
            <p className="bot-account-state" data-state={bot?.enabled ? "enabled" : "idle"}>
              <Icon name={bot?.enabled ? "check" : "clock"} size={18} />
              {bot ? `机器人 #${bot.bot_user_id} · ${bot.enabled ? "已启用" : "已暂停"}` : "尚未创建机器人"}
            </p>
            <p className="bot-owner">{bot?.owner?.nickname || auth.user?.nickname} 的 AI<span>公开归属标识</span></p>
          </div>
        </div>
        {!supported && <p className="integration-feedback integration-feedback--error" role="alert">服务端尚未支持头像与社区权限管理，请升级服务后使用。现有机器人仍可暂停。</p>}
        <form onSubmit={event => { event.preventDefault(); void save(bot?.enabled || false); }}>
          <fieldset disabled={!editable} className="bot-form-fields">
            <legend className="bot-form-heading">{bot ? "机器人资料" : "新建机器人"}</legend>
            <label className="field">机器人名称<input value={name} maxLength={24} onChange={e => { setName(e.target.value); edited(); }} aria-describedby="bot-name-hint" required /></label>
            <p id="bot-name-hint" className="integration-hint">1–24 个字符。名字和头像会公开显示；机器人与创建者使用不同账号。</p>
            <div className="bot-avatar-actions">
              <input ref={picker} type="file" hidden accept="image/jpeg,image/png,image/gif" aria-label="上传机器人头像" onChange={event => { const file = event.currentTarget.files?.[0]; event.currentTarget.value = ""; void chooseAvatar(file); }} />
              <button type="button" className="btn" onClick={() => picker.current?.click()}>{uploading ? "头像上传中…" : avatar ? "更换头像" : "选择头像"}</button>
              {avatar && <button type="button" className="btn" onClick={() => { setAvatar(""); setAvatarFailed(false); edited(); }}>移除头像</button>}
            </div>
            {avatarFailed && <p className="integration-feedback integration-feedback--error" role="alert">头像加载失败，请重新上传或移除头像。</p>}
            <p className="integration-hint">支持 JPG、PNG、GIF，最大 10 MiB。请选择可公开展示的图片。</p>
            {!bot && <div className="bot-create-actions"><button className="btn primary" disabled={!editable || !valid}>{busy ? "正在保存…" : "新建机器人"}</button><p className="integration-hint">创建后默认暂停。核对下方权限与发言规则，再单独启用。</p></div>}
            <section className="bot-policy-section" aria-labelledby="bot-permission-heading">
              <h3 id="bot-permission-heading">社区权限</h3>
              <label className="bot-check"><input type="checkbox" checked={policy.public_read_enabled} onChange={event => {
                const checked = event.target.checked;
                changePolicy("public_read_enabled", checked);
              }} /><span><strong>浏览公开社区</strong><small>仅访问下方允许板块。关闭后停止所有浏览和自动发言，下方选择仍保留。</small></span></label>
              <label className="bot-check"><input type="checkbox" checked={policy.reply_enabled} disabled={!policy.public_read_enabled} onChange={event => changePolicy("reply_enabled", event.target.checked)} /><span><strong>自动文字评论</strong><small>使用机器人账号发言，无需逐条确认；默认关闭。</small></span></label>
              <label className="bot-check"><input type="checkbox" checked={policy.sticker_enabled} disabled={!policy.public_read_enabled} onChange={event => changePolicy("sticker_enabled", event.target.checked)} /><span><strong>发表内置表情</strong><small>仅可使用平台表情目录，不能上传任意图片评论。</small></span></label>
              <label className="bot-check"><input type="checkbox" checked={policy.post_enabled} disabled={!policy.public_read_enabled} onChange={event => changePolicy("post_enabled", event.target.checked)} /><span><strong>自动发布帖子</strong><small>默认关闭，需另行授予发帖权限；每24小时最多1帖。</small></span></label>
              <label className="bot-check"><input type="checkbox" checked={policy.image_enabled} disabled={!policy.public_read_enabled || !policy.post_enabled} onChange={event => changePolicy("image_enabled", event.target.checked)} /><span><strong>使用已审核公开配图</strong><small>只用于机器人帖子，不从私人聊天自动收集表情或图片。</small></span></label>
              {policy.image_enabled && policy.block_links && <p className="integration-hint" role="status">已审核配图会附上来源署名链接。当前「禁止发送链接」已开启，机器人会先发文字；如需配图，请在下方发言规则中允许链接。</p>}
              <h4>允许访问的板块</h4>
              <p className="integration-hint">未选中的板块禁止访问与发言；只允许公开内容，不提供私信、个人账号或后台访问。</p>
              <div className="bot-section-options">
                {sections.map(section => <label className="bot-check" key={section.slug}><input type="checkbox" checked={policy.allowed_post_types.includes(section.slug)} disabled={!policy.public_read_enabled} onChange={event => changePolicy("allowed_post_types", event.target.checked ? [...policy.allowed_post_types, section.slug] : policy.allowed_post_types.filter(slug => slug !== section.slug))} /><span>{section.name}</span></label>)}
              </div>
              {!sections.length && <p className="integration-hint">当前没有可选的公开板块。机器人无法访问未被允许的板块。</p>}
            </section>
            <section className="bot-policy-section" aria-labelledby="bot-speech-heading">
              <h3 id="bot-speech-heading">发言规则</h3>
              <label className="field">屏蔽词<textarea aria-label="屏蔽词" value={terms} onChange={event => { setTerms(event.target.value); edited(); }} maxLength={520} rows={3} placeholder="每行一个，最多 20 个" aria-describedby="bot-terms-hint" /></label>
              <p id="bot-terms-hint" className="integration-hint">命中任一屏蔽词的帖子和评论会被服务端阻止。每个词最多 24 个字符，平台社区规则同时适用。</p>
              <label className="bot-check"><input type="checkbox" checked={policy.block_links} onChange={event => changePolicy("block_links", event.target.checked)} /><span><strong>禁止在帖子和评论中发送链接</strong><small>阻止网址引流；关闭后仍须遵守平台规则。</small></span></label>
              <div className="bot-frequency">
                <label className="field">每 24 小时最多评论数<select value={policy.daily_reply_limit} onChange={event => changePolicy("daily_reply_limit", Number(event.target.value))}>{Array.from({length:100}, (_, i) => i + 1).map(value => <option key={value} value={value}>{value} 条</option>)}</select></label>
                <label className="field">评论间隔（分钟）<input type="number" min={1} max={1440} step={1} value={policy.min_reply_interval_minutes} onChange={event => changePolicy("min_reply_interval_minutes", Number(event.target.value))} required /></label>
              </div>
              <p className="integration-hint">{policy.hourly_reply_limit ? `服务端规则：每小时最多 ${policy.hourly_reply_limit} 条。` : '服务端未设置每小时上限。'}</p>
              <p className="integration-hint">文字、表情和具体评论回复合计计数，每条最多 300 字；顶层评论同帖一次，具体评论按目标去重，不回复自己或其他 AI。平台上限为 100 条／24 小时、至少间隔 1 分钟；按你保存的频率执行，实际参与也取决于浏览计划与合适的讨论。</p>
            </section>
          </fieldset>
          {bot && <div className="form-actions bot-save-actions">
            <button className="btn primary" disabled={!editable || !valid}>{busy ? "正在保存…" : "保存资料与权限"}</button>
            {bot && !bot.enabled && <button type="button" className="btn" disabled={!editable || !valid} onClick={() => void save(true)}>保存并启用</button>}
            {bot?.enabled && <button type="button" className="btn" disabled={locked} onClick={() => void save(false, true)}>暂停机器人</button>}
            {bot && !supported && !bot.enabled && <p className="integration-hint">请先升级服务端，再编辑或启用机器人。</p>}
          </div>}
        </form>
        {bot && <BotRuntimePanel initial={q.data?.runtime} supported={q.data?.runtime_supported === true} enabled={bot.enabled} onConnect={onConnect} />}
        <section className="bot-policy-section" aria-labelledby="bot-conditions-heading">
          <h3 id="bot-conditions-heading">自动参与条件</h3>
          <dl className="bot-conditions">
            <div><dt>自动评论服务</dt><dd className="integration-state" data-ready={q.data?.auto_reply_server_enabled}><Icon name={q.data?.auto_reply_server_enabled ? "check" : "clock"} size={16} />{q.data?.auto_reply_server_enabled ? "已开放" : "暂未开放"}</dd></div>
            <div><dt>助手评论授权</dt><dd className="integration-state" data-ready={q.data?.auto_reply_authorized}><Icon name={q.data?.auto_reply_authorized ? "check" : "clock"} size={16} />{q.data?.auto_reply_authorized ? "已授权" : "尚未授权"}</dd></div>
            <div><dt>自动发帖服务</dt><dd>{q.data?.auto_post_server_enabled ? "已开放" : "暂未开放"}</dd></div>
            <div><dt>助手发帖授权</dt><dd>{q.data?.auto_post_authorized ? "已授权" : "尚未授权"}</dd></div>
          </dl>
          <p className="integration-hint">自动评论和发帖都需要：这里开放对应功能 → 在「连接 AstrBot」批准对应权限 → 保存并启用机器人。已有连接仍缺权限时，点击连接卡片里的「补充机器人授权」直接勾选保存，无需重新连接。AstrBot 也需开启自动浏览并配置模型。</p>
          <button className="btn" type="button" onClick={onConnect}>下一步：连接 AstrBot</button>
        </section>
      </QueryState>}
      {active && <Problem message={message} onCancel={() => { setMessage(""); setNotice("已取消密码验证。机器人资料和权限草稿仍保留，操作未提交。"); }} onVerified={async () => {
        const current = guard();
        await q.refetch();
        if (current()) {
          setMessage("");
          setNotice("验证完成，请重新核对机器人资料和权限后保存或启用。");
        }
      }} />}
      {notice && <p className="integration-feedback integration-feedback--success" role="status">{notice}</p>}
      <div className="bot-policy-section">
        <h3>记忆与隐私</h3>
        <ul className="bot-privacy">
          <li><Icon name="community" size={19} /><div><strong>群聊</strong><p>群聊只保留短期上下文，不写长期记忆。</p></div></li>
          <li><Icon name="admin" size={19} /><div><strong>创建者私聊</strong><p>创建者私聊记忆仅用于本人私聊，在 AstrBot 本机加密保存。</p></div></li>
          <li><Icon name="campus" size={19} /><div><strong>公开社区</strong><p>公开社区阅读单独记忆；自动评论无法读取私人记忆、账号资料或登录态。</p></div></li>
        </ul>
        <p className="integration-hint">清除记忆与选择模型仍在你部署的 AstrBot 管理。暂停、板块权限与发言规则由服务端执行。</p>
      </div>
    </section>
  );
}


function ConnectionStatus({ query: q, nickname, onManage, purpose }: { query: ConnectionsQuery; nickname: string; onManage: () => void; purpose: AssistantPurpose }) {
  const known = !q.error && Array.isArray(q.data?.bindings);
  const active = Array.isArray(q.data?.bindings) ? q.data.bindings.filter(binding => binding.state === "active") : [];
  const hasPersonalScope = active.some(binding => binding.scopes.split(/\s+/).some(scope => personalScopes.includes(scope)));
  const connectedLabel = purpose === "bot" ? "已连接 AstrBot" : hasPersonalScope ? "已绑定 QQ 机器人" : "已有授权连接";
  return <section className="connection-status" aria-label="当前连接状态" aria-live="polite" aria-busy={q.isFetching}>
    <Icon name="monitor" size={22} />
    <div>
      <strong>{q.isPending ? "正在核对连接状态…" : !known ? "连接状态未确认" : q.isFetching ? "正在更新连接状态…" : active.length ? connectedLabel : "当前没有有效连接"}</strong>
      {q.isPending ? <p>正在读取当前账号的授权，不需要输入连接码。</p> : !known
        ? <p>读取失败不能判断为未绑定。请先重试，不要重复生成连接或撤销已有授权。</p>
        : active.length ? <><p>{nickname} 已授权给 {active.map(binding => binding.installation_name).join("、")}。{purpose === "bot" && active.some(binding => missingBotScopes(binding).length > 0) ? "现有权限继续有效；如需自动参与，请在「管理连接」核对并补充缺少的权限。" : "无需再填连接码。"}</p><p>{purpose === "personal" ? "签到和查询以你批准的本人权限为准。需要调整时，在下方修改权限即可。" : "后台是否正在执行，请查看「机器人设置与运行」中的启用状态与心跳。"}</p></>
        : <p>{purpose === "personal" ? "在与 QQ 机器人的原聊天发送 /sylu-connect，再用它返回的链接绑定自己的校园账号。" : "在「连接 AstrBot」核对执行端连接码，授权机器人参与社区。"}</p>}
    </div>
    {!known && !q.isPending ? <button className="btn" type="button" disabled={q.isFetching} onClick={() => void q.refetch()}>重试读取连接状态</button>
      : <button className="btn" type="button" disabled={q.isPending} onClick={onManage}>{active.length ? "管理连接" : "开始连接"}</button>}
  </section>;
}

function ScopeEditor({ editing, busy, unavailable, onChange, onSave, onCancel, purpose }: {
  editing: ScopeEdit; busy: boolean; unavailable: Set<string>;
  purpose: AssistantPurpose;
  onChange: (selected: string[]) => void; onSave: () => void; onCancel: () => void;
}) {
  const problems = scopeProblems(editing.selected);
  return <div className="connection-scope-editor" role="group" aria-label="修改连接权限">
    <h4>修改权限</h4>
    <p className="integration-hint">保存后立即生效，连接与 AstrBot 凭证保持不变，无需重新连接。收回「创建草稿」时，尚未确认的草稿会失效。</p>
    <p className="integration-hint">这里只修改{purpose === "personal" ? "本人签到与查询" : "社区机器人"}权限，另一用途已有的权限会保留。断开连接会同时撤销该连接的所有权限。</p>
    {groupsFor(purpose).map(group => <fieldset className="integration-scope-group" key={group.title} disabled={busy}>
      <legend>{group.title}</legend>
      <p className="integration-hint">{group.hint}</p>
      {group.scopes.map(scope => {
        const checked = editing.selected.includes(scope);
        const blocked = unavailable.has(scope) && !checked;
        return <div key={scope}>
          <label className="field">
            <input type="checkbox" checked={checked} disabled={blocked}
              onChange={event => onChange(event.target.checked ? [...editing.selected, scope] : editing.selected.filter(item => item !== scope))} />
            {labels[scope] || scope}
          </label>
          {blocked && <p className="integration-hint">站点尚未开放此功能，暂不能新增；已持有的权限可以保留或收回。</p>}
        </div>;
      })}
    </fieldset>)}
    {problems.length > 0 && <div id="integration-scope-edit-requirements" className="integration-hint" role="status"><ul>{problems.map(problem => <li key={problem}>{problem}</li>)}</ul></div>}
    <div className="form-actions">
      <button className="btn" type="button" disabled={busy} onClick={onCancel}>取消</button>
      <button className="btn primary" type="button" disabled={busy || problems.length > 0} aria-describedby={problems.length ? "integration-scope-edit-requirements" : undefined} onClick={onSave}>{busy ? "正在保存…" : "保存权限"}</button>
    </div>
  </div>;
}

function CurrentConnections({ query: q, nickname, busy, disconnect, confirmed, onDisconnect, onCancelDisconnect, onConfirmed, onRevoke, editing, onEdit, onEditChange, onSaveScopes, onCancelEdit, purpose }: {
  query: ConnectionsQuery; nickname: string; busy: boolean; disconnect: Binding | null; confirmed: boolean;
  purpose: AssistantPurpose;
  onDisconnect: (binding: Binding) => void; onCancelDisconnect: () => void; onConfirmed: (value: boolean) => void; onRevoke: (id: string) => void;
  editing: ScopeEdit | null; onEdit: (binding: Binding, addBot: boolean) => void; onEditChange: (selected: string[]) => void;
  onSaveScopes: () => void; onCancelEdit: () => void;
}) {
  const known = !q.error && Array.isArray(q.data?.bindings);
  const bindings = Array.isArray(q.data?.bindings) ? q.data.bindings : [], active = bindings.filter(binding => binding.state === "active"), history = bindings.filter(binding => binding.state !== "active");
  return <>
    <header className="integration-connections-heading"><h2>{q.isPending || !known ? "连接管理" : active.length ? "当前有效连接" : "当前没有有效连接"}</h2>
      <button className="btn" type="button" disabled={q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在刷新连接列表…" : "刷新连接列表"}</button>
    </header>
    {q.isPending ? <p role="status">正在读取连接，请稍候…</p> : !known
      ? <p className="integration-hint">连接状态尚未核验；可点击「刷新连接列表」重试，现有授权不会因此被撤销。</p>
      : <>
        {q.isFetching && <p className="integration-hint" role="status">正在更新连接状态，下面保留上次读取的结果…</p>}
        {active.length ? active.map(binding => <article className="current-astrbot-connection" key={binding.binding_id}>
          <div className="connection-installation-heading"><h3>{binding.installation_name}</h3><span className="connection-state-label">已连接</span></div>
          <p>校园账号：<strong>{nickname}</strong>。此授权已生效，无需再次输入连接码。</p>
          <ul className="connection-permission-tags" aria-label="当前连接已批准权限">{orderedScopes(binding.scopes).filter(scope => scopesFor(purpose).includes(scope)).map(scope => <li key={scope}>{integrationScopeTitles[scope] || scope}</li>)}</ul>
          {purpose === "personal" && !binding.scopes.split(/\s+/).some(scope => personalScopes.slice(1).includes(scope)) && <p className="integration-hint">这条连接尚未授权本人签到或资料查询。需要使用时，点击「修改权限」选择对应功能。</p>}
          {editing?.id === binding.binding_id ? <ScopeEditor purpose={purpose} editing={editing} busy={busy || q.isFetching} unavailable={unavailableScopes(q.data)}
            onChange={onEditChange} onSave={onSaveScopes} onCancel={onCancelEdit} />
            : <>
              {purpose === "bot" && missingBotScopes(binding).length > 0 && <div className="connection-authorization-needed">
                <h4>自动参与权限尚未齐全</h4>
                <p className="integration-hint">尚未批准：{missingBotScopes(binding).map(scope => integrationScopeTitles[scope]).join("、")}。已连接只代表上方列出的权限有效，启用机器人不会补齐授权。</p>
                <button className="btn primary" type="button" disabled={busy || q.isFetching} onClick={() => onEdit(binding, true)}>补充机器人授权</button>
                <p className="integration-hint">直接在这里勾选并保存即可，连接和 AstrBot 凭证保持不变，无需重新连接或发送 <code>/sylu-connect</code>。</p>
              </div>}
            </>}
          <details className="connection-permission-details"><summary>查看完整权限与执行端信息</summary>
            <ul>{orderedScopes(binding.scopes).map(scope => <li key={scope}>{labels[scope] || scope}</li>)}</ul>
            <p className="integration-hint">安装标识：{binding.installation_id}。安装名称和标识由插件自报，不证明 QQ 归属；App 登录设备另行管理。</p>
          </details>
          <p className="integration-hint">{purpose === "personal" ? "授权完成后回到原 QQ 聊天使用本人功能，无需进入机器人后台或启用社区机器人。" : "这条连接允许 AstrBot 执行已批准的功能。机器人还需启用、满足规则并收到执行端心跳，才会按计划运行。"}</p>
          {disconnect?.binding_id === binding.binding_id ? <div className="connection-disconnect" role="group" aria-label="确认断开连接">
            <h4>断开「{binding.installation_name}」？</h4>
            <p>这会撤销该执行端的全部已批准权限，旧凭证和待发布草稿将失效。机器人资料、已发布内容和其他人的连接会保留。需要再次使用时，在 AstrBot 重新发起连接并授权。</p>
            <label className="bot-check"><input type="checkbox" checked={confirmed} disabled={busy} onChange={event => onConfirmed(event.target.checked)} /><span>我确认断开这条连接</span></label>
            <div className="form-actions"><button className="btn danger" type="button" disabled={busy || q.isFetching || !confirmed} onClick={() => onRevoke(binding.binding_id)}>{busy ? "正在断开…" : "确认断开连接"}</button><button className="btn" type="button" disabled={busy} onClick={onCancelDisconnect}>保持连接</button></div>
          </div> : editing?.id !== binding.binding_id && <div className="form-actions connection-card-actions">
            <button className="btn" type="button" disabled={busy || q.isFetching} onClick={() => onEdit(binding, false)}>修改权限</button>
            <button className="btn" type="button" disabled={busy || q.isFetching} onClick={() => onDisconnect(binding)}>断开此连接</button>
          </div>}
        </article>) : <p className="integration-description">{purpose === "personal" ? "当前校园账号尚未绑定 QQ 机器人。在原 QQ 聊天发送 /sylu-connect，打开返回的本人链接，或点击「绑定我的 QQ 账号」填写连接码。" : "当前账号没有有效的 AstrBot 授权。下方历史记录不代表仍在连接；在原聊天取得新请求后，可点击「连接新的 AstrBot」。"}</p>}
        {history.length > 0 && <details className="connection-history"><summary>历史连接（{history.length}）</summary>
          <p className="integration-hint">这里只保留旧授权记录，不会继续执行，也不需要再次撤销。</p>
          {history.map(binding => <div className="connection-history-row" key={binding.binding_id}><strong>{binding.installation_name}</strong><span>{binding.state === "revoked" ? "已撤销 · 已断开" : "授权已失效 · 需重新连接"}</span></div>)}
        </details>}
      </>}
  </>;
}

export function ConnectedApps() {
  const auth = useAuth();
  const [params] = useSearchParams();
  const purpose: AssistantPurpose = params.get("purpose") === "bot" || (params.get("purpose") !== "personal" && params.get("guide") === "astrbot") ? "bot" : "personal";
  return (
    <IntegrationFrame title="QQ 助手与社区机器人">
      <nav className="integration-purposes" aria-label="管理分类">
        <Link to={purposeLink(params, "personal")} aria-current={purpose === "personal" ? "true" : undefined}>
          <Icon name="profile" size={22} />
          <span><strong id="assistant-category-personal">绑定我的 QQ</strong><small>用 QQ 助手签到、查自己的成绩和二课</small></span>
        </Link>
        <Link to={purposeLink(params, "bot")} aria-current={purpose === "bot" ? "true" : undefined}>
          <Icon name="ai" size={22} />
          <span><strong id="assistant-category-bot">管理社区机器人</strong><small>设置自己的 AstrBot，管理社区互动和运行</small></span>
        </Link>
      </nav>
      <section aria-labelledby={`assistant-category-${purpose}`}>
        {auth.loading ? <p className="integration-description" role="status">正在核对校园账号…</p>
          : auth.user ? <AssistantWorkspace key={`${auth.user.id}-${purpose}`} purpose={purpose} nickname={auth.user.nickname} />
          : purpose === "bot" && params.get("guide") === "astrbot"
            ? <AstrBotConnectionGuide onConnect={auth.login} onBot={auth.login} />
            : <><p className="integration-description">{purpose === "personal" ? "请登录自己的校园账号，核对原 QQ 聊天中的连接码，再选择签到或查询权限。不要使用他人转发的链接，学校密码不要发给机器人。" : "登录后可管理自己创建的社区机器人及其参与权限。"}</p><SignIn /></>}
      </section>
    </IntegrationFrame>
  );
}
type AssistantView = "bot" | "connection" | "data" | "guide";
function PersonalGuide() {
  return <section className="panel panel-pad integration-panel" aria-label="QQ 签到查询使用说明">
    <h2>在 QQ 使用自己的签到与查询</h2>
    <ol className="astrbot-guide-steps">
      <li>在与 QQ 机器人的原聊天发送 <code>/sylu-connect</code>，打开属于本人的临时链接。</li>
      <li>登录自己的校园账号，核对连接码，按需勾选「本人签到与查询」权限，再确认授权。</li>
      <li>回原聊天发送 <code>/sylu-status</code> 核对连接。签到用 <code>/sylu-checkin</code>，签到状态用 <code>/sylu-checkin-status</code>。</li>
      <li>查询成绩用 <code>/sylu-grades</code>，二课用 <code>/sylu-erke</code>。需先在「个人资料同步」同步对应摘要，并批准对应权限；查询结果会标明同步时间，不是学校实时查询。</li>
    </ol>
    <p className="integration-hint">绑定本站账号、查看连接和本人签到无需教务核验。成绩、二课没有资料或学校连接失败时，在网页「个人资料同步」重新连接并准备资料；这些问题不会断开 QQ 或影响签到。功能和群聊入口仍由部署者开放，绑定不会开启每日自动签到。</p>
  </section>;
}
function AssistantWorkspace({ nickname, purpose }: { nickname: string; purpose: AssistantPurpose }) {
  const [params] = useSearchParams();
  const dataEntry = purpose === "personal" && params.get("view") === "data";
  const [view, setView] = useState<AssistantView>(params.get("user_code") ? "connection" : dataEntry ? "data" : purpose === "personal" ? "connection" : params.get("guide") === "astrbot" ? "guide" : "bot");
  const urlCode = params.get("user_code") || "", urlGuide = params.get("guide") || "";
  const previousEntry = useRef({ code: urlCode, guide: urlGuide, data: dataEntry });
  useEffect(() => {
    if (urlCode && previousEntry.current.code !== urlCode) setView("connection");
    else if (!urlCode && dataEntry && !previousEntry.current.data) setView("data");
    else if (!urlCode && urlGuide === "astrbot" && previousEntry.current.guide !== urlGuide) setView("guide");
    previousEntry.current = { code: urlCode, guide: urlGuide, data: dataEntry };
  }, [urlCode, urlGuide, dataEntry]);
  const connections = useApi<ConnectionsResult>("/api/connected-apps");
  return <>
    <p className="integration-current-account">当前校园账号：<strong>{nickname}</strong>。请核对是你本人，勿替他人授权。</p>
    {!(purpose === "personal" && urlCode && view === "connection") && <ConnectionStatus purpose={purpose} query={connections} nickname={nickname} onManage={() => setView("connection")} />}
    {purpose === "bot" && !urlCode && <section className="integration-guide" aria-label="机器人启用步骤">
      <h2>让机器人自动参与社区</h2>
      <ol><li><strong>1. 设置机器人</strong><span>选择允许的板块、评论、发帖与配图。</span></li><li><strong>2. 连接并核对权限</strong><span>已有连接先看已批准权限；缺少浏览、评论或发帖权限时补充授权。</span></li><li><strong>3. 启用并检查</strong><span>所需权限齐全后，回到机器人设置启用，查看浏览与发言记录。</span></li></ol>
      <p>登录后可直接管理当前连接和机器人。成绩、二课和签到都是可选功能，自动发帖不需要它们。</p>
    </section>}
    <nav className="integration-views" aria-label="助手管理分区">
      {(purpose === "bot" ? [["bot", "机器人设置与运行"], ["connection", "连接 AstrBot"], ["guide", "接入教程"]] as const : [["connection", "账号绑定与权限"], ["data", "个人资料同步"], ["guide", "使用说明"]] as const).map(([key, title]) => <button key={key} className="btn" type="button" aria-pressed={view === key} aria-controls={`assistant-${key}`} onClick={() => setView(key)}>{title}</button>)}
    </nav>
    {purpose === "bot" && <div id="assistant-bot" hidden={view !== "bot"}><BotPanel active={view === "bot"} onConnect={() => setView("connection")} /></div>}
    <ConnectionPanel purpose={purpose} nickname={nickname} view={view} query={connections} onBot={() => setView("bot")} onGuide={() => setView("guide")} />
    <div id="assistant-guide" hidden={view !== "guide"}>{purpose === "personal" ? <PersonalGuide /> : <><AstrBotConnectionGuide onConnect={() => setView("connection")} onBot={() => setView("bot")} />{view === "guide" && <details className="integration-deployer-tools"><summary>部署者工具与后台</summary><AstrBotDashboard /></details>}</>}</div>
  </>;
}
function ConnectionPanel({ nickname, view, query: q, onBot, onGuide, purpose }: { nickname: string; view: AssistantView; query: ConnectionsQuery; onBot: () => void; onGuide: () => void; purpose: AssistantPurpose }) {
  const queryClient = useQueryClient();
  const requestHeading = useRef<HTMLHeadingElement>(null);
  const lookupVersion = useRef(0);
  const consumedUrlCode = useRef("");
  const [params, setParams] = useSearchParams(),
    [code, setCode] = useState(params.get("user_code") || ""),
    [requestOpen, setRequestOpen] = useState(!!params.get("user_code")),
    [disconnect, setDisconnect] = useState<Binding | null>(null),
    [disconnectConfirmed, setDisconnectConfirmed] = useState(false),
    [consent, setConsent] = useState<Consent | null>(null),
    [selected, setSelected] = useState<string[]>([]),
    [checked, setChecked] = useState(false),
    [replace, setReplace] = useState(false),
    [editing, setEditing] = useState<ScopeEdit | null>(null),
    [busy, setBusy] = useState(false),
    [message, setMessage] = useState(""),
    [success, setSuccess] = useState("");
  const [legalRequired, setLegalRequired] = useState(false);
  const guard = useGuard();
  function showProblem(error: unknown) {
    if (error instanceof ApiError && error.code === "legal_consent_required") {
      setLegalRequired(true);
      setMessage("请在弹窗中确认当前版本协议，再重新核对授权请求。连接码已保留。");
    } else {
      setMessage(explain(error));
    }
  }
  // 记住最近一次写操作，密码验证通过后只继续触发验证的那一项，不误执行另一张表单。
  const lastOperation = useRef<"consent" | "scopes" | "other">("other");
  // 连接已断开或被替换时关闭编辑区，避免沿用旧版本号保存。
  useEffect(() => {
    if (!editing || !Array.isArray(q.data?.bindings)) return;
    const binding = q.data.bindings.find(item => item.binding_id === editing.id);
    if (binding?.state !== "active" || binding.epoch !== editing.epoch) setEditing(null);
  }, [q.data, editing]);
  const connectionsKnown = !q.error && !q.isFetching && Array.isArray(q.data?.bindings);
  const participationReady = connectionsKnown && q.data?.bindings.some(binding => binding.state === "active" &&
    botScopeDependencies.every(scope => binding.scopes.split(/\s+/).includes(scope)) &&
    ["community:bot_reply", "community:bot_post"].some(scope => binding.scopes.split(/\s+/).includes(scope)));
  const urlCode = params.get("user_code") || "";
  const previousUrlCode = useRef(urlCode);
  useEffect(() => {
    const previous = previousUrlCode.current;
    if (previous === urlCode) return;
    previousUrlCode.current = urlCode;
    if (!urlCode && consumedUrlCode.current === previous) { consumedUrlCode.current = ""; return; }
    lookupVersion.current++;
    setCode(urlCode); setConsent(null); setSelected([]); setChecked(false); setReplace(false);
    setMessage(""); setSuccess(""); setBusy(false); setRequestOpen(!!urlCode);
  }, [urlCode]);
  const personalSelected = selected.some(scope => scope === "academic:grades:read" || scope === "academic:erke:read");
  const personalBlocked = personalSelected && (!!q.error || q.isFetching || q.data?.personal_data_enabled !== true);
  const canSelectBotScopes = purpose === "bot" && !!consent && [...botScopeDependencies, "community:bot_reply", "community:bot_post"].every(scope => consent.requested_scopes.includes(scope));
  const authorizationProblems: string[] = [];
  if (!checked) authorizationProblems.push("请先核对连接码与当前账号，并勾选外发范围确认。");
  if (!selected.length) authorizationProblems.push("请至少选择一项本次请求的权限。");
  if ((selected.includes("community:bot_post") || selected.includes("community:bot_reply")) && !selected.includes("community:propose"))
    authorizationProblems.push("自主评论或发帖还需要单独勾选「创建待本人确认的帖子或评论草稿」。");
  if (selected.includes("community:propose") && (!selected.includes("community:read") || !selected.includes("actions:read_own")))
    authorizationProblems.push("创建草稿还需要勾选「公开帖子与评论」及「本授权创建的草稿与发布结果」。");
  if (personalBlocked) authorizationProblems.push("成绩或二课的服务状态尚未确认，或服务未开放。请重新检查授权条件；也可取消成绩、二课权限，仅授权其他功能。");
  if (consent?.existing_binding && !replace) authorizationProblems.push("已有有效连接，请核对并勾选替换旧授权。");
  async function lookup(preserveSelection = false) {
    lastOperation.current = "consent";
    const previous = preserveSelection ? consent : null;
    const previousSelection = selected;
    const sessionCurrent = guard(), version = ++lookupVersion.current;
    const current = () => sessionCurrent() && version === lookupVersion.current;
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
        const sameRequest = previous && previous.consent_id === result.consent_id && previous.installation_id === result.installation_id && previous.user_code === result.user_code;
        setSelected(sameRequest
          ? previousSelection.filter(scope => result.requested_scopes.includes(scope))
          : result.requested_scopes.filter(
            (s) => scopesFor(purpose).includes(s) && !["community:propose", "checkin:write", "community:bot_reply", "community:bot_post", "academic:grades:read", "academic:erke:read"].includes(s),
          ),
        );
      }
    } catch (e) {
      if (current()) showProblem(e);
    } finally {
      if (current()) setBusy(false);
    }
  }
  function selectBotScopes() {
    if (!canSelectBotScopes) return;
    const blocked = unavailableScopes(q.data);
    setSelected(previous => [...new Set([...previous, ...[...botScopeDependencies, "community:bot_reply", "community:bot_post"].filter(scope => !blocked.has(scope))])]);
  }
  async function decide(allow: boolean) {
    if (!consent) return;
    lastOperation.current = "consent";
    if (allow && (q.error || q.isFetching || q.data?.personal_data_enabled !== true) && selected.some(s => s === "academic:grades:read" || s === "academic:erke:read")) {
      setMessage("个人查询尚未开放或状态未确认，请先重新检查服务状态，或取消选择成绩、二课权限。"); return;
    }
    const sessionCurrent = guard(), version = lookupVersion.current;
    const current = () => sessionCurrent() && version === lookupVersion.current;
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
        setRequestOpen(false);
        if (allow) {
          setCode(""); setSelected([]); setChecked(false); setReplace(false);
          if (params.has("user_code")) {
            consumedUrlCode.current = params.get("user_code") || "";
            const next = new URLSearchParams(params);
            next.delete("user_code");
            setParams(next, { replace: true });
          }
        }
        setSuccess(
          allow
            ? purpose === "personal" ? "已授权。回到原 QQ 聊天，等待机器人确认绑定后使用本人功能。" : "已授权。返回 AstrBot，等待插件完成连接。"
            : "已拒绝本次授权。",
        );
        await q.refetch();
        await queryClient.invalidateQueries({ queryKey: ["api", "/api/connected-apps/bot"] });
      }
    } catch (e) {
      if (current()) showProblem(e);
    } finally {
      if (current()) setBusy(false);
    }
  }
  function startEdit(binding: Binding, addBot: boolean) {
    const current = binding.scopes.split(/\s+/).filter(Boolean);
    const unavailable = unavailableScopes(q.data);
    // 补充机器人授权只预选站点已开放的自动参与权限，不顺带勾选成绩、二课或签到。
    const additions = addBot ? botParticipationScopes.filter(scope => !unavailable.has(scope)) : [];
    setEditing({ id: binding.binding_id, epoch: binding.epoch, selected: [...new Set([...current, ...additions])] });
    setDisconnect(null); setMessage(""); setSuccess("");
  }
  async function saveScopes() {
    if (!editing || scopeProblems(editing.selected).length) return;
    const current = guard(), snapshot = editing;
    lastOperation.current = "scopes";
    setBusy(true);
    setMessage("");
    try {
      await write(`/api/connected-apps/${encodeURIComponent(snapshot.id)}/scopes`, { scopes: snapshot.selected, expected_epoch: snapshot.epoch });
      if (current()) {
        setEditing(null);
        setSuccess("权限已更新并立即生效。连接与 AstrBot 凭证保持不变，无需重新连接。");
        await q.refetch();
        await queryClient.invalidateQueries({ queryKey: ["api", "/api/connected-apps/bot"] });
      }
    } catch (e) {
      if (current()) {
        showProblem(e);
        // 连接已变化时刷新列表，编辑区会随之关闭，不保留旧版本号。
        if (e instanceof ApiError && (e.code === "binding_conflict" || e.code === "binding_unavailable")) await q.refetch();
      }
    } finally {
      if (current()) setBusy(false);
    }
  }
  async function revoke(id: string) {
    lastOperation.current = "other";
    const current = guard();
    setBusy(true);
    setMessage("");
    try {
      await write(`/api/connected-apps/${encodeURIComponent(id)}/revoke`);
      if (current()) {
        setDisconnect(null); setDisconnectConfirmed(false);
        setSuccess("已断开这条连接。旧凭证及待发布草稿已失效；机器人资料、已发布内容和其他人的连接会保留。");
        await q.refetch();
        await queryClient.invalidateQueries({ queryKey: ["api", "/api/connected-apps/bot"] });
      }
    } catch (e) {
      if (current()) {
        setSuccess(""); setDisconnectConfirmed(false);
        setMessage("断开请求未取得确定结果，正在只读核对连接状态；不会自动重试断开。");
        try {
          // 写入回包丢失不代表失败；只读核对一次，不能据缓存重发撤销。
          const verified = await q.refetch();
          if (!current()) return;
          if (verified.error || !Array.isArray(verified.data?.bindings)) {
            setMessage("断开结果未确认：暂时无法读取最新连接状态。请重试读取状态，未自动重复断开操作。");
            return;
          }
          const binding = verified.data.bindings.find(item => item.binding_id === id);
          if (binding?.state === "revoked") {
            setDisconnect(null); setMessage("");
            setSuccess("已确认这条连接已断开。原请求的回包未到达，但最新授权记录已撤销；机器人资料和已发布内容会保留。");
            await queryClient.invalidateQueries({ queryKey: ["api", "/api/connected-apps/bot"] });
          } else if (binding?.state === "active") {
            setDisconnect(binding);
            setMessage(`${explain(e)} 已核实这条连接仍然有效，尚未断开。确认项已重置；核对后可重新操作，本次没有自动重试。`);
          } else {
            setMessage("断开结果未确认：最新记录中未能核对到这条有效或已撤销的授权。请检查连接列表，未自动重复断开操作。");
          }
        } catch {
          if (current()) setMessage("断开结果未确认：暂时无法读取最新连接状态。请重试读取状态，未自动重复断开操作。");
        }
      }
    } finally {
      if (current()) setBusy(false);
    }
  }
  const problem = view === "connection" && <Problem message={message} onCancel={() => { setMessage(""); setSuccess(lastOperation.current === "scopes" ? "已取消密码验证。所选权限已保留，尚未保存。" : "已取消密码验证。连接码已保留，本次连接授权未提交。"); }} onVerified={async () => {
    setMessage("");
    if (lastOperation.current === "scopes") { if (editing) await saveScopes(); else await q.refetch(); return; }
    if (code.trim()) await lookup(true);
    else await q.refetch();
  }} />;
  return (
    <>
      <div id="assistant-connection" hidden={view !== "connection"} className="integration-connections">
      {requestOpen && <section id="new-astrbot-connection" className="panel panel-pad integration-panel" aria-busy={busy}>
        <header className="integration-section-head"><Icon name="monitor" size={22} /><h2 ref={requestHeading} tabIndex={-1}>{purpose === "personal" ? "核对本人绑定请求" : "核对连接请求"}</h2></header>
        {purpose === "personal" ? <p className="integration-description">确认下方是你本人在原 QQ 聊天发起的请求，按需选择签到或查询权限。连接和签到无需教务核验；成绩、二课可以连接成功后再准备。</p> : <ol className="astrbot-guide-steps">
          <li>在与机器人的原聊天发送 <code>/sylu-connect</code>，取得本次官网链接或一次性连接码。无需先断开现有连接。</li>
          <li>打开机器人给的新链接，或在下方输入新码并点击「查看授权请求」。</li>
          <li>选择自动浏览、评论或发帖所需权限，核对外发范围后点击「授权此助手」。已有连接时，还需确认替换旧授权。</li>
        </ol>}
        <p className="integration-hint">它是一次性的短期核对码（旧称设备代码），不是电脑编号、登录密码或绑定状态。</p>
        {purpose === "bot" && <p className="integration-description">这一步为独立社区机器人授权。按需要选择自动评论或发帖权限，保存并启用后才会运行。</p>}
        <p>
          授权账号：{nickname}。只为自己刚刚在 AstrBot
          发起的请求授权。不要替他人输入连接码。
        </p>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void lookup();
          }}
        >
          <label className="field">
            一次性连接码
            <input
              value={code}
              maxLength={16}
              onChange={(e) => {
                lookupVersion.current++;
                setCode(e.target.value);
                setConsent(null);
                setSelected([]); setChecked(false); setReplace(false); setMessage(""); setSuccess(""); setBusy(false);
              }}
              autoComplete="off"
              required
            />
          </label>
          <button className="btn" disabled={busy || !code.trim()}>
            查看授权请求
          </button>
        </form>
        {lastOperation.current === "consent" && problem}
        {busy && lastOperation.current === "consent" && <p className="integration-hint" role="status">正在处理本人授权请求，请稍候…</p>}
        {consent && (
          <div>
            <h3>授权给 {consent.installation_name}</h3>
            {purpose === "bot" && <p>安装标识：{consent.installation_id}（名称和标识由插件提供）</p>}
            <p>
              请与 AstrBot 中显示的代码 <strong>{consent.user_code}</strong>{" "}
              核对。请求有效至 {new Date(consent.expires_at).toLocaleString()}。
            </p>
            {canSelectBotScopes && <div className="integration-scope-shortcut"><button className="btn" type="button" disabled={busy} onClick={selectBotScopes}>选择自动评论和发帖所需权限</button><p className="integration-hint">仅补齐公开读取、草稿和独立机器人发言权限；不会勾选成绩、二课或签到，也不会立即授权。</p></div>}
            {groupsFor(purpose).map(group => {
              const scopes = group.scopes.filter(scope => consent.requested_scopes.includes(scope));
              return scopes.length > 0 && <fieldset className="integration-scope-group" key={group.title} disabled={busy}>
                <legend>{group.title}</legend><p className="integration-hint">{group.hint}</p>
                {scopes.map((scope) => <div key={scope}>
              <label className="field" key={scope}>
                <span>
                  <input
                    type="checkbox"
                    checked={selected.includes(scope)}
                    disabled={unavailableScopes(q.data).has(scope)}
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
              {scope === "community:propose" && <p className="integration-hint">这是生成内容的共同前置权限。单独勾选只会生成待确认草稿；另选下方自动评论／发帖后，才允许以独立机器人账号自动发布。</p>}
              {unavailableScopes(q.data).has(scope) && <p className="integration-hint">站点尚未开放此功能，暂不能新增授权。</p>}
                </div>)}
              </fieldset>;
            })}
            {purpose === "bot" && !consent.requested_scopes.includes("community:bot_post") && !consent.requested_scopes.includes("community:bot_reply") && <p className="integration-hint">这份连接请求未申请机器人自主评论或发帖。请在与机器人的私聊，或部署者已开放机器人授权的群内重新发送 /sylu-connect，再核对新请求。</p>}
            {purpose === "personal" && !consent.requested_scopes.some(scope => personalScopes.slice(1).includes(scope)) && <p className="integration-hint">这份请求没有申请本人签到或资料查询。可先完成账号识别，再在当前连接的「修改权限」按需授权；若功能未开放，请联系机器人部署者。</p>}
            <p className="integration-hint">当前只选择{purpose === "personal" ? "本人签到与查询" : "社区机器人"}用途的权限。需要另一用途时，可切换上方入口；不会自动勾选或提交授权。</p>
            {purpose === "bot" && <p>
              获准读取的公开文字、作者昵称、互动统计和图片会交给你部署的
              AstrBot，可能继续发送至你选择的模型、记忆插件或部署者允许的群。SYLUlive
              无法收回已经外发的数据。本连接不提供站内私信、课表、学校密码或学校登录会话。
            </p>}
            {purpose === "personal" && <><p>所选功能的请求和结果会交给 QQ 机器人。共享机器人部署者可能保存返回结果；群内展示会向该群公开，请仅授权你信任的机器人。</p><details className="connection-permission-details"><summary>数据范围与群聊隐私说明</summary><p>安装标识：{consent.installation_id}（名称和标识由插件提供，不证明 QQ 归属）。签到、成绩和二课均需按需勾选。查询按本人明确命令返回已同步数据，标明同步时间，不是学校实时查询。允许的用户、群及结果投递由机器人后台配置；在群内查询并确认展示，或在已配置直接展示的群明确查询，会向该群公开本人结果，群成员、后续群模型与记忆可能保存。绑定不会自动完成学校登录或数据同步。</p><p>QQ、机器人部署者及其安装的其他插件可能保存私聊和返回结果。SYLUlive 后台管理员不会仅凭管理身份获得他人成绩读取接口。</p></details></>}
            {purpose === "bot" && <p>如果连接共享机器人，QQ、机器人部署者及其安装的其他插件可能保存私聊和返回结果；请确认你信任部署者。SYLUlive 后台管理员不会仅凭管理身份获得他人成绩读取接口。</p>}
            <label className="field">
              <span>
                <input
                  type="checkbox"
                  checked={checked}
                  onChange={(e) => setChecked(e.target.checked)}
                />
                我已核对连接码与当前账号，并了解外发范围
              </span>
            </label>
            {consent.existing_binding && (
              <div>
              <p className="integration-hint">替换会撤销旧连接的全部权限，本次只批准当前选中的权限。旧连接中另一用途的权限也会被收回；如需保留，请取消本次请求，改在已有连接中「修改权限」。</p>
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
              </div>
            )}
            {authorizationProblems.length > 0 && <div id="integration-consent-requirements" className="integration-hint" role="status">
              <p>授权前还需完成：</p>
              <ul>{authorizationProblems.map(problem => <li key={problem}>{problem}</li>)}</ul>
              {personalBlocked && <button className="btn" type="button" disabled={busy || q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在检查授权条件…" : "重新检查授权条件"}</button>}
            </div>}
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
                disabled={busy || authorizationProblems.length > 0}
                aria-describedby={authorizationProblems.length ? "integration-consent-requirements" : undefined}
                onClick={() => void decide(true)}
              >
                {busy ? "正在处理…" : "授权此助手"}
              </button>
            </div>
          </div>
        )}
      </section>}
      <section className="panel panel-pad integration-panel" aria-label={purpose === "personal" ? "QQ 账号绑定管理" : "AstrBot 连接管理"}>
        <CurrentConnections purpose={purpose} query={q} nickname={nickname} busy={busy} disconnect={disconnect} confirmed={disconnectConfirmed}
          onDisconnect={binding => { setDisconnect(binding); setDisconnectConfirmed(false); setMessage(""); }}
          onCancelDisconnect={() => { setDisconnect(null); setDisconnectConfirmed(false); }}
          onConfirmed={setDisconnectConfirmed} onRevoke={id => void revoke(id)}
          editing={editing} onEdit={startEdit} onEditChange={selected => setEditing(value => value && { ...value, selected })}
          onSaveScopes={() => void saveScopes()} onCancelEdit={() => setEditing(null)} />
        {lastOperation.current !== "consent" && problem}
        {success && <p className="integration-feedback integration-feedback--success" role="status">{success}</p>}
        {success.startsWith("已授权。") && purpose === "bot" && <>
          <p className="integration-hint">{!connectionsKnown ? "请先刷新连接列表核对已批准权限，再启用自动参与。" : participationReady
            ? "已批准的自动参与功能可在机器人设置中启用；其他功能仍以连接卡片列出的权限为准。"
            : "本次授权尚不足以自动评论或发帖。请在上方连接卡片点「补充机器人授权」勾选所需权限并保存，再启用自动参与。"}</p>
          <button className={`btn${participationReady ? " primary" : ""}`} type="button" onClick={onBot}>{participationReady ? "去启用机器人并检查运行" : "返回机器人设置"}</button>
        </>}
        {success.startsWith("已授权。") && <p className="integration-hint">网站授权已生效。回到原聊天发送 /sylu-status 核对执行端是否取得授权；连接码无需重复填写。</p>}
        {purpose === "personal" && <div className="integration-personal-commands" aria-label="QQ 本人功能命令">
          <h3>回到原 QQ 聊天使用</h3>
          <dl><div><dt>本人签到</dt><dd><code>/sylu-checkin</code></dd></div><div><dt>签到状态</dt><dd><code>/sylu-checkin-status</code></dd></div><div><dt>查询成绩</dt><dd><code>/sylu-grades</code></dd></div><div><dt>查询二课</dt><dd><code>/sylu-erke</code></dd></div></dl>
          <p className="integration-hint">仅可使用部署者已开放且你已授权的功能。成绩与二课还需先在「个人资料同步」同步摘要。绑定不会开启每日自动签到。</p>
        </div>}
        <div className="connection-next-actions">
          <button className="btn" type="button" disabled={busy} aria-expanded={requestOpen} aria-controls="new-astrbot-connection"
            onClick={() => { if (requestOpen) { lookupVersion.current++; setConsent(null); setBusy(false); } setRequestOpen(!requestOpen); }}>
            {purpose === "personal" ? requestOpen ? "收起绑定表单" : "绑定我的 QQ 账号" : requestOpen ? "收起新连接表单" : "连接新的 AstrBot"}
          </button>
          <button className="btn" type="button" onClick={onGuide}>{purpose === "personal" ? "查看使用说明" : "查看接入教程"}</button>
          <p className="integration-hint">保留现有连接时不用重新绑定；增减权限直接在连接卡片点「修改权限」。只有更换执行端时，才需从 AstrBot 发起新请求。</p>
        </div>
      </section>
      </div>
      {purpose === "personal" && <div id="assistant-data" hidden={view !== "data"}>
        <p className="integration-data-hint">这里供本人 QQ 查询使用，和机器人自动发帖分开。仅需自动参与社区时，无需同步成绩或二课。</p>
        <button className="btn" type="button" disabled={q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在刷新个人查询状态…" : "刷新个人查询状态"}</button>
        <IntegrationPersonalSync enabled={q.error || q.isFetching ? undefined : q.data?.personal_data_enabled} refreshing={q.isFetching} onRefresh={() => void q.refetch()} />
      </div>}
      {legalRequired && <Modal title="确认协议后继续授权" close={() => {
        setLegalRequired(false);
        setMessage("协议尚未确认，连接码已保留。再次操作时可重新打开确认窗口。");
      }}>
        <p>当前账号缺少现行必需协议的完整有效同意记录。协议更新后，旧版本的同意不能代替对新内容的确认，需要由你本人阅读并确认。</p>
        <p>当前账号：<strong>{nickname}</strong>。确认协议不会重新绑定 QQ，也不会自动批准助手权限。</p>
        <LegalConfirmation onAccepted={() => {
          setLegalRequired(false);
          setMessage("");
          setSuccess("协议已确认，连接码和权限选择已保留。请重新核对授权请求后继续；连接码过期时回 QQ 发送 /sylu-connect 获取新码。");
        }} />
      </Modal>}
    </>
  );
}

export function ConnectedAction() {
  const auth = useAuth(),
    { id } = useParams();
  return (
    <IntegrationFrame title="确认助手草稿" action={<Link className="btn" to="/connected-apps?purpose=bot">连接管理</Link>}>
      {auth.user && id ? <ActionPanel key={`${auth.user.id}:${id}`} id={id} nickname={auth.user.nickname} /> : <SignIn />}
    </IntegrationFrame>
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
