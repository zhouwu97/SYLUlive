import {
  BRIDGE_CHANNEL,
  BridgeFailure,
  PROTOCOL_VERSION,
  capabilities as contractCapabilities,
  isBridgeRequest,
  isProvider,
  parseBackup,
  providers as contractProviders,
  type AcademicConnection,
  type AcademicDataset,
  type AcademicProvider,
  type AcademicSnapshot,
  type AcademicTerm,
  type BridgeErrorCode,
  type BridgeRequest,
  type BridgeResponse,
  assistantLoginMessages,
  type AssistantLoginPhase,
} from "@sylulive/academic-contracts";
import { identity, fetchDataset, origins } from "./school";
import { store, clearPrefix } from "./storage";
import { installReminders, removeSchedule, removeOriginSchedules, type ReminderConfig } from './reminders';
import { installSelfHealingInjection } from './inject';
import { pickHelloConnections } from "./hello";
import { assertFlowOwner, cancelLoginFlows, readLoginFlow, writeLoginFlow, isAssistantTab, loginFlowTtl, type LoginFlow } from "./login-flow";
import { credentialScope, clearCredentials, saveCredentials, type SchoolCredentials } from "./credentials";
import {storeBuild} from './build-flavor';
const capabilities = contractCapabilities.filter(value => !storeBuild || value.provider !== 'physical');
const providers = contractProviders.filter(value => !storeBuild || value !== 'physical');
installReminders();
installSelfHealingInjection();
type Connection = AcademicConnection & { origin: string; confirmed: boolean };
// 必须是带显式 never 返回类型的函数声明：箭头函数常量不会让 if (!x) fail(...)
// 之后的代码被收窄，identity 与连接对象的类型保护会整片失效。
function fail(code: BridgeErrorCode, message: string): never {
  throw new BridgeFailure(code, message);
}
const controllers = new Map<
  string,
  { controller: AbortController; key: string }
>();
const keyLocks = new Map<string, Promise<unknown>>();
const cancelledRequests = new Set<string>();
const siteOrigins = new Set(
  chrome.runtime
    .getManifest()
    .host_permissions?.map((x: string) => new URL(x).origin),
);
const connectionKey = (origin: string, provider: AcademicProvider) =>
  `connection:${origin}:${provider}`;
