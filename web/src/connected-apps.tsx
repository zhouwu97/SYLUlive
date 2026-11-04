import { useEffect, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useAuth } from "./auth";
import { ApiError, asset, captureAuthSession, upload, useApi, write } from "./api";
import { Empty, Head, Icon, QueryState } from "./ui";
import "./connected-apps.css";
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
  "community:bot_reply": "以本人管理的独立AI机器人自动评论/发表情：每24小时最多3条、间隔30分钟、同帖不重复；不再逐条确认，不代表本人发言",
};
const scopeGroups = [
  { title: "公开浏览与连接", hint: "用于识别当前账号、阅读公开内容和查看本连接的结果。只选这些权限时，机器人不会自动发言。", scopes: ["profile:read_minimal", "community:read", "content:read_own_public", "actions:read_own"] },
  { title: "机器人自动参与", hint: "自动评论需要「创建草稿＋自动评论」；自动发帖需要「创建草稿＋自动发帖」。两者都需要上方的公开社区读取和草稿结果权限。", scopes: ["community:propose", "community:bot_reply", "community:bot_post"] },
  { title: "可选：本人查询与签到", hint: "自动浏览、评论和发帖都不需要这些权限。仅在你要通过 QQ 查询本人已同步资料或签到时选择，默认不勾选。", scopes: ["academic:grades:read", "academic:erke:read", "checkin:write"] },
];
const botScopeDependencies = ["community:read", "actions:read_own", "community:propose"];
const errors: Record<string, string> = {
  invalid_user_code: "设备代码无效，请核对后重试，或在 AstrBot 重新发送 /sylu-connect 获取新代码。",
  device_request_expired: "这份连接请求已过期。请在 AstrBot 重新发送 /sylu-connect 获取新代码，机器人设置和已有授权不受影响。",
  recent_authentication_required:
    "继续前请验证当前账号的密码。验证成功后可继续本次操作，无需重新登录。",
  academic_verification_required:
    "当前账号尚无符合要求的教务核验。请在账号设置完成受支持的身份核验；本地自报资料不能用于此授权。",
  source_changed: "原帖或回复内容已变化，请让助手重新读取并生成草稿。",
  source_unavailable: "原帖或回复已不可用，此草稿不能发布。",
  draft_expired: "草稿已过期，请让助手重新生成。",
  confirmation_expired:
    "确认窗口已过期或已在另一页面打开，请重新加载草稿后确认。",
  installation_conflict: "这份机器人连接已被另一个校园账号授权。请先在原账号撤销连接，不能直接挪用他人的绑定。",
  personal_queries_disabled: "服务端尚未开放成绩和二课查询，当前可只授权其他已开放能力。",
  binding_conflict: "已有一个有效助手授权，请明确勾选替换旧授权。",
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
  scope_required: "缺少本人公开浏览授权", offline: "执行端离线或尚未连接", syncing: "正在同步新权限",
  idle: "等待下一轮", waiting: "排队中", loading: "正在浏览", completed: "本轮已完成",
  empty: "暂无符合条件的帖子", error: "执行失败", disabled: "执行端未开启自动浏览", cooldown: "等待下次执行",
};
function BotRuntimePanel({ initial, supported, enabled }: { initial?: BotRuntime; supported: boolean; enabled: boolean }) {
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
  block_links: true, daily_reply_limit: 3, min_reply_interval_minutes: 30,
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
    setPolicy({...initialBotPolicy(),...bot?.policy});
    setTerms((bot?.policy?.blocked_terms || []).join("\n"));
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
  const valid = !!name.trim() && Number.isInteger(policy.min_reply_interval_minutes) && policy.min_reply_interval_minutes >= 30 && policy.min_reply_interval_minutes <= 1440;
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
                <label className="field">每 24 小时最多评论数<select value={policy.daily_reply_limit} onChange={event => changePolicy("daily_reply_limit", Number(event.target.value))}>{[1, 2, 3].map(value => <option key={value} value={value}>{value} 条</option>)}</select></label>
                <label className="field">评论间隔（分钟）<input type="number" min={30} max={1440} step={1} value={policy.min_reply_interval_minutes} onChange={event => changePolicy("min_reply_interval_minutes", Number(event.target.value))} required /></label>
              </div>
              <p className="integration-hint">文字和表情合计计数，每条最多 300 字，同一帖子不重复参与。可设置更低频率；平台上限为 3 条／24 小时、至少间隔 30 分钟。</p>
            </section>
          </fieldset>
          {bot && <div className="form-actions bot-save-actions">
            <button className="btn primary" disabled={!editable || !valid}>{busy ? "正在保存…" : "保存资料与权限"}</button>
            {bot && !bot.enabled && <button type="button" className="btn" disabled={!editable || !valid} onClick={() => void save(true)}>保存并启用</button>}
            {bot?.enabled && <button type="button" className="btn" disabled={locked} onClick={() => void save(false, true)}>暂停机器人</button>}
            {bot && !supported && !bot.enabled && <p className="integration-hint">请先升级服务端，再编辑或启用机器人。</p>}
          </div>}
        </form>
        {bot && <BotRuntimePanel initial={q.data?.runtime} supported={q.data?.runtime_supported === true} enabled={bot.enabled} />}
        <section className="bot-policy-section" aria-labelledby="bot-conditions-heading">
          <h3 id="bot-conditions-heading">自动参与条件</h3>
          <dl className="bot-conditions">
            <div><dt>自动评论服务</dt><dd className="integration-state" data-ready={q.data?.auto_reply_server_enabled}><Icon name={q.data?.auto_reply_server_enabled ? "check" : "clock"} size={16} />{q.data?.auto_reply_server_enabled ? "已开放" : "暂未开放"}</dd></div>
            <div><dt>助手评论授权</dt><dd className="integration-state" data-ready={q.data?.auto_reply_authorized}><Icon name={q.data?.auto_reply_authorized ? "check" : "clock"} size={16} />{q.data?.auto_reply_authorized ? "已授权" : "尚未授权"}</dd></div>
            <div><dt>自动发帖服务</dt><dd>{q.data?.auto_post_server_enabled ? "已开放" : "暂未开放"}</dd></div>
            <div><dt>助手发帖授权</dt><dd>{q.data?.auto_post_authorized ? "已授权" : "尚未授权"}</dd></div>
          </dl>
          <p className="integration-hint">自动评论和发帖都需要：这里开放对应功能 → 在「连接 AstrBot」批准对应权限 → 保存并启用机器人。AstrBot 也需开启自动浏览并配置模型。</p>
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


export function ConnectedApps() {
  const auth = useAuth();
  return (
    <IntegrationFrame title="已授权助手" subtitle="管理你的独立 AI 机器人，核对连接与参与权限。">
      {auth.user ? <AssistantWorkspace key={auth.user.id} nickname={auth.user.nickname} /> : <SignIn />}
    </IntegrationFrame>
  );
}
type AssistantView = "bot" | "connection" | "data";
function AssistantWorkspace({ nickname }: { nickname: string }) {
  const [params] = useSearchParams();
  const [view, setView] = useState<AssistantView>(params.get("user_code") ? "connection" : "bot");
  return <>
    <p className="integration-current-account">当前账号：{nickname}。机器人设置和连接授权都只作用于这个账号。</p>
    <section className="integration-guide" aria-label="机器人启用步骤">
      <h2>让机器人自动参与社区</h2>
      <ol><li><strong>1. 设置机器人</strong><span>选择允许的板块、评论、发帖与配图。</span></li><li><strong>2. 连接 AstrBot</strong><span>核对设备代码，批准执行端所需的权限。</span></li><li><strong>3. 启用并检查</strong><span>回到机器人设置启用，查看浏览与发言记录。</span></li></ol>
      <p>密码验证只确认操作人；授权不会自动启用机器人。成绩、二课和签到都是可选功能，自动发帖不需要它们。</p>
    </section>
    <nav className="integration-views" aria-label="助手管理分区">
      {([["bot", "机器人设置与运行"], ["connection", "连接 AstrBot"], ["data", "个人资料同步"]] as const).map(([key, title]) => <button key={key} className="btn" type="button" aria-pressed={view === key} aria-controls={`assistant-${key}`} onClick={() => setView(key)}>{title}</button>)}
    </nav>
    <div id="assistant-bot" hidden={view !== "bot"}><BotPanel active={view === "bot"} onConnect={() => setView("connection")} /></div>
    <ConnectionPanel nickname={nickname} view={view} onBot={() => setView("bot")} />
  </>;
}
function ConnectionPanel({ nickname, view, onBot }: { nickname: string; view: AssistantView; onBot: () => void }) {
  const queryClient = useQueryClient();
  const lookupVersion = useRef(0);
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
  const personalSelected = selected.some(scope => scope === "academic:grades:read" || scope === "academic:erke:read");
  const personalBlocked = personalSelected && (!!q.error || q.isFetching || q.data?.personal_data_enabled !== true);
  const canSelectBotScopes = !!consent && [...botScopeDependencies, "community:bot_reply", "community:bot_post"].every(scope => consent.requested_scopes.includes(scope));
  const authorizationProblems: string[] = [];
  if (!checked) authorizationProblems.push("请先核对设备代码与当前账号，并勾选外发范围确认。");
  if (!selected.length) authorizationProblems.push("请至少选择一项本次请求的权限。");
  if ((selected.includes("community:bot_post") || selected.includes("community:bot_reply")) && !selected.includes("community:propose"))
    authorizationProblems.push("自主评论或发帖还需要单独勾选「创建待本人确认的帖子或评论草稿」。");
  if (selected.includes("community:propose") && (!selected.includes("community:read") || !selected.includes("actions:read_own")))
    authorizationProblems.push("创建草稿还需要勾选「公开帖子与评论」及「本授权创建的草稿与发布结果」。");
  if (personalBlocked) authorizationProblems.push("成绩或二课的服务状态尚未确认，或服务未开放。请重新检查授权条件；也可取消成绩、二课权限，仅授权其他功能。");
  if (consent?.existing_binding && !replace) authorizationProblems.push("已有有效连接，请核对并勾选替换旧授权。");
  async function lookup(preserveSelection = false) {
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
            (s) => !["community:propose", "checkin:write", "community:bot_reply", "community:bot_post", "academic:grades:read", "academic:erke:read"].includes(s),
          ),
        );
      }
    } catch (e) {
      if (current()) setMessage(explain(e));
    } finally {
      if (current()) setBusy(false);
    }
  }
  function selectBotScopes() {
    if (!canSelectBotScopes) return;
    setSelected(previous => [...new Set([...previous, ...botScopeDependencies, "community:bot_reply", "community:bot_post"])]);
  }
  async function decide(allow: boolean) {
    if (!consent) return;
    if (allow && (q.error || q.isFetching || q.data?.personal_data_enabled !== true) && selected.some(s => s === "academic:grades:read" || s === "academic:erke:read")) {
      setMessage("个人查询尚未开放或状态未确认，请先重新检查服务状态，或取消选择成绩、二课权限。"); return;
    }
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
        await queryClient.invalidateQueries({ queryKey: ["api", "/api/connected-apps/bot"] });
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
        await queryClient.invalidateQueries({ queryKey: ["api", "/api/connected-apps/bot"] });
      }
    } catch (e) {
      if (current()) setMessage(explain(e));
    } finally {
      if (current()) setBusy(false);
    }
  }
  return (
    <>
      <div id="assistant-connection" hidden={view !== "connection"} className="integration-connections">
      <section className="panel panel-pad integration-panel">
        <header className="integration-section-head"><Icon name="monitor" size={22} /><h2>核对连接请求</h2></header>
        <p className="integration-description">这一步把 AstrBot 连接到你管理的机器人。自动发帖请选择「机器人自动参与」中的相应权限；个人资料查询可以不选。</p>
        <p>
          授权账号：{nickname}。只为自己刚刚在 AstrBot
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
        {view === "connection" && <Problem message={message} onCancel={() => { setMessage(""); setSuccess("已取消密码验证。设备代码已保留，本次连接授权未提交。"); }} onVerified={async () => {
          setMessage("");
          if (code.trim()) await lookup(true);
          else await q.refetch();
        }} />}
        {success && <p className="integration-feedback integration-feedback--success" role="status">{success}</p>}
        {success.startsWith("已授权。") && <button className="btn primary" type="button" onClick={onBot}>去启用机器人并检查运行</button>}
        {consent && (
          <div>
            <h3>授权给 {consent.installation_name}</h3>
            <p>安装标识：{consent.installation_id}（名称和标识由插件提供）</p>
            <p>
              请与 AstrBot 中显示的代码 <strong>{consent.user_code}</strong>{" "}
              核对。请求有效至 {new Date(consent.expires_at).toLocaleString()}。
            </p>
            {canSelectBotScopes && <div className="integration-scope-shortcut"><button className="btn" type="button" disabled={busy} onClick={selectBotScopes}>选择自动评论和发帖所需权限</button><p className="integration-hint">仅补齐公开读取、草稿和独立机器人发言权限；不会勾选成绩、二课或签到，也不会立即授权。</p></div>}
            {[...scopeGroups, { title: "其他请求权限", hint: "请单独核对后选择。", scopes: consent.requested_scopes.filter(scope => !scopeGroups.some(group => group.scopes.includes(scope))) }].map(group => {
              const scopes = group.scopes.filter(scope => consent.requested_scopes.includes(scope));
              return scopes.length > 0 && <fieldset className="integration-scope-group" key={group.title} disabled={busy}>
                <legend>{group.title}</legend><p className="integration-hint">{group.hint}</p>
                {scopes.map((scope) => <div key={scope}>
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
              {scope === "community:propose" && <p className="integration-hint">这是生成内容的共同前置权限。单独勾选只会生成待确认草稿；另选下方自动评论／发帖后，才允许以独立机器人账号自动发布。</p>}
                </div>)}
              </fieldset>;
            })}
            {!consent.requested_scopes.includes("community:bot_post") && !consent.requested_scopes.includes("community:bot_reply") && <p className="integration-hint">这份连接请求未申请机器人自主评论或发帖。请在与机器人的私聊，或部署者已开放机器人授权的群内重新发送 /sylu-connect，再核对新请求。</p>}
            <p>
              获准读取的公开文字、作者昵称、互动统计和图片会交给你部署的
              AstrBot，可能继续发送至你选择的模型、记忆插件或部署者允许的群。SYLUlive
              无法收回已经外发的数据。本连接不提供站内私信、课表、学校密码或学校登录会话。
            </p>
            <p>成绩和二课为独立可选权限，默认不勾选。授权后按本人明确命令返回已同步数据，标明同步时间，不是学校实时查询。允许的用户、群及结果投递由机器人后台配置；在群内查询并确认展示，或在已配置直接展示的群明确查询，会向该群公开本人结果，群成员、后续群模型与记忆可能保存。绑定不会自动完成学校登录或数据同步。</p>
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
      </section>
      <section className="panel panel-pad integration-panel">
        <header className="integration-section-head"><Icon name="admin" size={22} /><h2>连接管理</h2></header>
        <button className="btn" disabled={q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在刷新连接列表…" : "刷新连接列表"}</button>
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
      <div id="assistant-data" hidden={view !== "data"}>
        <p className="integration-data-hint">这里供本人 QQ 查询使用，和机器人自动发帖分开。仅需自动参与社区时，无需同步成绩或二课。</p>
        <button className="btn" type="button" disabled={q.isFetching} onClick={() => void q.refetch()}>{q.isFetching ? "正在刷新个人查询状态…" : "刷新个人查询状态"}</button>
        <IntegrationPersonalSync enabled={q.error || q.isFetching ? undefined : q.data?.personal_data_enabled} refreshing={q.isFetching} onRefresh={() => void q.refetch()} />
      </div>
    </>
  );
}

export function ConnectedAction() {
  const auth = useAuth(),
    { id } = useParams();
  return (
    <IntegrationFrame title="确认助手草稿" action={<Link className="btn" to="/connected-apps">连接管理</Link>}>
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
