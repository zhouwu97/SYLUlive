import { test, expect, type Page } from "@playwright/test";

const required = ["community:read", "actions:read_own", "community:propose", "community:bot_reply", "community:bot_post"];
const oldScopes = ["profile:read_minimal", "content:read_own_public", "actions:read_own", "checkin:write"];
type FixtureOptions = {
  requested?: string[]; failedDecision?: boolean; failedScopes?: boolean;
  toggles?: Record<string, boolean>; recentDecision?: boolean; conflictScopes?: boolean;
};
async function fixture(page: Page, options: FixtureOptions = {}) {
  let scopes = oldScopes, state = "active", verified = false;
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  const binding = () => ({ binding_id: "binding-one", installation_name: "本机 AstrBot", installation_id: "install-one", state, scopes: scopes.join(" "), epoch: 1 });
  await page.route("**/api/**", async route => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (request.method() !== "GET") writes.push({ path, body: request.postDataJSON() });
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 991, nickname: "合成创建者", role: "user" } });
    if (path === "/api/connected-apps") return route.fulfill({ json: { bindings: [binding()], personal_data_enabled: false, ...options.toggles } });
    if (path === "/api/auth/reauthenticate") { verified = true; return route.fulfill({ json: { authenticated: true, user_id: 991 } }); }
    if (path === "/api/connected-apps/bot") return route.fulfill({ json: { bot: null, policy_supported: true, sections: [], auto_reply_server_enabled: true, auto_reply_authorized: scopes.includes("community:bot_reply"), auto_post_server_enabled: true, auto_post_authorized: scopes.includes("community:bot_post") } });
    if (path.endsWith("/lookup")) return route.fulfill({ json: { consent_id: "request-one", installation_name: "本机 AstrBot", installation_id: "install-one", user_code: "ABCD-1234", requested_scopes: options.requested || [...new Set([...oldScopes, ...required])], confirmation_nonce: "synthetic-nonce", expires_at: "2099-01-01T00:00:00Z", existing_binding: binding() } });
    if (path === "/api/connected-apps/binding-one/scopes") {
      if (options.failedScopes) return route.fulfill({ status: 503, json: { code: "integration_unavailable" } });
      if (options.conflictScopes) { state = "revoked"; return route.fulfill({ status: 409, json: { code: "binding_conflict" } }); }
      scopes = request.postDataJSON().scopes;
      return route.fulfill({ json: { binding: binding() } });
    }
    if (path.endsWith("/decision")) {
      if (options.failedDecision) return route.fulfill({ status: 503, json: { code: "integration_unavailable" } });
      if (options.recentDecision && !verified) return route.fulfill({ status: 403, json: { code: "recent_authentication_required" } });
      scopes = request.postDataJSON().scopes;
      return route.fulfill({ json: { binding: binding() } });
    }
    return route.fulfill({ status: 404, json: { code: "fixture_resource_unavailable" } });
  });
  return writes;
}