const response = (
  request: BridgeRequest,
  result?: unknown,
  error?: unknown,
): BridgeResponse => ({
  channel: BRIDGE_CHANNEL,
  direction: "response",
  version: PROTOCOL_VERSION,
  id: request.id,
  ok: error === undefined,
  result,
  error:
    error === undefined
      ? undefined
      : {
          code: error instanceof BridgeFailure ? error.code : "failed",
          message: error instanceof Error ? error.message : "学校查询失败",
        },
});
async function account(origin: string) {
  const res = await fetch(`${origin}/api/user/profile`, {
    credentials: "include",
    cache: "no-store",
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) fail("site_login_required", "请先登录沈理校园");
  const value = await res.json();
  if (!Number.isInteger(value.id) || value.id < 1)
    fail("site_login_required", "无法核对沈理校园账号");
  return value.id as number;
}
async function get(key: string) {
  return (await chrome.storage.session.get(key))[key] as Connection | undefined;
}
async function withKeyLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const previous = keyLocks.get(key) || Promise.resolve();
  let run!: Promise<T>;
  run = previous.then(fn);
  const queued = run.catch(() => undefined);
  keyLocks.set(key, queued);
  try {
    return await run;
  } finally {
    if (keyLocks.get(key) === queued) keyLocks.delete(key);
  }
}
async function revokeUnlocked(key: string, clearData = true) {
  for (const entry of controllers.values())
    if (entry.key === key) entry.controller.abort();
  const connection = await get(key);
  if (connection && clearData) {
    await clearPrefix(cachePrefix(connection));
    await removeSchedule(connection.origin, connection.appUserId);
  }
  await chrome.storage.session.remove([key, `latest:${key}`]);
}
async function revoke(key: string, clearData = true) {
  return withKeyLock(key, () => revokeUnlocked(key, clearData));
}
function cachePrefix(connection: Connection) {
  return `${connection.origin}:${connection.appUserId}:${connection.provider}:${connection.studentId}:`;
}
function snapshotKey(connection: Connection, dataset: string, term: AcademicTerm) {
  return `${cachePrefix(connection)}${dataset}:${term.year}:${term.semester}:${term.providerTermId || ''}`;
}
async function handle(request: BridgeRequest, origin: string, tabId: number) {
  const p = request.payload;
  if (storeBuild && p.provider === 'physical') fail('unsupported_query', '商店版不提供明文体测连接');
  if (request.operation === "hello") {
    // 连接快照读本机 session 存储、授权状态读 chrome.permissions，都是本地调用，
    // 页面因此可以反复复检而不产生网络代价。epoch 只交给同 origin 的页面，
    // 且 query 仍会重新核对 appUserId 与新鲜学校身份，不构成新的权限面。
    const [stored, granted] = await Promise.all([
      chrome.storage.session.get(null),
      Promise.all(
        providers.map((x) =>
          chrome.permissions.contains({ origins: [`${origins[x]}/*`] }),
        ),
      ),
    ]);
    return {
      version: PROTOCOL_VERSION,
      extensionVersion: chrome.runtime.getManifest().version,
      capabilities,
      automaticLogin: true,
      connections: pickHelloConnections(stored, origin).filter(value => !storeBuild || value.provider !== 'physical'),
      authorized: Object.fromEntries(
        providers.map((x, i) => [x, granted[i] === true]),
      ) as Partial<Record<AcademicProvider, boolean>>,
    };
  }
  if (request.operation === "cancel") {
    if (typeof p.requestId === "string" && p.requestId.length <= 80) {
      controllers.get(`${tabId}:${p.requestId}`)?.controller.abort();
      const requestKey = `${tabId}:${p.requestId}`;
      cancelledRequests.add(requestKey);
      setTimeout(() => cancelledRequests.delete(requestKey), 60_000);
    }
    // connect 可能已在网页取消前返回、但其响应尚未送达。任务也按原请求 ID
    // 失效，避免关闭弹窗那一瞬间仍留下可自动填写密码的旧助手任务。
    const stored = await chrome.storage.session.get(null);
    for (const [id, value] of Object.entries(stored)) {
      if (!id.startsWith("login-flow:")) continue;
      const flow = value as LoginFlow;
      if (flow.origin !== origin || flow.returnTabId !== tabId ||
          !((typeof p.requestId === "string" && flow.requestId === p.requestId) || flow.flowId === p.flowId)) continue;
      await withKeyLock(connectionKey(origin, flow.provider), async () => {
        const latest = (await chrome.storage.session.get(id))[id] as LoginFlow | undefined;
        if (latest) await writeLoginFlow({ ...latest, state: "cancelled" });
      });
    }
    return { cancelled: true };
  }
  if (request.operation === 'window' || request.operation === 'reminders') {
    const appUserId = await account(origin);
    if (request.operation === 'reminders' && p.enabled === false) {
      await removeSchedule(origin, appUserId);
      return {enabled:false};
    }
    const backup = parseBackup(JSON.stringify(p.data));
    const minutes = p.minutes === undefined ? 10 : Number(p.minutes);
    if (!Number.isInteger(minutes) || minutes < 0 || minutes > 120) fail('invalid_argument', '提前提醒时间应为 0 至 120 分钟');
    const data = {termStart:backup.termStart,courses:backup.courses,overrides:backup.overrides,exams:backup.exams};
    const id = crypto.randomUUID();
    const config: ReminderConfig = {origin,appUserId,data,minutes};
    await chrome.storage.session.set({[`schedule:${id}`]:config});
    const url = chrome.runtime.getURL(`schedule.html?id=${id}&mode=${request.operation}`);
    if (request.operation === 'window') await chrome.windows.create({url,type:'popup',width:420,height:620});
    else await chrome.tabs.create({url});
    return {state:request.operation === 'window' ? 'opened' : 'awaiting_permission'};
  }
  if (!isProvider(p.provider)) fail("invalid_argument", "请选择学校系统");
  const provider = p.provider,
    key = connectionKey(origin, provider);
  if (request.operation === "disconnect") {
    if (p.localOnly === true) {
      if (!Number.isSafeInteger(p.appUserId) || Number(p.appUserId) < 1) fail("invalid_argument", "本机退出账号无效");
      const owner = Number(p.appUserId);
      // 站点 logout 已撤销 Cookie，此处只取消本人本机任务和资料，不再请求账号
      // 接口，也不删除本人曾明确保存的自动登录凭据。
      await withKeyLock(key, async () => {
        await cancelLoginFlows(origin, provider, owner);
        const current = await get(key);
        if (current?.appUserId === owner) await revokeUnlocked(key);
      });
      await removeSchedule(origin, owner);
      return { disconnected: true };
    }
    const owner = await account(origin);
    await withKeyLock(key, async () => {
      await cancelLoginFlows(origin, provider);
      await clearCredentials(credentialScope(origin, owner, provider));
      await revokeUnlocked(key);
    });
    // 本地手动课表也可以启用提醒，没有学校连接时同样清理。
    await removeOriginSchedules(origin);
    return { disconnected: true };
  }
  const appUserId = await account(origin);
  const old = await get(key);
  if (old && old.appUserId !== appUserId) await revoke(key);
  if (request.operation === "connect") {
    const requestKey = `${tabId}:${request.id}`;
    if (cancelledRequests.has(requestKey)) fail("connection_stale", "登录任务已取消");
    if (provider === "physical") {
      await chrome.tabs.create({ url: chrome.runtime.getURL(`assistant.html?provider=${provider}`) });
      return { state: "awaiting_login" };
    }
    await revoke(key, false);
    return withKeyLock(key, async () => {
      await cancelLoginFlows(origin, provider);
      const flow: LoginFlow = {
        flowId: crypto.randomUUID(), state: "awaiting_login", origin, appUserId,
        provider, returnTabId: tabId, expiresAt: Date.now() + loginFlowTtl,
        requestId: request.id,
      };
      await writeLoginFlow(flow);
      const tab = await chrome.tabs.create({ url: "about:blank" });
      // 先绑定标签 ID 再载入助手页，避免初始化消息抢先于会话写入。
      await writeLoginFlow({ ...flow, assistantTabId: tab.id });
      await chrome.tabs.update(tab.id!, { url: chrome.runtime.getURL(`assistant.html?provider=${provider}&flow=${flow.flowId}`) });
      if (cancelledRequests.has(requestKey)) {
        await writeLoginFlow({ ...flow, assistantTabId: tab.id, state: "cancelled" });
        fail("connection_stale", "登录任务已取消");
      }
      return { state: "awaiting_login", flowId: flow.flowId };
    });
  }
  if (request.operation === "loginStatus") {
    const flow = await readLoginFlow(p.flowId, true);
    assertFlowOwner(flow, origin, appUserId, tabId, provider);
    if (flow.expiresAt < Date.now()) fail("connection_stale", "登录任务已过期，请重新连接");
    if (flow.state === "cancelled") return { flowId: flow.flowId, state: "cancelled" };
    const expectedAssistantUrl = chrome.runtime.getURL(`assistant.html?provider=${provider}&flow=${flow.flowId}`);
    const assistantExists = flow.assistantTabId !== undefined && await chrome.tabs.get(flow.assistantTabId).then(tab => isAssistantTab(flow, tab, expectedAssistantUrl), () => false);
    if (p.cancel === true || (flow.state === "awaiting_login" && !assistantExists)) {
      await withKeyLock(key, async () => {
        const latest = await readLoginFlow(flow.flowId);
        await writeLoginFlow({ ...latest, state: "cancelled" });
      });
      return { flowId: flow.flowId, state: "cancelled" };
    }
    return { flowId: flow.flowId, state: flow.state, phase: flow.phase };
  }
  if (
    !(await chrome.permissions.contains({
      origins: [`${origins[provider]}/*`],
    }))
  )
    fail("authorization_required", "请在助手页面授予学校域名权限");
  if (request.operation === "session") {
    const startedEpoch = old?.appUserId === appUserId ? old.epoch : "";
    const current = await identity(provider);
    if (old && old.studentId !== current.studentId) await revoke(key);
    const connection: Connection = {
      appUserId,
      provider,
      ...current,
      state: "connected",
      epoch: crypto.randomUUID(),
      connectedAt: new Date().toISOString(),
      origin,
      // 身份由助手直接从当前学校会话读取，网页不再重复要求用户确认学号。
      confirmed: true,
    };
    return withKeyLock(key, async () => {
      const latest = await get(key);
      if ((startedEpoch && latest?.epoch !== startedEpoch) || (!startedEpoch && latest))
        fail("connection_stale", "连接已改变，请重新连接");
      if (latest && latest.appUserId !== appUserId)
        fail("connection_stale", "连接已被其他账号接管，请重新连接");
      await chrome.storage.session.set({ [key]: connection });
      return connection;
    });
  }
  if (request.operation === "confirm") {
    const pending = await get(key);
    if (
      !pending ||
      pending.epoch !== p.epoch ||
      pending.appUserId !== appUserId
    )
      fail("connection_stale", "连接已改变，请重新核对身份");
    const current = await identity(provider);
    if (current.studentId !== pending.studentId) {
      await revoke(key);
      fail("identity_changed", "学校账号发生变化，请重新确认");
    }
    return withKeyLock(key, async () => {
      // 身份读取在锁外进行，提交前必须重新确认连接仍是同一世代；
      // disconnect 或新账号接管后，旧 confirm 只能失败，不能恢复连接。
      const latest = await get(key);
      if (
        !latest ||
        latest.epoch !== pending.epoch ||
        latest.appUserId !== appUserId
      )
        fail("connection_stale", "连接已改变，请重新核对身份");
      await chrome.storage.session.set({
        [key]: { ...latest, confirmed: true },
      });
      return { ...latest, confirmed: true };
    });
  }
  if (request.operation === 'persistence' || request.operation === 'cache') {
    const connection = await get(key);
    if (!connection?.confirmed || connection.appUserId !== appUserId || connection.epoch !== p.epoch) fail('connection_stale', '请先确认教务身份');
    const current = await identity(provider);
    if (current.studentId !== connection.studentId) { await revoke(key); fail('identity_changed', '学校身份已变化'); }
    const preference = `save:${cachePrefix(connection)}`;
    if (request.operation === 'persistence') {
      const enabled = p.enabled === true;
      return withKeyLock(key, async () => {
        const latest = await get(key);
        if (!latest?.confirmed || latest.appUserId !== appUserId || latest.epoch !== connection.epoch)
          fail('connection_stale', '连接已改变，请重新确认教务身份');
        await chrome.storage.local.set({[preference]: enabled});
        if (!enabled) await clearPrefix(cachePrefix(connection));
        return {enabled};
      });
    }
    if (typeof p.dataset !== 'string' || !p.term || typeof p.term !== 'object') fail('invalid_argument', '缓存参数无效');
    const cacheDataset = p.dataset;
    const cacheTerm = p.term as AcademicTerm;
    return withKeyLock(key, async () => {
      const latest = await get(key);
      if (!latest?.confirmed || latest.appUserId !== appUserId || latest.epoch !== connection.epoch)
        fail('connection_stale', '连接已改变，请重新确认教务身份');
      return await store(snapshotKey(connection, cacheDataset, cacheTerm)) || null;
    });
  }
  if (request.operation === "query") {
    const connected = await get(key);
    if (
      !connected?.confirmed ||
      connected.appUserId !== appUserId ||
      p.epoch !== connected.epoch
    )
      fail("connection_stale", "请先确认当前教务身份");
    const dataset = p.dataset as AcademicDataset;
    if (
      !capabilities
        .find((x) => x.provider === provider)
        ?.datasets.includes(dataset)
    )
      fail("unsupported_query", "学校系统不支持此查询");
    const term = p.term as AcademicTerm;
    if (
      !term ||
      typeof term.year !== "string" ||
      typeof term.semester !== "string"
    )
      fail("invalid_argument", "请选择有效学期");
    const id = `${tabId}:${request.id}`,
      controller = new AbortController();
    controllers.set(id, { controller, key });
    try {
      const before = await identity(provider, controller.signal);
      if (before.studentId !== connected.studentId) {
        await revoke(key);
        fail("identity_changed", "学校身份变化，请重新连接");
      }
      const data = await fetchDataset(
        provider,
        dataset,
        term,
        controller.signal,
      );
      const after = await identity(provider, controller.signal),
        latest = await get(key);
      const accountStillMatches = (await account(origin)) === appUserId;
      if (
        controller.signal.aborted ||
        latest?.epoch !== connected.epoch ||
        after.studentId !== connected.studentId ||
        !accountStillMatches
      ) {
        if (latest?.epoch === connected.epoch) await revoke(key);
        fail("connection_stale", "连接已失效，本次结果未保存");
      }
      const snapshot = {
        version: 1,
        provider,
        studentId: connected.studentId,
        dataset,
        term,
        fetchedAt: new Date().toISOString(),
        parserVersion: 1,
        data,
      } satisfies AcademicSnapshot;
      const preference = `save:${cachePrefix(connected)}`;
      await withKeyLock(key, async () => {
        const current = await get(key);
        if (current?.epoch !== connected.epoch || current.appUserId !== appUserId)
          fail('connection_stale', '连接已断开，本次结果未保存');
        if ((await chrome.storage.local.get(preference))[preference] === true) {
          await store(snapshotKey(connected, dataset, term), snapshot);
          if ((await get(key))?.epoch !== connected.epoch) {
            await clearPrefix(cachePrefix(connected));
            fail('connection_stale', '连接已断开，本次缓存已清除');
          }
        }
      });
      return snapshot;
    } finally {
      controllers.delete(id);
    }
  }
  fail("unsupported_query", "此功能尚未启用");
}
chrome.runtime.onMessage.addListener((message: unknown, sender, reply) => {
  if (message && typeof message === "object" && (message as { kind?: string }).kind === "assistant-login") {
    if (!sender.url || sender.frameId !== 0 || sender.tab?.id === undefined) return false;
    const url = new URL(sender.url);
    const assistantUrl = new URL(chrome.runtime.getURL("assistant.html"));
    if (url.protocol !== assistantUrl.protocol || url.host !== assistantUrl.host || url.pathname !== assistantUrl.pathname) return false;
    const input = message as { flowId?: unknown; action?: unknown; studentId?: unknown; credentials?: SchoolCredentials; phase?: AssistantLoginPhase };
    void (async () => {
      const flow = await readLoginFlow(input.flowId, input.action === "forget");
      if (flow.assistantTabId !== sender.tab!.id || url.searchParams.get("flow") !== flow.flowId)
        fail("connection_stale", "登录任务不属于当前助手页");
      if (input.action === "heartbeat" || input.action === "abandon") {
        await withKeyLock(connectionKey(flow.origin, flow.provider), async () => {
          const latest = await readLoginFlow(flow.flowId);
          if (latest.state === "awaiting_login") await writeLoginFlow({ ...latest,
            ...(input.action === "abandon" ? {state: "cancelled" as const} : {lastSeen: Date.now()}) });
        });
        return { origin: flow.origin, appUserId: flow.appUserId, provider: flow.provider };
      }
      if ((await account(flow.origin)) !== flow.appUserId)
        fail("connection_stale", "沈理校园账号已改变，请返回网站重新连接");
      const returnTab = await chrome.tabs.get(flow.returnTabId);
      if (!returnTab.url || new URL(returnTab.url).origin !== flow.origin)
        fail("connection_stale", "连接页面已关闭或离开本站");
      if (input.action === "forget") {
        await withKeyLock(connectionKey(flow.origin, flow.provider), async () => {
          await cancelLoginFlows(flow.origin, flow.provider, flow.appUserId);
          await clearCredentials(credentialScope(flow.origin, flow.appUserId, flow.provider));
        });
      } else if (input.action === "cancel") {
        await withKeyLock(connectionKey(flow.origin, flow.provider), async () => {
          const latest = await readLoginFlow(flow.flowId);
          await writeLoginFlow({ ...latest, state: "cancelled" });
        });
      } else if (input.action === "progress") {
        if (!input.phase || !Object.hasOwn(assistantLoginMessages, input.phase)) fail("invalid_argument", "登录进度无效");
        await withKeyLock(connectionKey(flow.origin, flow.provider), async () => {
          const latest = await readLoginFlow(flow.flowId);
          if (latest.state === "awaiting_login") await writeLoginFlow({ ...latest, phase: input.phase });
        });
      } else if (input.action === "complete") {
        const current = await identity(flow.provider);
        if (typeof input.studentId !== "string" || current.studentId !== input.studentId)
          fail("identity_changed", "学校账号发生变化，请重新连接");
        await withKeyLock(connectionKey(flow.origin, flow.provider), async () => {
          if ((await account(flow.origin)) !== flow.appUserId)
            fail("connection_stale", "沈理校园账号已改变，请重新连接");
          const latest = await readLoginFlow(flow.flowId);
          if (input.credentials) {
            const c = input.credentials;
            if (!["undergraduate", "erke"].includes(flow.provider) || c.account !== current.studentId ||
                typeof c.password !== "string" || !c.password || c.password.length > 1024 ||
                (flow.provider === "erke" && (typeof c.vpnPassword !== "string" || !c.vpnPassword || c.vpnPassword.length > 1024)))
              fail("invalid_argument", "保存凭据与本次学校身份不匹配");
            await saveCredentials(credentialScope(flow.origin, flow.appUserId, flow.provider), c);
          }
          await writeLoginFlow({ ...latest, state: "ready" });
        });
        await chrome.tabs.update(flow.returnTabId, { active: true });
        await chrome.windows.update(returnTab.windowId, { focused: true });
      } else if (input.action !== "context") fail("invalid_argument", "登录操作无效");
      return { origin: flow.origin, appUserId: flow.appUserId, provider: flow.provider };
    })().then(result => reply({ ok: true, result })).catch(error => reply({ ok: false, code: error instanceof BridgeFailure ? error.code : "failed", message: error instanceof Error ? error.message : "连接失败" }));
    return true;
  }
  if (
    !isBridgeRequest(message) ||
    sender.frameId !== 0 ||
    sender.tab?.id === undefined ||
    !sender.url
  )
    return false;
  const origin = new URL(sender.url).origin;
  if (!siteOrigins.has(origin)) return false;
  handle(message, origin, sender.tab.id)
    .then((value) => reply(response(message, value)))
    .catch((error) => reply(response(message, undefined, error)));
  return true;
});
