import { chromium, expect, test, type Page } from "@playwright/test";

const historyModule = "/web/src/login-history.ts";
const account = "student@example.test", password = "synthetic-password-42";

async function fixture(page: Page) {
  const state = { loggedIn: false, fail: false, loginCalls: 0, writes: [] as { path: string; data: any; transport?: string }[], errors: [] as string[], delay: undefined as Promise<void> | undefined };
  page.on("pageerror", error => state.errors.push(error.message));
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() !== "GET") state.writes.push({ path, data: route.request().postDataJSON(), transport: route.request().headers()["x-auth-transport"] });
    if (path === "/api/user/profile") return state.loggedIn ? route.fulfill({ json: { id: 991, nickname: "合成测试同学", email: account, role: "user" } }) : route.fulfill({ status: 401, json: { message: "未登录" } });
    if (path === "/api/refresh") return route.fulfill({ status: 401, json: { message: "未登录" } });
    if (path === "/api/login") {
      state.loginCalls++;
      if (state.delay) await state.delay;
      if (route.request().failure()) return route.abort();
      if (state.fail) return route.fulfill({ status: 401, json: { code: "INVALID_CREDENTIALS", error: "账号或密码错误" } });
      state.loggedIn = true;
      return route.fulfill({ json: { user: { id: 991, nickname: "合成测试同学", email: account }, token: "must-not-persist", refresh_token: "must-not-persist-refresh" }, headers: { "set-cookie": "jwt=fixture-session; HttpOnly; SameSite=Lax; Path=/api" } });
    }
    if (path === "/api/logout") { state.loggedIn = false; return route.fulfill({ json: {} }); }
    if (path.startsWith("/api/password/") || path.startsWith("/api/register/")) return route.fulfill({ json: {} });
    return route.fulfill({ json: { items: [], posts: [], has_more: false } });
  });
  return state;
}

async function openLogin(page: Page) {
  await page.getByRole("button", { name: page.viewportSize()!.width <= 760 ? "发布校园内容" : "登录", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "登录沈理校园", exact: true });
  await expect(dialog.getByLabel("邮箱或账号")).toBeVisible();
  await expect(dialog).toHaveCSS("opacity", "1");
  await expect(dialog.getByLabel("记住账号", { exact: true })).toBeEnabled();
  return dialog;
}

async function records(page: Page) {
  return page.evaluate(async path => (await import(path)).savedAccounts(), historyModule);
}

async function seed(page: Page, entries: { account: string; password?: string; nickname?: string }[]) {
  await page.evaluate(async ({ path, entries }) => {
    const history = await import(path);
    for (const entry of entries) await history.rememberLogin({ ...entry, password: entry.password || "", nickname: entry.nickname || "测试同学", rememberPassword: !!entry.password, revision: await history.historyRevision(), loginStartedAt: Date.now() });
  }, { path: historyModule, entries });
}

test("登录面板支持密码显隐，成功后加密保存，重新打开自动回填并可移除", async ({ page, context }) => {
  const state = await fixture(page);
  await page.goto("./");
  let dialog = await openLogin(page);
  await expect(dialog.getByLabel("邮箱或账号")).toBeFocused();
  await expect(dialog.getByLabel("记住密码", { exact: true })).not.toBeChecked();
  await dialog.getByLabel("邮箱或账号").fill(account);
  await dialog.getByLabel("密码", { exact: true }).fill(password);
  await dialog.getByRole("button", { name: "显示密码" }).click();
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveAttribute("type", "text");
  await dialog.getByRole("button", { name: "隐藏密码" }).click();
  await dialog.getByLabel("记住密码", { exact: true }).check();
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  await expect.poll(async () => (await records(page)).length).toBe(1);
  const stored = await page.evaluate(async () => {
    const db = await new Promise<IDBDatabase>((resolve, reject) => { const request = indexedDB.open("sylulive-login", 1); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); });
    const values: any[] = await new Promise((resolve, reject) => { const tx = db.transaction("accounts"), request = tx.objectStore("accounts").getAll(); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); });
    db.close();
    return { serialized: JSON.stringify(values), extractable: values[0].secret.key.extractable, local: JSON.stringify(localStorage), session: JSON.stringify(sessionStorage) };
  });
  expect(stored.extractable).toBe(false);
  for (const value of [stored.serialized, stored.local, stored.session]) { expect(value).not.toContain(password); expect(value).not.toContain("must-not-persist"); }
  expect((await context.cookies()).find(cookie => cookie.name === "jwt")?.httpOnly).toBe(true);
  expect(state.writes.find(write => write.path === "/api/login")?.transport).toBe("cookie");
  await page.goto("profile");
  await page.getByRole("button", { name: "退出登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "登录", exact: true }).first()).toBeVisible();
  await page.goto("./");
  dialog = await openLogin(page);
  await expect(dialog.getByLabel("邮箱或账号")).toHaveValue(account);
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue(password);
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveAttribute("autocomplete", "current-password");
  await expect(dialog.getByLabel("邮箱或账号")).toHaveAttribute("autocomplete", "username");
  await dialog.getByLabel("记住密码", { exact: true }).uncheck();
  await expect.poll(async () => (await records(page))[0]?.hasPassword).toBe(false);
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue(password);
  await dialog.getByRole("button", { name: "选择历史账号" }).click();
  await dialog.getByRole("button", { name: `移除账号记录 ${account}`, exact: true }).click();
  await expect.poll(async () => (await records(page)).length).toBe(0);
  await expect(dialog.getByLabel("密码", { exact: true })).toBeEmpty();
  expect(state.errors).toEqual([]);
});

