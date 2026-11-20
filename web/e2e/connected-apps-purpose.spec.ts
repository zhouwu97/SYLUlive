import { test, expect, type Page } from "@playwright/test";

const personal = ["profile:read_minimal", "checkin:write", "academic:grades:read", "academic:erke:read"];
const community = ["community:read", "actions:read_own", "community:propose", "community:bot_reply", "community:bot_post"];
async function fixture(page: Page, options: { connected?: boolean; failed?: boolean; signedOut?: boolean } = {}) {
  let scopes = [...personal, ...community], connected = !!options.connected, failed = !!options.failed;
  const requests: string[] = [], writes: { path: string; body: Record<string, unknown> }[] = [];
  const binding = () => ({ binding_id: "mine", installation_name: "QQ 示例 · 群机器人", installation_id: "my-install", state: "active", scopes: scopes.join(" "), epoch: 1 });
  await page.route("**/api/**", async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    requests.push(path);
    if (req.method() !== "GET") writes.push({ path, body: req.postDataJSON() });
    if (path === "/api/user/profile") return route.fulfill(options.signedOut ? { status: 401, json: { code: "invalid_token" } } : { json: { id: 991, nickname: "示例用户", role: "user", student_verified: false } });
    if (path === "/api/connected-apps") return route.fulfill(failed ? { status: 503, json: { code: "integration_unavailable" } } : { json: { bindings: connected ? [binding()] : [], personal_data_enabled: true } });
    if (path.endsWith("/lookup")) return route.fulfill({ json: { consent_id: "request", installation_name: "QQ 示例 · 群机器人", installation_id: "my-install", user_code: "ABCD-1234", requested_scopes: [...personal, ...community], confirmation_nonce: "synthetic-nonce", expires_at: "2099-01-01T00:00:00Z" } });
    if (path.endsWith("/decision") || path.endsWith("/scopes")) { connected = true; scopes = req.postDataJSON().scopes; return route.fulfill({ json: { binding: binding() } }); }
    if (path === "/api/connected-apps/bot") return route.fulfill({ json: { bot: null, policy_supported: true, sections: [], auto_reply_server_enabled: true, auto_reply_authorized: true } });
    return route.fulfill({ status: 404, json: { code: "fixture_unavailable" } });
  });
  return { requests, writes, recover: () => { failed = false; } };
}

test("QQ 临时链接直达用户绑定，普通用户看不到机器人设置和部署后台", async ({ page }) => {
  const { requests, writes } = await fixture(page);
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await expect(page.getByRole("heading", { name: "QQ 助手与社区机器人", exact: true })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "一次性连接码" })).toHaveValue("ABCD-1234");
  await expect(page.locator("#new-astrbot-connection")).toContainText("连接和签到无需教务核验");
  await expect(page.getByRole("region", { name: "AstrBot 插件后台" })).toHaveCount(0);
  await expect(page.getByLabel("机器人名称", { exact: true })).toHaveCount(0);
  await expect(page.getByText("自动参与权限尚未齐全", { exact: true })).toHaveCount(0);
  expect(requests).not.toContain("/api/connected-apps/bot");
  expect(writes).toHaveLength(0);
});

for (const [theme, width] of [["light", 375], ["dark", 1440]] as const) {
  test(`签到授权与社区机器人权限分开，成功后给出本人命令 ${theme}`, async ({ page }) => {
    const { writes } = await fixture(page);
    await page.setViewportSize({ width, height: 1000 });
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await page.goto("./connected-apps?user_code=ABCD-1234&entry=qq");
    await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
    const checkin = page.getByRole("checkbox", { name: /查看本人签到状态/ });
    await expect(checkin).not.toBeChecked();
    await expect(page.getByRole("checkbox", { name: /独立AI机器人自动发帖/ })).toHaveCount(0);
    await expect(page.getByRole("button", { name: "选择自动评论和发帖所需权限" })).toHaveCount(0);
    if (width === 375) await expect(page.locator(".mobile-header-title")).toHaveText("QQ 助手与社区机器人");
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: test.info().outputPath(`personal-request-${theme}.png`), fullPage: true });
    await checkin.check();
    await page.getByLabel("我已核对连接码与当前账号，并了解外发范围", { exact: true }).check();
    await page.getByRole("button", { name: "授权此助手", exact: true }).click();
    await expect(page.getByRole("status").filter({ hasText: "已授权。" })).toBeVisible();
    expect(writes.at(-1)?.body.scopes).toEqual(["profile:read_minimal", "checkin:write"]);
    await expect(page.locator(".integration-workspace")).toContainText("/sylu-checkin");
    await expect(page.getByText("本次授权尚不足以自动评论或发帖。", { exact: false })).toHaveCount(0);
    expect(new URL(page.url()).searchParams.has("user_code")).toBe(false);
    expect(new URL(page.url()).searchParams.get("entry")).toBe("qq");
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: test.info().outputPath(`personal-${theme}.png`), fullPage: true });
  });
}

