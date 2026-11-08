import { describe, expect, it } from "vitest";
import { accountKey, sealPassword, unsealPassword } from "./login-history";

describe("本机登录密码保护", () => {
  it("账号首尾空格与邮箱大小写统一，密码保留原始字符", async () => {
    expect(accountKey("  Student@Example.com ")).toBe("student@example.com");
    const password = " 空格与emoji🔑 password ";
    const sealed = await sealPassword("student@example.com", password);
    expect(await unsealPassword("Student@Example.com", sealed)).toBe(password);
    expect(JSON.stringify({ iv: sealed.iv, data: sealed.data })).not.toContain(password);
  });
  it("密钥不可导出，并使用独立随机密钥与 IV", async () => {
    const a = await sealPassword("one", "synthetic-password"), b = await sealPassword("one", "synthetic-password");
    expect(a.key.extractable).toBe(false);
    await expect(crypto.subtle.exportKey("raw", a.key)).rejects.toThrow();
    expect(a.iv).not.toEqual(b.iv);
    expect(a.data).not.toEqual(b.data);
  });
  it("密文绑定账号，不能挪到其他账号或修改后回填", async () => {
    const sealed = await sealPassword("one", "synthetic-password");
    await expect(unsealPassword("two", sealed)).rejects.toThrow("无法读取");
    const data = [...sealed.data];
    data[0] ^= 1;
    await expect(unsealPassword("one", { ...sealed, data })).rejects.toThrow("无法读取");
  });
});