test("错误登录不保存，默认只记录账号，关闭记住账号后不留新记录", async ({ page }) => {
  const state = await fixture(page);
  state.fail = true;
  await page.goto("./");
  let dialog = await openLogin(page);
  await dialog.getByLabel("邮箱或账号").fill(account);
  await dialog.getByLabel("密码", { exact: true }).fill(password);
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("账号或密码错误");
  await expect(dialog.getByLabel("邮箱或账号")).toHaveAttribute("aria-invalid", "true");
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveAccessibleDescription("账号或密码错误");
  expect(await records(page)).toEqual([]);
  state.fail = false;
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  await expect.poll(async () => (await records(page))[0]?.hasPassword).toBe(false);
  state.loggedIn = false;
  await page.reload(); dialog = await openLogin(page);
  await expect(dialog.getByLabel("邮箱或账号")).toHaveValue(account);
  await expect(dialog.getByLabel("密码", { exact: true })).toBeEmpty();
  await dialog.getByLabel("密码", { exact: true }).fill(password);
  await dialog.getByLabel("记住账号", { exact: true }).uncheck();
  await expect.poll(async () => (await records(page)).length).toBe(0);
  await expect(dialog.getByLabel("邮箱或账号")).toHaveValue(account);
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  expect(await records(page)).toEqual([]);
});

test("账号切换和手动输入隔离迟到的密码解密结果", async ({ page }) => {
  await fixture(page); await page.goto("./");
  await seed(page, [{ account: "one@example.test", password: "first-secret" }, { account: "two@example.test", password: "second-secret" }]);
  const dialog = await openLogin(page);
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue("second-secret");
  await dialog.getByRole("button", { name: "显示密码" }).click();
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveAttribute("type", "text");
  await page.evaluate(() => {
    const decrypt = crypto.subtle.decrypt.bind(crypto.subtle);
    (window as any).__decryptRelease = [];
    crypto.subtle.decrypt = async (...args: Parameters<SubtleCrypto["decrypt"]>) => {
      if (new TextDecoder().decode((args[0] as AesGcmParams).additionalData).endsWith(":one@example.test")) await new Promise<void>(resolve => (window as any).__decryptRelease.push(resolve));
      return decrypt(...args);
    };
  });
  const choose = async (account: string) => { await dialog.getByRole("button", { name: "选择历史账号" }).click(); await dialog.getByRole("button", { name: `使用账号 ${account}`, exact: true }).click(); };
  await choose("one@example.test");
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveAttribute("type", "password");
  await expect.poll(() => page.evaluate(() => (window as any).__decryptRelease.length)).toBe(1);
  await choose("two@example.test");
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue("second-secret");
  await page.evaluate(() => (window as any).__decryptRelease.splice(0).forEach((release: () => void) => release()));
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue("second-secret");
  await choose("one@example.test");
  await expect.poll(() => page.evaluate(() => (window as any).__decryptRelease.length)).toBe(1);
  await dialog.getByLabel("密码", { exact: true }).fill("manually-entered-secret");
  await page.evaluate(() => (window as any).__decryptRelease.splice(0).forEach((release: () => void) => release()));
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue("manually-entered-secret");
  await dialog.getByRole("button", { name: "显示密码" }).click();
  await dialog.getByLabel("邮箱或账号").fill("manual@example.test");
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveAttribute("type", "password");
});