test("个人权限编辑保留已有社区授权，且不要求补充机器人权限", async ({ page }) => {
  const { writes } = await fixture(page, { connected: true });
  await page.goto("./connected-apps");
  await expect(page.getByRole("heading", { name: "当前有效连接", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "补充机器人授权", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "修改权限", exact: true }).click();
  const editor = page.getByRole("group", { name: "修改连接权限" });
  await expect(editor.getByRole("checkbox", { name: /自动发帖/ })).toHaveCount(0);
  await editor.getByRole("checkbox", { name: /查看本人签到状态/ }).uncheck();
  await editor.getByRole("button", { name: "保存权限", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "权限已更新" })).toBeVisible();
  expect(writes[0].body.scopes).toEqual(expect.arrayContaining(community));
  expect(writes[0].body.scopes).not.toContain("checkin:write");
});

test("同一管理页切换类别不自动授权，部署工具归入社区机器人", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.goto("./connected-apps?user_code=ABCD-1234");
  const navigation = page.getByRole("navigation", { name: "管理分类" });
  const personalCategory = navigation.getByRole("link", { name: /^绑定我的 QQ/ });
  const botCategory = navigation.getByRole("link", { name: /^管理社区机器人/ });
  await expect(personalCategory).toHaveAttribute("aria-current", "true");
  await expect(page.getByRole("region", { name: "绑定我的 QQ", exact: true })).toBeVisible();
  await botCategory.click();
  await expect(page).toHaveURL(/purpose=bot/);
  await expect(page.getByRole("heading", { name: "QQ 助手与社区机器人", exact: true })).toBeVisible();
  await expect(botCategory).toHaveAttribute("aria-current", "true");
  await expect(page.getByRole("region", { name: "管理社区机器人", exact: true })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "一次性连接码" })).toHaveValue("ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await expect(page.getByRole("checkbox", { name: /查看本人签到状态/ })).toHaveCount(0);
  await expect(page.getByRole("checkbox", { name: /独立AI机器人自动发帖/ })).not.toBeChecked();
  await expect(page.getByRole("region", { name: "AstrBot 插件后台" })).toHaveCount(0);
  await page.getByRole("button", { name: "接入教程", exact: true }).click();
  await page.getByText("部署者工具与后台", { exact: true }).click();
  await expect(page.getByRole("region", { name: "AstrBot 插件后台" })).toBeVisible();
  expect(writes.map(value => value.path)).toEqual(["/api/connected-apps/device-requests/lookup"]);
});

for (const width of [390, 1440]) {
  test(`个人主页只有一个助手管理入口，${width}px`, async ({ page }) => {
    await fixture(page);
    await page.setViewportSize({ width, height: 950 });
    await page.goto("./profile");
    const entry = page.getByRole("link", { name: /^QQ 助手与社区机器人/ });
    await expect(entry).toHaveCount(1);
    await expect(entry).toHaveAttribute("href", "/web/connected-apps");
    await entry.click();
    const navigation = page.getByRole("navigation", { name: "管理分类" });
    await expect(navigation.getByRole("link")).toHaveCount(2);
    await expect(navigation.getByText("用 QQ 助手签到、查自己的成绩和二课")).toBeVisible();
    await expect(navigation.getByText("设置自己的 AstrBot，管理社区互动和运行")).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: test.info().outputPath("assistant-management.png") });
  });
}

test("读取失败可以重试，用户绑定不会因失败跳转机器人设置", async ({ page }) => {
  const { recover, writes } = await fixture(page, { failed: true });
  await page.goto("./connected-apps");
  const status = page.getByRole("region", { name: "当前连接状态" });
  await expect(status).toContainText("连接状态未确认");
  recover();
  await status.getByRole("button", { name: "重试读取连接状态", exact: true }).click();
  await expect(status).toContainText("当前没有有效连接");
  await expect(page.getByRole("heading", { name: "QQ 助手与社区机器人", exact: true })).toBeVisible();
  expect(writes).toHaveLength(0);
});

test("未登录的 QQ 链接保留连接码并解释本人绑定用途", async ({ page }) => {
  await fixture(page, { signedOut: true });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await expect(page.getByRole("heading", { name: "QQ 助手与社区机器人", exact: true })).toBeVisible();
  await expect(page.locator(".integration-workspace").getByRole("button", { name: "登录", exact: true })).toBeVisible();
  await expect(page.getByLabel("机器人名称", { exact: true })).toHaveCount(0);
  expect(new URL(page.url()).searchParams.get("user_code")).toBe("ABCD-1234");
});

