import { test, expect, type Page } from "@playwright/test";

const active = { binding_id: "binding-one", installation_name: "本机 AstrBot · 示例平台", installation_id: "install-one", state: "active", scopes: "profile:read_minimal community:read actions:read_own community:propose community:bot_reply community:bot_post", epoch: 1 };
async function fixture(page: Page, options: { connected?: boolean; fail?: boolean } = {}) {
  let connected = options.connected !== false, fail = !!options.fail;
  const writes: string[] = [];
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() !== "GET") writes.push(path);
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 991, nickname: "示例创建者", role: "user" } });
    if (path === "/api/connected-apps") return fail
      ? route.fulfill({ status: 503, json: { code: "integration_unavailable" } })
      : route.fulfill({ json: { bindings: [...(connected ? [active] : []), { ...active, binding_id: "old-one", installation_name: "历史执行端", state: "revoked" }], personal_data_enabled: false } });
    if (path === "/api/connected-apps/binding-one/revoke") { connected = false; return route.fulfill({ json: { revoked: true } }); }
    if (path === "/api/connected-apps/device-requests/lookup") return route.fulfill({ json: {
      consent_id: "request-one", installation_name: active.installation_name, installation_id: active.installation_id,
      user_code: "ABCD-1234", requested_scopes: ["profile:read_minimal", "community:read", "actions:read_own"],
      confirmation_nonce: "synthetic-once-nonce", expires_at: "2099-01-01T00:00:00Z",
    } });
    if (path === "/api/connected-apps/device-requests/request-one/decision") { connected = true; return route.fulfill({ json: { binding: active } }); }
    if (path === "/api/connected-apps/bot") return route.fulfill({ json: { bot: null, policy_supported: true, sections: [], auto_reply_server_enabled: true, auto_reply_authorized: connected, auto_post_server_enabled: true, auto_post_authorized: connected } });
    return route.fulfill({ status: 404, json: { code: "fixture_resource_unavailable" } });
  });
  return { writes, recover: () => { fail = false; }, setFailed: (value: boolean) => { fail = value; } };
}

test("已连接时先给明确状态，不要求重复填代码，历史连接默认收起", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.goto("./connected-apps");
  const status = page.getByRole("region", { name: "当前连接状态" });
  await expect(status).toContainText("已连接 AstrBot");
  await expect(status).toContainText("示例创建者");
  await expect(status).toContainText("无需再填连接码");
  await status.getByRole("button", { name: "管理连接", exact: true }).click();
  await expect(page.getByRole("heading", { name: "当前有效连接", exact: true })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveCount(0);
  await expect(page.getByText("机器人自主评论", { exact: true })).toBeVisible();
  await expect(page.getByText("历史执行端", { exact: true })).not.toBeVisible();
  await page.getByText("历史连接（1）", { exact: true }).click();
  await expect(page.getByText("历史执行端", { exact: true })).toBeVisible();
  await page.getByText("历史连接（1）", { exact: true }).click();
  await expect(page.getByText("历史执行端", { exact: true })).not.toBeVisible();
  expect(writes).toHaveLength(0);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: test.info().outputPath("connected-state.png"), fullPage: true });
});