test("清空记录阻止在途加密写回，多标签页移除后不再保留回填密码", async ({ page, context }) => {
  await fixture(page); await page.goto("./");
  await seed(page, [{ account, password }]);
  const dialog = await openLogin(page);
  await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue(password);
  const other = await context.newPage(); await fixture(other); await other.goto("./");
  await other.evaluate(async path => (await import(path)).clearSavedAccounts(), historyModule);
  await expect(dialog.getByLabel("密码", { exact: true })).toBeEmpty();
  expect(await page.evaluate(async path => {
    const history = await import(path), revision = await history.historyRevision();
    await history.clearSavedAccounts();
    try { await history.rememberLogin({ account: "late@example.test", password: "late-secret", rememberPassword: true, revision, loginStartedAt: Date.now() }); return "unexpected save"; }
    catch { return (await history.savedAccounts()).length; }
  }, historyModule)).toBe(0);
  await other.close();
});

test("关闭在途登录后不会保存密码或关闭后来打开的注册界面", async ({ page }) => {
  const state = await fixture(page);
  let release = () => {};
  state.delay = new Promise<void>(resolve => { release = resolve; });
  try {
    await page.goto("./"); const dialog = await openLogin(page);
    await dialog.getByLabel("邮箱或账号").fill(account); await dialog.getByLabel("密码", { exact: true }).fill(password);
    await dialog.getByLabel("记住密码", { exact: true }).check();
    await dialog.getByRole("button", { name: "登录", exact: true }).click();
    await expect.poll(() => state.loginCalls).toBe(1);
    await expect(dialog.getByRole("button", { name: "正在登录…", exact: true })).toBeDisabled();
    await dialog.getByRole("button", { name: "关闭", exact: true }).click();
    const next = await openLogin(page); await next.getByRole("button", { name: "注册账号", exact: true }).click();
    release();
    await expect(page.getByRole("dialog", { name: "邮箱注册", exact: true })).toBeVisible();
    expect(await records(page)).toEqual([]);
    expect(state.loginCalls).toBe(1);
  } finally { release(); }
});

test("浏览器禁用存储时仍可手动登录", async ({ page }) => {
  const state = await fixture(page);
  await page.addInitScript(() => Object.defineProperty(window, "indexedDB", { configurable: true, get() { throw new DOMException("blocked", "SecurityError"); } }));
  await page.goto("./");
  await page.getByRole("button", { name: "登录", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "登录沈理校园", exact: true });
  await expect(dialog.getByText("本机账号记录暂不可用，你仍可手动登录。")).toBeVisible();
  await expect(dialog.getByLabel("记住账号", { exact: true })).toBeDisabled();
  await dialog.getByLabel("邮箱或账号").fill(account); await dialog.getByLabel("密码", { exact: true }).fill(password);
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  expect(state.loginCalls).toBe(1); expect(state.errors).toEqual([]);
});

test("找回密码沿用验证码接口，清除旧保存密码并回到登录", async ({ page }) => {
  const state = await fixture(page); await page.goto("./"); await seed(page, [{ account, password }]);
  const dialog = await openLogin(page); await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue(password);
  await dialog.getByRole("button", { name: "忘记密码", exact: true }).click();
  const reset = page.getByRole("dialog", { name: "找回密码", exact: true });
  const form = reset.locator("form").nth(1);
  await expect(form.getByLabel("邮箱", { exact: true })).toHaveValue(account);
  await form.getByLabel("验证码", { exact: true }).fill("123456");
  await form.getByLabel("新密码", { exact: true }).fill("new-synthetic-password");
  await form.getByRole("button", { name: "重置密码", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true }).getByLabel("密码", { exact: true })).toBeEmpty();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true }).getByLabel("邮箱或账号")).toBeFocused();
  expect((await records(page))[0].hasPassword).toBe(false);
  expect(state.writes.find(write => write.path === "/api/password/email/reset")?.data).toMatchObject({ email: account, code: "123456", new_password: "new-synthetic-password" });
});

