export const LOGIN_HISTORY_DB = "sylulive-login";
export const LOGIN_HISTORY_LIMIT = 5;
export const LOGIN_HISTORY_CHANNEL = "sylulive-login-history";

type SealedPassword = { key: CryptoKey; iv: number[]; data: number[] };
type StoredAccount = {
  key: string;
  account: string;
  nickname: string;
  userId?: number;
  email?: string;
  lastUsedAt: number;
  loginStartedAt: number;
  secret?: SealedPassword;
};
export type SavedAccount = Omit<StoredAccount, "secret" | "loginStartedAt"> & { hasPassword: boolean };

export function accountKey(account: string) {
  return account.trim().toLowerCase();
}

export function canRememberPassword() {
  try { return typeof indexedDB !== "undefined" && !!globalThis.crypto?.subtle; } catch { return false; }
}

function binding(account: string) {
  return new TextEncoder().encode(`sylulive-login:v1:${globalThis.location?.origin || "local"}:${accountKey(account)}`);
}

export async function sealPassword(account: string, password: string): Promise<SealedPassword> {
  if (!crypto.subtle) throw new Error("当前浏览器不支持保存密码");
  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: binding(account) }, key, new TextEncoder().encode(password));
  return { key, iv: [...iv], data: [...new Uint8Array(data)] };
}

export async function unsealPassword(account: string, secret: SealedPassword) {
  if (!secret.key || secret.key.extractable || secret.key.algorithm?.name !== "AES-GCM") throw new Error("保存的密码无法读取，请重新输入");
  try {
    const data = await crypto.subtle.decrypt({ name: "AES-GCM", iv: new Uint8Array(secret.iv), additionalData: binding(account) }, secret.key, new Uint8Array(secret.data));
    return new TextDecoder().decode(data);
  } catch { throw new Error("保存的密码无法读取，请重新输入"); }
}

let opening: Promise<IDBDatabase> | undefined;
function database(): Promise<IDBDatabase> {
  if (opening) return opening;
  const pending = new Promise<IDBDatabase>((resolve, reject) => {
    let settled = false;
    const fail = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error("本机账号记录暂不可用，仍可手动登录"));
    };
    const timer = setTimeout(fail, 1500);
    try {
      const request = indexedDB.open(LOGIN_HISTORY_DB, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains("accounts")) db.createObjectStore("accounts", { keyPath: "key" });
        if (!db.objectStoreNames.contains("settings")) db.createObjectStore("settings");
      };
      request.onerror = fail;
      request.onblocked = fail;
      request.onsuccess = () => {
        if (settled) { request.result.close(); return; }
        settled = true;
        clearTimeout(timer);
        const db = request.result;
        db.onversionchange = () => { db.close(); if (opening === pending) opening = undefined; };
        db.onclose = () => { if (opening === pending) opening = undefined; };
        resolve(db);
      };
    } catch { fail(); }
  });
  opening = pending;
  pending.catch(() => { if (opening === pending) opening = undefined; });
  return pending;
}

function transaction<T>(db: IDBDatabase, mode: IDBTransactionMode, run: (tx: IDBTransaction, done: (value: T) => void) => void, signal?: AbortSignal) {
  signal?.throwIfAborted();
  return new Promise<T>((resolve, reject) => {
    const tx = db.transaction(["accounts", "settings"], mode);
    let value: T;
    const abort = () => { try { tx.abort(); } catch {} };
    const clean = () => signal?.removeEventListener("abort", abort);
    tx.oncomplete = () => { clean(); resolve(value); };
    tx.onabort = tx.onerror = () => { clean(); reject(signal?.aborted ? new DOMException("操作已取消", "AbortError") : new Error("本机账号记录未能保存，请检查浏览器存储设置")); };
    signal?.addEventListener("abort", abort, { once: true });
    try { run(tx, result => { value = result; }); }
    catch (error) { abort(); clean(); reject(error); }
  });
}

function announceHistoryChange() {
  try {
    if (typeof BroadcastChannel === "undefined") return;
    const channel = new BroadcastChannel(LOGIN_HISTORY_CHANNEL);
    channel.postMessage("changed");
    channel.close();
  } catch {}
}

function validRecord(record: StoredAccount) {
  return record && typeof record.account === "string" && record.account.length <= 320 && record.key === accountKey(record.account) && record.key.length > 0;
}

