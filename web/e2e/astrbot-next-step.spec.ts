import { test, expect, type Page } from "@playwright/test";

const required = ["community:read", "actions:read_own", "community:propose", "community:bot_reply", "community:bot_post"];
const oldScopes = ["profile:read_minimal", "content:read_own_public", "actions:read_own", "checkin:write"];
async function fixture(page: Page, options: { requested?: string[]; failedDecision?: boolean } = {}) {
  let scopes = oldScopes;
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  const binding = () => ({ binding_id: "binding-one", installation_name: "本机 AstrBot", installation_id: "install-one", state: "active", scopes: scopes.join(" "), epoch: 1 });
  await page.route("**/api/**", async route => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (request.method() !== "GET") writes.push({ path, body: request.postDataJSON() });
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 991, nickname: "合成创建者", role: "user" } });
    if (path === "/api/connected-apps") return route.fulfill({ json: { bindings: [binding()], personal_data_enabled: false } });
    if (path === "/api/connected-apps/bot") return route.fulfill({ json: { bot: null, policy_supported: true, sections: [], auto_reply_server_enabled: true, auto_reply_authorized: scopes.includes("community:bot_reply"), auto_post_server_enabled: true, auto_post_authorized: scopes.includes("community:bot_post") } });
    if (path.endsWith("/lookup")) return route.fulfill({ json: { consent_id: "request-one", installation_name: "本机 AstrBot", installation_id: "install-one", user_code: "ABCD-1234", requested_scopes: options.requested || [...new Set([...oldScopes, ...required, "academic:grades:read", "academic:erke:read"])], confirmation_nonce: "synthetic-nonce", expires_at: "2099-01-01T00:00:00Z", existing_binding: binding() } });
    if (path.endsWith("/decision")) {
      if (options.failedDecision) return route.fulfill({ status: 503, json: { code: "integration_unavailable" } });
      scopes = request.postDataJSON().scopes;
      return route.fulfill({ json: { binding: binding() } });
    }
    return route.fulfill({ status: 404, json: { code: "fixture_resource_unavailable" } });
  });
  return writes;
}

async function openRequest(page: Page) {
  await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
  await expect(page.getByRole("heading", { name: "核对连接请求", exact: true })).toBeFocused();
  await page.getByRole("textbox", { name: "设备代码", exact: true }).fill("ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
}

async function confirm(page: Page) {
  await page.getByLabel("我已核对设备代码与当前账号，并了解外发范围", { exact: true }).check();
  await page.getByLabel(/撤销并替换已有授权/).check();
  await page.getByRole("button", { name: "授权此助手", exact: true }).click();
}

test("旧连接缺权限时展示完整下一步，补充授权不撤销或自动提交", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  const missing = page.locator(".connection-authorization-needed");
  await expect(missing).toContainText("公开社区浏览");
  await expect(missing).toContainText("机器人自动评论");
  await expect(missing).toContainText("机器人自动发帖");
  await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
  const form = page.locator("#new-astrbot-connection");
  await expect(form).toContainText("/sylu-connect");
  await expect(form).toContainText("已有连接时勾选替换旧授权");
  await expect(form).toContainText("授权此助手");
  await expect(page.getByRole("heading", { name: "核对连接请求", exact: true })).toBeFocused();
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toHaveCount(0);
  expect(writes).toHaveLength(0);
});

test("补齐并明确替换后才提示启用步骤，不连带批准个人查询", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByRole("button", { name: "选择自动评论和发帖所需权限", exact: true }).click();
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toBeDisabled();
  await confirm(page);
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toBeVisible();
  await expect(page.locator(".connection-authorization-needed")).toHaveCount(0);
  const decision = writes.find(value => value.path.endsWith("/decision"))!.body;
  expect(decision.replace_binding_id).toBe("binding-one");
  expect(decision.expected_epoch).toBe(1);
  expect(decision.scopes).toEqual(expect.arrayContaining(required));
  expect((decision.scopes as string[]).some(scope => scope.startsWith("academic:") || scope === "checkin:write" || scope === "profile:read_minimal")).toBe(false);
  expect(writes.some(value => value.path.endsWith("/revoke") || value.path.endsWith("/bot"))).toBe(false);
});

test("只批准读取仍提示缺权限，不把授权成功当成自动参与就绪", async ({ page }) => {
  await fixture(page, { requested: oldScopes });
  await page.goto("./connected-apps");
  await openRequest(page);
  await confirm(page);
  await expect(page.getByRole("status").filter({ hasText: "已授权。" })).toBeVisible();
  await expect(page.getByText("本次授权尚不足以自动评论或发帖。", { exact: false })).toBeVisible();
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "补充机器人授权", exact: true })).toBeVisible();
});

test("只申请评论也提示已授权功能的下一步，发帖仍需另外批准", async ({ page }) => {
  await fixture(page, { requested: required.filter(scope => scope !== "community:bot_post") });
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByLabel("创建待本人确认的帖子或评论草稿", { exact: true }).check();
  await page.getByLabel(/以本人管理的独立AI机器人自动评论/).check();
  await confirm(page);
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toBeVisible();
  await expect(page.locator(".connection-authorization-needed")).toContainText("尚未批准：机器人自动发帖");
});