test("浏览器重启后保存的密码仍可读取，历史账号去重并限制最近五个", async ({}, info) => {
  const directory = info.outputPath("remembered-browser");
  let context = await chromium.launchPersistentContext(directory, { headless: true, baseURL: "http://127.0.0.1:5173/web/", viewport: { width: 1440, height: 900 } });
  try {
    let page = await context.newPage(); await fixture(page); await page.goto("./");
    await seed(page, Array.from({ length: 6 }, (_, index) => ({ account: `user-${index}@example.test`, password: "synthetic-record-password" })));
    await seed(page, [{ account, password }]);
    await seed(page, [{ account: account.toUpperCase(), password }]);
    expect((await records(page)).length).toBe(5);
    expect((await records(page)).filter((record: any) => record.key === account)).toHaveLength(1);
    await context.close();
    context = await chromium.launchPersistentContext(directory, { headless: true, baseURL: "http://127.0.0.1:5173/web/", viewport: { width: 1440, height: 900 } });
    page = await context.newPage(); await fixture(page); await page.goto("./");
    const dialog = await openLogin(page);
    await expect(dialog.getByLabel("邮箱或账号")).toHaveValue(account.toUpperCase());
    await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue(password);
  } finally { await context.close(); }
});

test("本机写入失败不阻断成功登录，也不降级保存明文", async ({ page }) => {
  const state = await fixture(page); await page.goto("./");
  const dialog = await openLogin(page);
  await page.evaluate(() => {
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function(...args: Parameters<IDBObjectStore["put"]>) {
      if (this.name === "accounts") throw new DOMException("synthetic quota", "QuotaExceededError");
      return put.apply(this, args);
    };
  });
  await dialog.getByLabel("邮箱或账号").fill(account); await dialog.getByLabel("密码", { exact: true }).fill(password);
  await dialog.getByLabel("记住密码", { exact: true }).check();
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  await expect(page.getByText("本机账号记录未能保存，可在下次登录时重试", { exact: true })).toBeVisible();
  expect(await records(page)).toEqual([]);
  expect(state.errors).toEqual([]);
});

test("损坏的保存密码不会回填，手动登录后可以替换", async ({ page }) => {
  const state = await fixture(page); await page.goto("./"); await seed(page, [{ account, password }]);
  await page.evaluate(async key => {
    const db = await new Promise<IDBDatabase>(resolve => { const request = indexedDB.open("sylulive-login", 1); request.onsuccess = () => resolve(request.result); });
    await new Promise<void>((resolve, reject) => { const tx = db.transaction("accounts", "readwrite"), store = tx.objectStore("accounts"), request = store.get(key); request.onsuccess = () => { const record = request.result; record.secret.data[0] ^= 1; store.put(record); }; tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); });
    db.close();
  }, account);
  const dialog = await openLogin(page);
  await expect(dialog.getByText("保存的密码无法读取，请重新输入", { exact: true })).toBeVisible();
  await expect(dialog.getByLabel("密码", { exact: true })).toBeEmpty();
  await dialog.getByLabel("密码", { exact: true }).fill(password);
  await dialog.getByLabel("记住密码", { exact: true }).check();
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  await expect.poll(async () => page.evaluate(async ({ path, account }) => (await import(path)).savedPassword(account), { path: historyModule, account })).toBe(password);
  expect(state.errors).toEqual([]);
});

