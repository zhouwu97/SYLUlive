import { store } from "./storage";

export type SchoolCredentials = { account: string; password: string; vpnPassword?: string };
function validCredentials(value: SchoolCredentials) {
  return value && typeof value.account === "string" && /^\d{8,20}$/.test(value.account) &&
    typeof value.password === "string" && value.password.length > 0 && value.password.length <= 1024 &&
    (value.vpnPassword === undefined || (typeof value.vpnPassword === "string" && value.vpnPassword.length > 0 && value.vpnPassword.length <= 1024));
}
export function credentialScope(origin: string, appUserId: number, provider: string) {
  return `school-credentials:${origin}:${appUserId}:${provider}`;
}
type Sealed = { iv: number[]; data: number[]; key: CryptoKey };
// 密钥不可导出并与密文一起保存在扩展自己的 IndexedDB；这是浏览器本机保护，
// 不宣称为操作系统凭据库。站点、消息桥和 content script 均不提供读取入口。
export async function saveCredentials(scope: string, value: SchoolCredentials) {
  if (!validCredentials(value)) throw new Error("学校凭据格式无效，请检查输入。");
  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(scope) }, key,
    new TextEncoder().encode(JSON.stringify({ account: value.account, password: value.password, ...(value.vpnPassword === undefined ? {} : { vpnPassword: value.vpnPassword }) })),
  );
  await store<Sealed>(scope, { key, iv: [...iv], data: [...new Uint8Array(data)] });
}
export async function loadCredentials(scope: string): Promise<SchoolCredentials | undefined> {
  const value = await store<Sealed>(scope);
  if (!value) return;
  let data: ArrayBuffer;
  try { data = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: new Uint8Array(value.iv), additionalData: new TextEncoder().encode(scope) },
    value.key, new Uint8Array(value.data),
  ); } catch { throw new Error("本机凭据无法解密，请清除后重新输入。"); }
  let credentials: SchoolCredentials;
  try { credentials = JSON.parse(new TextDecoder().decode(data)) as SchoolCredentials; }
  catch { throw new Error("本机凭据已损坏，请清除后重新输入。"); }
  if (!validCredentials(credentials))
    throw new Error("本机凭据已损坏，请清除后重新输入");
  return credentials;
}
export async function clearCredentials(scope: string) {
  await store(scope, undefined, true);
}