async function openRequest(page: Page) {
  await page.getByRole("region", { name: "当前连接状态" }).getByRole("button", { name: "管理连接", exact: true }).click();
  await page.getByRole("button", { name: "连接新的 AstrBot", exact: true }).click();
  await page.getByRole("textbox", { name: "一次性连接码", exact: true }).fill("ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
}

async function confirm(page: Page) {
  await page.getByLabel("我已核对连接码与当前账号，并了解外发范围", { exact: true }).check();
  await page.getByLabel(/撤销并替换已有授权/).check();
  await page.getByRole("button", { name: "授权此助手", exact: true }).click();
}

test("旧连接缺权限时补充授权直接原地修改，不重新连接", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  await page.getByRole("button", { name: "下一步：连接 AstrBot", exact: true }).click();
  const missing = page.locator(".connection-authorization-needed");
  await expect(missing).toContainText("公开社区浏览");
  await expect(missing).toContainText("机器人自动评论");
  await expect(missing).toContainText("机器人自动发帖");
  await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
  const editor = page.getByRole("group", { name: "修改连接权限" });
  await expect(editor).toContainText("无需重新连接");
  await expect(editor.getByLabel(/以独立AI机器人自动发帖/)).toBeChecked();
  await expect(editor.getByLabel(/以本人管理的独立AI机器人自动评论/)).toBeChecked();
  await expect(editor.getByLabel(/读取本人主动同步的成绩/)).not.toBeChecked();
  await expect(page.locator("#new-astrbot-connection")).toHaveCount(0);
  expect(writes).toHaveLength(0);
  await editor.getByRole("button", { name: "保存权限", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "权限已更新" })).toContainText("无需重新连接");
  await expect(page.locator(".connection-authorization-needed")).toHaveCount(0);
  expect(writes.map(value => value.path)).toEqual(["/api/connected-apps/binding-one/scopes"]);
  const update = writes[0].body;
  expect(update.expected_epoch).toBe(1);
  expect(update.scopes).toEqual(expect.arrayContaining([...required, ...oldScopes]));
  expect((update.scopes as string[]).some(scope => scope.startsWith("academic:"))).toBe(false);
});

test("修改权限可收回，依赖不满足时不能保存", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  await page.getByRole("button", { name: "下一步：连接 AstrBot", exact: true }).click();
  await page.getByRole("button", { name: "修改权限", exact: true }).click();
  const editor = page.getByRole("group", { name: "修改连接权限" });
  await editor.getByLabel(/以本人管理的独立AI机器人自动评论/).check();
  await expect(editor).toContainText("自动评论或发帖还需要勾选");
  await expect(editor.getByRole("button", { name: "保存权限", exact: true })).toBeDisabled();
  await editor.getByLabel(/以本人管理的独立AI机器人自动评论/).uncheck();
  await editor.getByLabel(/查看本人签到状态/).uncheck();
  await editor.getByRole("button", { name: "保存权限", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "权限已更新" })).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0].body.scopes).toEqual(oldScopes.filter(scope => scope !== "checkin:write"));
});