test("注册保留协议勾选，修改密码可按本人身份清除保存密码", async ({ page }) => {
  const state = await fixture(page); await page.goto("./");
  const dialog = await openLogin(page); await dialog.getByLabel("邮箱或账号").fill(account);
  await dialog.getByRole("button", { name: "注册账号", exact: true }).click();
  const registration = page.getByRole("dialog", { name: "邮箱注册", exact: true }), form = registration.locator("form").nth(1);
  await form.getByLabel("验证码", { exact: true }).fill("123456");
  await form.getByLabel("新密码", { exact: true }).fill(password); await form.getByLabel("昵称", { exact: true }).fill("测试同学");
  await form.getByRole("button", { name: "注册", exact: true }).click();
  expect(state.writes.some(write => write.path === "/api/register/email")).toBe(false);
  await form.getByRole("checkbox").check(); await form.getByRole("button", { name: "注册", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true })).toBeVisible();
  await expect(page.getByRole("dialog", { name: "登录沈理校园", exact: true }).getByLabel("邮箱或账号")).toBeFocused();
  expect(state.writes.find(write => write.path === "/api/register/email")?.data).toMatchObject({ email: account, user_agreement_accepted: true, privacy_policy_accepted: true });
  const login = page.getByRole("dialog", { name: "登录沈理校园", exact: true });
  await login.getByLabel("密码", { exact: true }).fill(password);
  await login.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
  await page.evaluate(async path => {
    const history = await import(path);
    for (const userId of [991, 992]) await history.rememberLogin({ account: `alias-${userId}`, userId, password: "synthetic-secret", rememberPassword: true, revision: await history.historyRevision(), loginStartedAt: Date.now() });
  }, historyModule);
  await page.goto("profile");
  await page.getByRole("button", { name: "账号安全", exact: true }).click();
  const security = page.getByRole("dialog", { name: "账号安全", exact: true });
  await security.getByLabel("当前密码", { exact: true }).fill(password);
  await expect(security.getByLabel("新密码（8–32 位）", { exact: true })).toHaveAttribute("autocomplete", "new-password");
  await security.getByLabel("新密码（8–32 位）", { exact: true }).fill("updated-synthetic-password");
  await security.getByRole("button", { name: "修改密码", exact: true }).click();
  await expect(security).not.toBeVisible();
  expect(state.writes.find(write => write.path === "/api/change_password")?.data).toEqual({ old_password: password, new_password: "updated-synthetic-password" });
  const values = await records(page);
  expect(values.find((value: any) => value.userId === 991)?.hasPassword).toBe(false);
  expect(values.find((value: any) => value.userId === 992)?.hasPassword).toBe(true);
});

for (const theme of ["light", "dark"]) test(`登录与账号记录在${theme}、窄屏和短屏下可操作`, async ({ page }) => {
  const state = await fixture(page);
  await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
  await page.goto("./");
  await seed(page, [{ account: "a-very-long-account-name-for-layout@example.test", nickname: "校园里的同学" }, { account: "first@example.test", password: "first-secret", nickname: "校园同学" }]);
  for (const [width, height] of [[1440, 900], [390, 844], [320, 420]]) {
    await page.setViewportSize({ width, height });
    const dialog = await openLogin(page);
    await expect(dialog.getByLabel("密码", { exact: true })).toHaveValue("first-secret");
    await dialog.getByLabel("邮箱或账号").press("ArrowDown");
    const choices = dialog.locator("[data-account-choice]");
    await expect(choices.first()).toBeFocused();
    await expect(choices.first()).toHaveAttribute("aria-current", "true");
    await page.keyboard.press("ArrowDown"); await expect(choices.last()).toBeFocused();
    await page.keyboard.press("Home"); await expect(choices.first()).toBeFocused();
    await page.keyboard.press("ArrowUp"); await expect(choices.last()).toBeFocused();
    await page.keyboard.press("End"); await expect(choices.last()).toBeFocused();
    await page.keyboard.press("Home");
    await expect(dialog.getByRole("group", { name: "历史账号", exact: true })).toBeVisible();
    expect(await dialog.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
    expect(await dialog.locator("input[name=account]").evaluate(el => parseFloat(getComputedStyle(el).fontSize))).toBeGreaterThanOrEqual(16);
    await page.screenshot({ path: `.codex-captures/login/${theme}-${width}-history.png` });
    await page.keyboard.press("Escape");
    await expect(dialog).toBeVisible(); await expect(dialog.getByLabel("邮箱或账号")).toBeFocused();
    await dialog.getByRole("button", { name: "登录", exact: true }).scrollIntoViewIfNeeded();
    await expect(dialog.getByRole("button", { name: "登录", exact: true })).toBeInViewport();
    await page.screenshot({ path: `.codex-captures/login/${theme}-${width}.png` });
    await page.keyboard.press("Escape"); await expect(dialog).not.toBeVisible();
  }
  expect(state.errors).toEqual([]);
});
