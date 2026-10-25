import { expect, test } from "@playwright/test";

test("浏览器登录与过期恢复声明 Cookie 模式，脚本读取不到 HttpOnly 会话", async ({ page, context }) => {
  const observed: Array<{ path: string; transport?: string; cookie?: string }> = [];
  let protectedReads = 0;
  // 只访问本地夹具，防止 Vite 的默认代理连接生产账号服务。
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    const headers = await route.request().allHeaders();
    observed.push({ path, transport: headers["x-auth-transport"], cookie: headers.cookie });
    if (path === "/api/login" || path === "/api/refresh") {
      const payload = headers["x-auth-transport"] === "cookie" ? { user: { id: 991 } } : { token: "exposed-token", refresh_token: "exposed-refresh" };
      await route.fulfill({
        json: payload,
        headers: { "set-cookie": "jwt=fixture-session; HttpOnly; SameSite=Lax; Path=/api" },
      });
    } else if (path === "/api/auth-cookie-fixture") {
      await route.fulfill({ status: protectedReads++ === 0 ? 401 : 200, json: { ok: true } });
    } else {
      await route.fulfill({ status: 401, json: { error: "fixture logged out" } });
    }
  });
  await page.goto("./");
  const result = await page.evaluate(async (moduleURL) => {
    const api = await import(moduleURL);
    const login = await api.write("/api/login", { account: "fixture@example.com", password: "fixture-password" });
    const read = await api.request("/api/auth-cookie-fixture");
    return { login, read, visibleCookies: document.cookie };
  }, "/web/src/api.ts");
  expect(result.login).not.toHaveProperty("token");
  expect(result.login).not.toHaveProperty("refresh_token");
  expect(result.read).toEqual({ ok: true });
  expect(result.visibleCookies).not.toContain("fixture-session");
  const cookies = await context.cookies();
  expect(cookies.find((cookie) => cookie.name === "jwt")?.httpOnly).toBe(true);
  const authCalls = observed.filter((call) => ["/api/login", "/api/refresh", "/api/auth-cookie-fixture"].includes(call.path));
  expect(authCalls.every((call) => call.transport === "cookie")).toBe(true);
  expect(authCalls.some((call) => call.path === "/api/refresh" && call.cookie?.includes("fixture-session"))).toBe(true);
  expect(authCalls.filter((call) => call.path === "/api/auth-cookie-fixture")).toHaveLength(2);
});