test("连接新执行端才展开代码，并解释它是短期核对码", async ({ page }) => {
  const { writes } = await fixture(page, { connected: false });
  await page.goto("./connected-apps");
  await page.getByRole("region", { name: "当前连接状态" }).getByRole("button", { name: "开始连接", exact: true }).click();
  await expect(page.getByRole("heading", { name: "当前没有有效连接", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "连接新的 AstrBot", exact: true }).click();
  const code = page.getByRole("textbox", { name: "一次性连接码", exact: true });
  await expect(code).toBeVisible();
  await expect(page.locator("#new-astrbot-connection")).toContainText("它是一次性的短期核对码（旧称设备代码），不是电脑编号、登录密码或绑定状态。");
  await code.fill("ABCD-1234");
  await page.getByRole("button", { name: "收起新连接表单", exact: true }).click();
  await expect(code).toHaveCount(0);
  await page.getByRole("button", { name: "连接新的 AstrBot", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveValue("ABCD-1234");
  expect(writes).toHaveLength(0);
});

test("断开已有连接先说明影响，取消不写入，确认后只断开当前连接", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.goto("./connected-apps");
  await page.getByRole("region", { name: "当前连接状态" }).getByRole("button", { name: "管理连接", exact: true }).click();
  await page.getByRole("button", { name: "断开此连接", exact: true }).click();
  const confirm = page.getByRole("group", { name: "确认断开连接" });
  await expect(confirm).toContainText("机器人资料、已发布内容和其他人的连接会保留");
  await expect(confirm.getByRole("button", { name: "确认断开连接", exact: true })).toBeDisabled();
  await confirm.getByRole("button", { name: "保持连接", exact: true }).click();
  expect(writes).toHaveLength(0);
  await page.getByRole("button", { name: "断开此连接", exact: true }).click();
  await confirm.getByRole("checkbox", { name: "我确认断开这条连接", exact: true }).check();
  await confirm.getByRole("button", { name: "确认断开连接", exact: true }).click();
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("当前没有有效连接");
  expect(writes).toEqual(["/api/connected-apps/binding-one/revoke"]);
});

test("批准成功收起表单并清理已消费的连接码和URL，保留其他参数", async ({ page }) => {
  const { writes } = await fixture(page, { connected: false });
  await page.goto("./connected-apps?user_code=ABCD-1234&entry=example");
  const navigation = page.getByRole("navigation", { name: "助手管理分区" });
  await navigation.getByRole("button", { name: "机器人设置与运行", exact: true }).click();
  await page.getByRole("textbox", { name: "机器人名称", exact: true }).fill("保留未保存的名字");
  await navigation.getByRole("button", { name: "连接 AstrBot", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveValue("ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await page.getByRole("checkbox", { name: "我已核对连接码与当前账号，并了解外发范围", exact: true }).check();
  await page.getByRole("button", { name: "授权此助手", exact: true }).click();
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("已连接 AstrBot");
  expect(new URL(page.url()).searchParams.has("user_code")).toBe(false);
  expect(new URL(page.url()).searchParams.get("entry")).toBe("example");
  await expect(page.getByRole("status").filter({ hasText: "已授权。返回 AstrBot" })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "连接新的 AstrBot", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveValue("");
  await navigation.getByRole("button", { name: "机器人设置与运行", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "机器人名称", exact: true })).toHaveValue("保留未保存的名字");
  expect(writes).toEqual(["/api/connected-apps/device-requests/lookup", "/api/connected-apps/device-requests/request-one/decision"]);
});

test("新的连接码历史导航清除旧核对，迟到旧请求不能恢复表单且机器人草稿保留", async ({ page }) => {
  await fixture(page, { connected: false });
  let release!: () => void, started = false;
  const delayed = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps/device-requests/lookup", async route => {
    started = true;
    await delayed;
    await route.fulfill({ json: { consent_id: "old-request", installation_name: "旧执行端", installation_id: "old-install", user_code: "ABCD-1234", requested_scopes: ["community:read"], confirmation_nonce: "old-nonce", expires_at: "2099-01-01T00:00:00Z" } });
  });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  const navigation = page.getByRole("navigation", { name: "助手管理分区" });
  await navigation.getByRole("button", { name: "机器人设置与运行", exact: true }).click();
  await page.getByRole("textbox", { name: "机器人名称", exact: true }).fill("URL变化保留的名字");
  await navigation.getByRole("button", { name: "连接 AstrBot", exact: true }).click();
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await expect.poll(() => started).toBe(true);
  await page.evaluate(() => {
    history.pushState(null, "", "/web/connected-apps?user_code=EFGH-5678");
    dispatchEvent(new PopStateEvent("popstate"));
  });
  release();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveValue("EFGH-5678");
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "授权给 旧执行端", exact: true })).toHaveCount(0);
  await navigation.getByRole("button", { name: "机器人设置与运行", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "机器人名称", exact: true })).toHaveValue("URL变化保留的名字");
  await page.evaluate(() => {
    history.pushState(null, "", "/web/connected-apps?guide=astrbot");
    dispatchEvent(new PopStateEvent("popstate"));
  });
  await expect(page.getByRole("region", { name: "AstrBot 接入教程" })).toBeVisible();
});