test("用户绑定加载中不误报未绑定，空状态有明确本人绑定入口", async ({ page }) => {
  const { writes, requests } = await fixture(page);
  let release!: () => void;
  const paused = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps", async route => { await paused; await route.fulfill({ json: { bindings: [], personal_data_enabled: true } }); });
  await page.goto("./connected-apps");
  const status = page.getByRole("region", { name: "当前连接状态" });
  await expect(status).toContainText("正在核对连接状态");
  await expect(status).not.toContainText("当前没有有效连接");
  release();
  await expect(status).toContainText("当前没有有效连接");
  await page.getByRole("button", { name: "绑定我的 QQ 账号", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "一次性连接码" })).toBeVisible();
  expect(writes).toHaveLength(0);
  expect(requests).not.toContain("/api/connected-apps/bot");
});

test("本人绑定请求失败可重试，不会提交或展示社区权限", async ({ page }) => {
  const { writes } = await fixture(page);
  let fail = true;
  await page.route("**/api/connected-apps/device-requests/lookup", async route => fail
    ? route.fulfill({ status: 503, json: { code: "integration_unavailable" } })
    : route.fallback());
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("服务暂时不可用");
  await expect(page.getByRole("textbox", { name: "一次性连接码" })).toHaveValue("ABCD-1234");
  fail = false;
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await expect(page.getByRole("checkbox", { name: /查看本人签到状态/ })).toBeVisible();
  expect(writes.some(value => value.path.endsWith("/decision"))).toBe(false);
});

test("切换用途取消旧核对，迟到请求不会串入社区机器人表单", async ({ page }) => {
  const { writes } = await fixture(page);
  let release!: () => void;
  const paused = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps/device-requests/lookup", async route => { await paused; await route.fallback(); });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  const started = page.waitForRequest("**/api/connected-apps/device-requests/lookup");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await started;
  await page.getByRole("link", { name: /^管理社区机器人/ }).click();
  release();
  await expect(page.getByRole("region", { name: "管理社区机器人", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toHaveCount(0);
  await expect(page.getByRole("textbox", { name: "一次性连接码" })).toHaveValue("ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await expect(page.getByRole("checkbox", { name: /独立AI机器人自动发帖/ })).not.toBeChecked();
  expect(writes.some(value => value.path.endsWith("/decision"))).toBe(false);
});

test("用户绑定切号后迟到请求不能恢复旧账号的授权", async ({ page }) => {
  const { writes } = await fixture(page);
  let release!: () => void;
  const paused = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps/device-requests/lookup", async route => { await paused; await route.fallback(); });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  const started = page.waitForRequest("**/api/connected-apps/device-requests/lookup");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await started;
  await page.route("**/api/user/profile", route => route.fulfill({ json: { id: 992, nickname: "另一个合成用户", role: "user" } }));
  await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  await expect(page.locator(".integration-current-account")).toContainText("另一个合成用户");
  release();
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toHaveCount(0);
  expect(writes.some(value => value.path.endsWith("/decision"))).toBe(false);
});

test("本人资料同步有独立分区，切换分区保留尚未提交的签到选择", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求", exact: true }).click();
  await page.getByRole("checkbox", { name: /查看本人签到状态/ }).check();
  const nav = page.getByRole("navigation", { name: "助手管理分区" });
  await nav.getByRole("button", { name: "个人资料同步", exact: true }).click();
  await expect(page.getByRole("heading", { name: "供本人 QQ 查询的资料同步", exact: true })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "一次性连接码" })).toBeHidden();
  await nav.getByRole("button", { name: "账号绑定与权限", exact: true }).click();
  await expect(page.getByRole("checkbox", { name: /查看本人签到状态/ })).toBeChecked();
  expect(writes.some(value => value.path.includes("personal-sync") || value.path.endsWith("/decision"))).toBe(false);
});

test("资料修复链接直达个人同步，学校资料失败后基础连接保持可管理", async ({ page }) => {
  const { writes } = await fixture(page, { connected: true });
  await page.goto("./connected-apps?purpose=personal&view=data");
  await expect(page.getByRole("heading", { name: "供本人 QQ 查询的资料同步", exact: true })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "助手管理分区" }).getByRole("button", { name: "个人资料同步", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("navigation", { name: "助手管理分区" }).getByRole("button", { name: "账号绑定与权限", exact: true }).click();
  await expect(page.getByRole("region", { name: "当前连接状态" })).toContainText("已绑定 QQ 机器人");
  await expect(page.getByRole("button", { name: "修改权限", exact: true })).toBeVisible();
  expect(writes).toHaveLength(0);
});
