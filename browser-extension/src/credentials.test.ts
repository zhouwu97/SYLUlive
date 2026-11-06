import { afterEach, expect, it, vi } from "vitest";
const records = vi.hoisted(() => new Map<string, unknown>());
vi.mock("./storage", () => ({ store: vi.fn(async (key: string, value?: unknown, remove = false) => {
  if (remove) records.delete(key);
  else if (value !== undefined) records.set(key, structuredClone(value));
  return records.get(key);
}) }));
import { clearCredentials, credentialScope, loadCredentials, saveCredentials } from "./credentials";
afterEach(() => records.clear());
const scope = credentialScope("https://sylulive.online", 7, "erke");
const value = { account: "2099000001", password: "synthetic-erke-secret", vpnPassword: "synthetic-vpn-secret" };
it("保存双密码密文、不可导出密钥，重读可恢复；明文不落库", async () => {
  await saveCredentials(scope, value);
  const stored = records.get(scope) as { key: CryptoKey };
  expect(JSON.stringify(stored)).not.toContain(value.password);
  expect(JSON.stringify(stored)).not.toContain(value.vpnPassword);
  await expect(crypto.subtle.exportKey("raw", stored.key)).rejects.toThrow();
  await expect(loadCredentials(scope)).resolves.toEqual(value);
  await clearCredentials(scope);
  await expect(loadCredentials(scope)).resolves.toBeUndefined();
});
it("站点、账号、学校系统隔离，挪用密文不能解密", async () => {
  await saveCredentials(scope, value);
  for (const other of [credentialScope("http://127.0.0.1:5173", 7, "erke"), credentialScope("https://sylulive.online", 8, "erke"), credentialScope("https://sylulive.online", 7, "undergraduate")]) {
    await expect(loadCredentials(other)).resolves.toBeUndefined();
    records.set(other, records.get(scope));
    await expect(loadCredentials(other)).rejects.toThrow();
  }
});

it("无效输入不能覆盖旧凭据，密文损坏给出可清除的提示", async () => {
  await saveCredentials(scope, value);
  await expect(saveCredentials(scope, {...value,password:42 as unknown as string})).rejects.toThrow('格式无效');
  await expect(loadCredentials(scope)).resolves.toEqual(value);
  const sealed=records.get(scope) as {data:number[]};sealed.data[0]^=1;
  await expect(loadCredentials(scope)).rejects.toThrow('无法解密');
  expect(records.has(scope)).toBe(true);
  await clearCredentials(scope);
  await expect(loadCredentials(scope)).resolves.toBeUndefined();
});