export async function savedAccounts(): Promise<SavedAccount[]> {
  return transaction(await database(), "readonly", (tx, done) => {
    const request = tx.objectStore("accounts").getAll();
    request.onsuccess = () => done((request.result as StoredAccount[]).filter(validRecord).sort((a, b) => b.lastUsedAt - a.lastUsedAt).slice(0, LOGIN_HISTORY_LIMIT).map(record => ({ key: record.key, account: record.account, nickname: typeof record.nickname === "string" ? record.nickname.slice(0, 80) : "", userId: typeof record.userId === "number" ? record.userId : undefined, email: typeof record.email === "string" ? record.email : undefined, lastUsedAt: Number(record.lastUsedAt) || 0, hasPassword: !!record.secret })));
  });
}

export async function historyRevision(signal?: AbortSignal): Promise<number> {
  return transaction(await database(), "readonly", (tx, done) => {
    const request = tx.objectStore("settings").get("revision");
    request.onsuccess = () => done(Number(request.result) || 0);
  }, signal);
}

export async function savedPassword(key: string, signal?: AbortSignal) {
  const record = await transaction<StoredAccount | undefined>(await database(), "readonly", (tx, done) => {
    const request = tx.objectStore("accounts").get(key);
    request.onsuccess = () => done(request.result);
  }, signal);
  signal?.throwIfAborted();
  if (!record?.secret) return "";
  const password = await unsealPassword(key, record.secret);
  signal?.throwIfAborted();
  return password;
}

export async function rememberLogin(input: {
  account: string;
  password: string;
  nickname?: string;
  userId?: number;
  email?: string;
  rememberPassword: boolean;
  revision: number;
  loginStartedAt: number;
}, signal?: AbortSignal) {
  const account = input.account.trim(), key = accountKey(account);
  if (!key || account.length > 320 || /[\u0000-\u001f\u007f]/.test(account) || input.password.length > 1024) throw new Error("账号记录格式无效");
  const secret = input.rememberPassword ? await sealPassword(key, input.password) : undefined;
  signal?.throwIfAborted();
  const stored = await transaction<boolean>(await database(), "readwrite", (tx, done) => {
    const accounts = tx.objectStore("accounts");
    const request = tx.objectStore("settings").get("revision");
    request.onsuccess = () => {
      // 删除和清空优先于在途登录，不允许迟到的加密结果恢复用户刚移除的记录。
      if ((Number(request.result) || 0) !== input.revision) { done(false); return; }
      const existing = accounts.getAll();
      existing.onsuccess = () => {
        try {
        const previous = (existing.result as StoredAccount[]).filter(validRecord);
        if (previous.some(record => record.key === key && record.loginStartedAt > input.loginStartedAt)) { done(false); return; }
        const lastUsedAt = Math.max(Date.now(), ...previous.map(record => (Number(record.lastUsedAt) || 0) + 1));
        const record: StoredAccount = { key, account, nickname: input.nickname?.slice(0, 80) || "", userId: input.userId, email: input.email?.slice(0, 320), lastUsedAt, loginStartedAt: input.loginStartedAt, ...(secret ? { secret } : {}) };
        accounts.put(record);
        const retained = previous.filter(item => item.key !== key).sort((a, b) => b.lastUsedAt - a.lastUsedAt);
        retained.slice(LOGIN_HISTORY_LIMIT - 1).forEach(item => accounts.delete(item.key));
        done(true);
        } catch { tx.abort(); }
      };
    };
  }, signal);
  if (!stored) throw new Error("本机记录已在其他页面更新，本次未覆盖");
  announceHistoryChange();
}

async function changeHistory(change: (accounts: IDBObjectStore) => void) {
  await transaction<void>(await database(), "readwrite", (tx, done) => {
    const settings = tx.objectStore("settings"), revision = settings.get("revision");
    revision.onsuccess = () => { try { settings.put((Number(revision.result) || 0) + 1, "revision"); change(tx.objectStore("accounts")); done(); } catch { tx.abort(); } };
  });
  announceHistoryChange();
}

export async function removeSavedAccount(key: string) {
  await changeHistory(accounts => { accounts.delete(key); });
}

export async function clearSavedAccounts() {
  await changeHistory(accounts => { accounts.clear(); });
}

export async function forgetSavedPasswords(identity: { account?: string; userId?: number }) {
  await changeHistory(accounts => {
    const request = accounts.getAll();
    request.onsuccess = () => {
      try {
      for (const record of request.result as StoredAccount[]) {
        if ((identity.userId && record.userId === identity.userId) || (identity.account && (record.key === accountKey(identity.account) || accountKey(record.email || "") === accountKey(identity.account)))) {
          const { secret: _, ...rest } = record;
          accounts.put(rest);
        }
      }
      } catch { accounts.transaction.abort(); }
    };
  });
}