test("批准响应迟到时不能清空后来输入的连接码或冒充新请求成功", async ({ page }) => {
  await fixture(page, { connected: false });
  let release!: () => void, started = false;
  const delayed = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps/device-requests/request-one/decision", async route => {
    started = true; await delayed;
    await route.fulfill({ json: { binding: active } });
  });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await page.getByRole("checkbox", { name: "我已核对连接码与当前账号，并了解外发范围", exact: true }).check();
  await page.getByRole("button", { name: "授权此助手", exact: true }).click();
  await expect.poll(() => started).toBe(true);
  await page.getByRole("textbox", { name: "一次性连接码", exact: true }).fill("EFGH-5678");
  release();
  await expect(page.getByRole("textbox", { name: "一次性连接码", exact: true })).toHaveValue("EFGH-5678");
  await expect(page.getByRole("status").filter({ hasText: "已授权。返回 AstrBot" })).toHaveCount(0);
  expect(new URL(page.url()).searchParams.get("user_code")).toBe("ABCD-1234");
});

test("读取失败显示未确认，恢复读取不把有效连接变成未绑定", async ({ page }) => {
  const state = await fixture(page, { fail: true });
  await page.goto("./connected-apps");
  const status = page.getByRole("region", { name: "当前连接状态" });
  await expect(status).toContainText("连接状态未确认");
  await expect(status).not.toContainText("尚未连接");
  state.recover();
  await status.getByRole("button", { name: "重试读取连接状态", exact: true }).click();
  await expect(status).toContainText("已连接 AstrBot");
  expect(state.writes).toHaveLength(0);
});

test("刷新失败不把缓存的有效连接冒充为本次已确认", async ({ page }) => {
  const state = await fixture(page);
  await page.goto("./connected-apps");
  const status = page.getByRole("region", { name: "当前连接状态" });
  await expect(status).toContainText("已连接 AstrBot");
  await status.getByRole("button", { name: "管理连接", exact: true }).click();
  state.setFailed(true);
  await page.getByRole("button", { name: "刷新连接列表", exact: true }).click();
  await expect(status).toContainText("连接状态未确认");
  await expect(status).not.toContainText("已连接 AstrBot");
  state.recover();
  await status.getByRole("button", { name: "重试读取连接状态", exact: true }).click();
  await expect(status).toContainText("已连接 AstrBot");
  expect(state.writes).toHaveLength(0);
});

test("断开失败保留连接并允许核实，不显示已经断开", async ({ page }) => {
  await fixture(page);
  let attempts = 0;
  await page.route("**/api/connected-apps/binding-one/revoke", route => {
    attempts++;
    return route.fulfill({ status: 503, json: { code: "integration_unavailable" } });
  });
  await page.goto("./connected-apps");
  await page.getByRole("region", { name: "当前连接状态" }).getByRole("button", { name: "管理连接", exact: true }).click();
  await page.getByRole("button", { name: "断开此连接", exact: true }).click();
  const confirm = page.getByRole("group", { name: "确认断开连接" });
  await confirm.getByRole("checkbox", { name: "我确认断开这条连接", exact: true }).check();
  await confirm.getByRole("button", { name: "确认断开连接", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("服务暂时不可用");
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("已连接 AstrBot");
  await expect(confirm).toBeVisible();
  expect(attempts).toBe(1);
});

test("教程未登录也可阅读，不要求先绑定", async ({ page }) => {
  const { writes } = await fixture(page);
  for (const path of ["user/profile", "refresh"]) await page.route(`**/api/${path}`, route => route.fulfill({ status: 401, json: { code: "authentication_required" } }));
  await page.goto("./connected-apps?guide=astrbot");
  await expect(page.getByRole("region", { name: "AstrBot 接入教程" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "使用已有的机器人", exact: true })).toBeVisible();
  expect(writes.filter(path => path.includes("connected-apps"))).toHaveLength(0);
});

for (const [theme, width] of [["light", 1440], ["dark", 390]] as const) {
  test(`站内完整教程可直达且无横向溢出 ${theme}`, async ({ page }) => {
    await fixture(page);
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("./connected-apps?guide=astrbot");
    const guide = page.getByRole("region", { name: "AstrBot 接入教程" });
    await expect(guide.getByRole("heading", { name: "使用已有的机器人", exact: true })).toBeVisible();
    await expect(guide).toContainText("/sylu-connect");
    await expect(guide).toContainText("/sylu-status");
    await expect(guide).toContainText("系统身份标签");
    await guide.getByText("我要自己部署 AstrBot", { exact: true }).click();
    await expect(guide).toContainText("community_auto_browse");
    await expect(guide).toContainText("community_multi_user_runtime_enabled");
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: test.info().outputPath(`guide-${theme}.png`), fullPage: true });
  });
}