test("补授权失败保留旧连接、选择和恢复入口", async ({ page }) => {
  await fixture(page, { failedDecision: true });
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByRole("button", { name: "选择自动评论和发帖所需权限", exact: true }).click();
  await confirm(page);
  await expect(page.getByRole("alert")).toContainText("服务暂时不可用");
  await expect(page.locator(".list-row").filter({ hasText: "本机 AstrBot" })).toContainText("有效");
  await expect(page.getByLabel(/以独立AI机器人自动发帖/)).toBeChecked();
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toHaveCount(0);
});

test("编辑连接码后，较早的查询结果不能恢复旧授权表单", async ({ page }) => {
  await fixture(page);
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/device-requests/lookup", async route => {
    await pending;
    await route.fulfill({ json: { consent_id: "old-request", installation_name: "过期页面的请求", installation_id: "install-one", user_code: "ABCD-1234", requested_scopes: required, confirmation_nonce: "synthetic-nonce", expires_at: "2099-01-01T00:00:00Z" } });
  });
  await page.goto("./connected-apps");
  await openRequest(page);
  const input = page.getByRole("textbox", { name: "设备代码", exact: true });
  await expect(page.getByRole("button", { name: "查看授权请求" })).toBeDisabled();
  await input.fill("NEW-CODE");
  const response = page.waitForResponse(value => value.url().endsWith("/lookup"));
  release();
  await response;
  await expect(page.getByRole("button", { name: "查看授权请求" })).toBeEnabled();
  await expect(page.getByRole("heading", { name: "授权给 过期页面的请求" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toHaveCount(0);
});

test("旧服务不支持新权限时说明升级入口，保留原授权和本次选择", async ({ page }) => {
  await fixture(page);
  await page.route("**/device-requests/*/decision", route => route.fulfill({ status: 400, json: { code: "invalid_scope" } }));
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByRole("button", { name: "选择自动评论和发帖所需权限" }).click();
  await confirm(page);
  await expect(page.getByRole("alert")).toContainText("请部署者核对插件和服务端版本");
  await expect(page.getByLabel(/以独立AI机器人自动发帖/)).toBeChecked();
  await expect(page.locator(".list-row").filter({ hasText: "本机 AstrBot" })).toContainText("有效");
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toHaveCount(0);
});

test("提交旧请求期间编辑连接码，旧响应不能覆盖新的连接步骤", async ({ page }) => {
  await fixture(page);
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/device-requests/*/decision", async route => {
    await pending;
    await route.fulfill({ json: { binding: { binding_id: "old-response" } } });
  });
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByRole("button", { name: "选择自动评论和发帖所需权限" }).click();
  await confirm(page);
  await page.getByRole("textbox", { name: "设备代码", exact: true }).fill("NEW-CODE");
  const response = page.waitForResponse(value => value.url().endsWith("/decision"));
  release();
  await response;
  await expect(page.getByText("自动参与所需授权已批准。", { exact: false })).toHaveCount(0);
  await expect(page.getByRole("status").filter({ hasText: "已授权。" })).toHaveCount(0);
  await expect(page.getByRole("textbox", { name: "设备代码", exact: true })).toHaveValue("NEW-CODE");
});

for (const [theme, width] of [["light", 1440], ["dark", 390]] as const) {
  test(`插件后台可直达并支持其他地址，无效地址不生成链接 ${theme}`, async ({ page }) => {
    const writes = await fixture(page);
    await page.setViewportSize({ width, height: 1000 });
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await page.goto("./connected-apps?user_code=ABCD-1234");
    const dashboard = page.getByRole("region", { name: "AstrBot 插件后台" });
    const link = dashboard.getByRole("link", { name: "打开 AstrBot 插件管理", exact: true });
    await expect(link).toHaveAttribute("href", "http://127.0.0.1:6185/#/plugin-view/astrbot_plugin_sylulive/permissions");
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");
    await dashboard.getByText("修改后台地址／打不开？", { exact: true }).click();
    const address = dashboard.getByLabel("AstrBot 后台地址", { exact: true });
    await address.fill("https://astrbot.example:8443");
    await expect(link).toHaveAttribute("href", "https://astrbot.example:8443/#/plugin-view/astrbot_plugin_sylulive/permissions");
    for (const invalid of ["javascript:alert(1)", "http://name:password@localhost:6185", "http://localhost:6185/?token=private", "not-a-url"]) {
      await address.fill(invalid);
      await expect(link).toHaveCount(0);
      await expect(dashboard.getByRole("alert")).toContainText("请填写完整");
    }
    await address.fill("http://127.0.0.1:6185");
    await expect(link).toBeVisible();
    expect(writes).toHaveLength(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await dashboard.screenshot({ path: test.info().outputPath(`dashboard-${theme}.png`) });
    await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
    await page.locator("#new-astrbot-connection").screenshot({ path: test.info().outputPath(`supplement-${theme}.png`) });
  });
}
