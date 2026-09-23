import {
  BRIDGE_CHANNEL,
  PROTOCOL_VERSION,
  capabilities,
  isBridgeRequest,
  isProvider,
  parseBackup,
  type AcademicConnection,
  type AcademicDataset,
  type AcademicProvider,
  type AcademicSnapshot,
  type AcademicTerm,
  type BridgeRequest,
  type BridgeResponse,
} from "@sylulive/academic-contracts";
import { identity, fetchDataset, origins } from "./school";
import { store, clearPrefix } from "./storage";
import { installReminders, removeSchedule, removeOriginSchedules, type ReminderConfig } from './reminders';
installReminders();
type Connection = AcademicConnection & { origin: string; confirmed: boolean };
const controllers = new Map<
  string,
  { controller: AbortController; key: string }
>();
const keyLocks = new Map<string, Promise<unknown>>();
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
  error?: string,
): BridgeResponse => ({
  channel: BRIDGE_CHANNEL,
  direction: "response",
  version: PROTOCOL_VERSION,
  id: request.id,
  ok: !error,
  result,
  error: error ? { code: "academic_failed", message: error } : undefined,
});
async function account(origin: string) {
  const res = await fetch(`${origin}/api/user/profile`, {
    credentials: "include",
    cache: "no-store",
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error("请先登录沈理校园");
  const value = await res.json();
  if (!Number.isInteger(value.id) || value.id < 1)
    throw new Error("无法核对沈理校园账号");
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
  if (request.operation === "hello")
    return {
      version: PROTOCOL_VERSION,
      extensionVersion: chrome.runtime.getManifest().version,
      capabilities,
    };
  if (request.operation === "cancel") {
    controllers.get(`${tabId}:${p.requestId}`)?.controller.abort();
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
    if (!Number.isInteger(minutes) || minutes < 0 || minutes > 120) throw new Error('提前提醒时间应为 0 至 120 分钟');
    const data = {termStart:backup.termStart,courses:backup.courses,overrides:backup.overrides,exams:backup.exams};
    const id = crypto.randomUUID();
    const config: ReminderConfig = {origin,appUserId,data,minutes};
    await chrome.storage.session.set({[`schedule:${id}`]:config});
    const url = chrome.runtime.getURL(`schedule.html?id=${id}&mode=${request.operation}`);
    if (request.operation === 'window') await chrome.windows.create({url,type:'popup',width:420,height:620});
    else await chrome.tabs.create({url});
    return {state:request.operation === 'window' ? 'opened' : 'awaiting_permission'};
  }
  if (!isProvider(p.provider)) throw new Error("请选择学校系统");
  const provider = p.provider,
    key = connectionKey(origin, provider);
  if (request.operation === "disconnect") {
    await revoke(key);
    // 本地手动课表也可以启用提醒，没有学校连接时同样清理。
    await removeOriginSchedules(origin);
    return { disconnected: true };
  }
  const appUserId = await account(origin);
  const old = await get(key);
  if (old && old.appUserId !== appUserId) await revoke(key);
  if (request.operation === "connect") {
    await revoke(key, false);
    await chrome.tabs.create({
      url: chrome.runtime.getURL(`assistant.html?provider=${provider}`),
    });
    return { state: "awaiting_login" };
  }
  if (
    !(await chrome.permissions.contains({
      origins: [`${origins[provider]}/*`],
    }))
  )
    throw new Error("请在助手页面授予学校域名权限");
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
        throw new Error("连接已改变，请重新连接");
      if (latest && latest.appUserId !== appUserId)
        throw new Error("连接已被其他账号接管，请重新连接");
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
      throw new Error("连接已改变，请重新核对身份");
    const current = await identity(provider);
    if (current.studentId !== pending.studentId) {
      await revoke(key);
      throw new Error("学校账号发生变化，请重新确认");
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
        throw new Error("连接已改变，请重新核对身份");
      await chrome.storage.session.set({
        [key]: { ...latest, confirmed: true },
      });
      return { ...latest, confirmed: true };
    });
  }
  if (request.operation === 'persistence' || request.operation === 'cache') {
    const connection = await get(key);
    if (!connection?.confirmed || connection.appUserId !== appUserId || connection.epoch !== p.epoch) throw new Error('请先确认教务身份');
    const current = await identity(provider);
    if (current.studentId !== connection.studentId) { await revoke(key); throw new Error('学校身份已变化'); }
    const preference = `save:${cachePrefix(connection)}`;
    if (request.operation === 'persistence') {
      const enabled = p.enabled === true;
      return withKeyLock(key, async () => {
        const latest = await get(key);
        if (!latest?.confirmed || latest.appUserId !== appUserId || latest.epoch !== connection.epoch)
          throw new Error('连接已改变，请重新确认教务身份');
        await chrome.storage.local.set({[preference]: enabled});
        if (!enabled) await clearPrefix(cachePrefix(connection));
        return {enabled};
      });
    }
    if (typeof p.dataset !== 'string' || !p.term || typeof p.term !== 'object') throw new Error('缓存参数无效');
    const cacheDataset = p.dataset;
    const cacheTerm = p.term as AcademicTerm;
    return withKeyLock(key, async () => {
      const latest = await get(key);
      if (!latest?.confirmed || latest.appUserId !== appUserId || latest.epoch !== connection.epoch)
        throw new Error('连接已改变，请重新确认教务身份');
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
      throw new Error("请先确认当前教务身份");
    const dataset = p.dataset as AcademicDataset;
    if (
      !capabilities
        .find((x) => x.provider === provider)
        ?.datasets.includes(dataset)
    )
      throw new Error("学校系统不支持此查询");
    const term = p.term as AcademicTerm;
    if (
      !term ||
      typeof term.year !== "string" ||
      typeof term.semester !== "string"
    )
      throw new Error("请选择有效学期");
    const id = `${tabId}:${request.id}`,
      controller = new AbortController();
    controllers.set(id, { controller, key });
    try {
      const before = await identity(provider, controller.signal);
      if (before.studentId !== connected.studentId) {
        await revoke(key);
        throw new Error("学校身份变化，请重新连接");
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
        throw new Error("连接已失效，本次结果未保存");
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
          throw new Error('连接已断开，本次结果未保存');
        if ((await chrome.storage.local.get(preference))[preference] === true) {
          await store(snapshotKey(connected, dataset, term), snapshot);
          if ((await get(key))?.epoch !== connected.epoch) {
            await clearPrefix(cachePrefix(connected));
            throw new Error('连接已断开，本次缓存已清除');
          }
        }
      });
      return snapshot;
    } finally {
      controllers.delete(id);
    }
  }
  throw new Error("此功能尚未启用");
}
chrome.runtime.onMessage.addListener((message: unknown, sender, reply) => {
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
    .catch((error) =>
      reply(
        response(
          message,
          undefined,
          error instanceof Error ? error.message : "学校查询失败",
        ),
      ),
    );
  return true;
});