test("修改权限失败保留连接和所选权限", async ({ page }) => {
  await fixture(page, { failedScopes: true });
  await page.goto("./connected-apps");
  await page.getByRole("button", { name: "下一步：连接 AstrBot", exact: true }).click();
  await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
  const editor = page.getByRole("group", { name: "修改连接权限" });
  await editor.getByRole("button", { name: "保存权限", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("服务暂时不可用");
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("已连接 AstrBot");
  await expect(editor.getByLabel(/以独立AI机器人自动发帖/)).toBeChecked();
});

test("站点未开放的权限置灰且不预选，已持有的仍可保留", async ({ page }) => {
  const writes = await fixture(page, { toggles: { proposals_enabled: true, auto_reply_enabled: true, auto_post_enabled: false } });
  await page.goto("./connected-apps");
  await page.getByRole("button", { name: "下一步：连接 AstrBot", exact: true }).click();
  await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
  const editor = page.getByRole("group", { name: "修改连接权限" });
  const post = editor.getByLabel(/以独立AI机器人自动发帖/);
  await expect(post).not.toBeChecked();
  await expect(post).toBeDisabled();
  await expect(editor).toContainText("站点尚未开放此功能");
  await expect(editor.getByLabel(/以本人管理的独立AI机器人自动评论/)).toBeChecked();
  await editor.getByRole("button", { name: "保存权限", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "权限已更新" })).toBeVisible();
  expect(writes[0].body.scopes).not.toContain("community:bot_post");
  expect(writes[0].body.scopes).toContain("community:bot_reply");
});

test("同时打开权限编辑与新连接时，密码验证只继续触发验证的授权", async ({ page }) => {
  const writes = await fixture(page, { recentDecision: true });
  await page.goto("./connected-apps");
  await page.getByRole("button", { name: "下一步：连接 AstrBot", exact: true }).click();
  await page.getByRole("button", { name: "补充机器人授权", exact: true }).click();
  await openRequest(page);
  await confirm(page);
  await page.getByLabel("当前账号密码", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect(page.getByLabel("当前账号密码", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("group", { name: "修改连接权限" })).toBeVisible();
  expect(writes.some(value => value.path.endsWith("/scopes"))).toBe(false);
  expect(writes.filter(value => value.path.endsWith("/lookup")).length).toBe(2);
});

test("连接已变化时保存失败会刷新并关闭编辑区", async ({ page }) => {
  await fixture(page, { conflictScopes: true });
  await page.goto("./connected-apps");
  await page.getByRole("button", { name: "下一步：连接 AstrBot", exact: true }).click();
  await page.getByRole("button", { name: "修改权限", exact: true }).click();
  await page.getByRole("group", { name: "修改连接权限" }).getByRole("button", { name: "保存权限", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("连接状态已变化");
  await expect(page.getByRole("group", { name: "修改连接权限" })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("当前没有有效连接");
});

test("补齐并明确替换后才能去启用，不连带批准个人查询", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByRole("button", { name: "选择自动评论和发帖所需权限", exact: true }).click();
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toBeDisabled();
  await confirm(page);
  await expect(page.getByRole("button", { name: "去启用机器人并检查运行", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "补充机器人授权", exact: true })).toHaveCount(0);
  const decision = writes.find(value => value.path.endsWith("/decision"))!.body;
  expect(decision.replace_binding_id).toBe("binding-one");
  expect(decision.expected_epoch).toBe(1);
  expect(decision.scopes).toEqual(expect.arrayContaining(required));
  expect((decision.scopes as string[]).some(scope => scope.startsWith("academic:") || scope === "checkin:write")).toBe(false);
  expect(writes.some(value => value.path.endsWith("/revoke") || value.path.endsWith("/bot"))).toBe(false);
});

test("只批准读取仍提示缺权限，不把授权成功当成自动参与就绪", async ({ page }) => {
  await fixture(page, { requested: oldScopes });
  await page.goto("./connected-apps");
  await openRequest(page);
  await confirm(page);
  await expect(page.getByRole("status").filter({ hasText: "已授权。" })).toBeVisible();
  await expect(page.getByText("本次授权尚不足以自动评论或发帖。", { exact: false })).toBeVisible();
  await expect(page.getByRole("button", { name: "去启用机器人并检查运行", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "补充机器人授权", exact: true })).toBeVisible();
});

test("只申请评论也能启用已授权功能，发帖仍需另外批准", async ({ page }) => {
  await fixture(page, { requested: required.filter(scope => scope !== "community:bot_post") });
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByLabel("创建待本人确认的帖子或评论草稿", { exact: true }).check();
  await page.getByLabel(/以本人管理的独立AI机器人自动评论/).check();
  await confirm(page);
  await expect(page.getByRole("button", { name: "去启用机器人并检查运行", exact: true })).toBeVisible();
  await expect(page.locator(".connection-authorization-needed")).toContainText("尚未批准：机器人自动发帖");
});

test("补授权失败保留旧连接、选择和恢复入口", async ({ page }) => {
  await fixture(page, { failedDecision: true });
  await page.goto("./connected-apps");
  await openRequest(page);
  await page.getByRole("button", { name: "选择自动评论和发帖所需权限", exact: true }).click();
  await confirm(page);
  await expect(page.getByRole("alert")).toContainText("服务暂时不可用");
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("已连接 AstrBot");
  await expect(page.getByLabel(/以独立AI机器人自动发帖/)).toBeChecked();
  await expect(page.getByRole("button", { name: "去启用机器人并检查运行", exact: true })).toHaveCount(0);
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
    await page.getByRole("group", { name: "修改连接权限" }).screenshot({ path: test.info().outputPath(`supplement-${theme}.png`) });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}
