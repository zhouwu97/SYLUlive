import { readFileSync } from "node:fs";
import { test, expect, type Page } from "@playwright/test";

const consent = {
  consent_id: "request-one",
  installation_name: "我的 AstrBot",
  installation_id: "install-one",
  user_code: "ABCD-1234",
  requested_scopes: [
    "profile:read_minimal",
    "community:read",
    "actions:read_own",
    "community:propose",
    "checkin:write",
    "academic:grades:read",
    "academic:erke:read",
  ],
  confirmation_nonce: "owner-nonce",
  expires_at: "2099-01-01T00:00:00Z",
};
const action = {
  action_id: "action-one",
  kind: "reply",
  state: "pending",
  draft_version: 1,
  payload_hash: "hash-one",
  expires_at: "2099-01-01T00:00:00Z",
  payload: {
    post_id: 123,
    content: "这是经过本人核对的合成评论",
    sticker_id: "test_sticker",
  },
};
async function fixture(
  page: Page,
  options: { recent?: boolean; slow?: boolean } = {},
) {
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  let decisions = 0;
  const groups = JSON.parse(
    readFileSync(
      new URL(
        "../../server/internal/handlers/sticker_assets/catalog.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const sticker = groups[0].items[0];
  await page.route("**/stickers/test_sticker", (route) =>
    route.fulfill({
      contentType: sticker.mime_type,
      body: readFileSync(
        new URL(
          "../../server/internal/handlers/sticker_assets/" + sticker.file,
          import.meta.url,
        ),
      ),
    }),
  );

  await page.route("**/api/**", async (route) => {
    const request = route.request(),
      path = new URL(request.url()).pathname;
    if (request.method() === "POST")
      writes.push({ path, body: request.postDataJSON() });
    if (path === "/api/user/profile")
      return route.fulfill({
        json: { id: 991, nickname: "合成账号", role: "user" },
      });
    if (path === "/api/connected-apps")
      return route.fulfill({ json: { bindings: [] } });
    if (path.endsWith("/lookup"))
      return route.fulfill(
        options.recent
          ? { status: 403, json: { code: "recent_authentication_required" } }
          : { json: consent },
      );
    if (path.includes("/device-requests/") && path.endsWith("/decision"))
      return route.fulfill({ json: { binding: { binding_id: "bound" } } });
    if (path === "/api/connected-apps/actions/action-one") {
      if (options.slow)
        await new Promise((resolve) => setTimeout(resolve, 200));
      return route.fulfill({
        json: {
          action: decisions
            ? {
                ...action,
                state: "published",
                payload: {},
                post_id: 123,
                reply_id: 456,
              }
            : action,
          confirmation_nonce: "approval-nonce",
          confirmation_expires_at: "2099-01-01T00:00:00Z",
        },
      });
    }
    if (path === "/api/connected-apps/actions/action-one/decision") {
      decisions++;
      await new Promise((resolve) => setTimeout(resolve, 200));
      return route.fulfill({
        json: {
          action: {
            ...action,
            state: "published",
            post_id: 123,
            reply_id: 456,
            payload: {},
          },
        },
      });
    }
    return route.fulfill({
      status: 404,
      json: { code: "fixture_resource_unavailable" },
    });
  });
  return writes;
}

test("授权需核对代码，写入提案默认不勾选，提交不携带QQ身份或用户ID", async ({
  page,
}) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await expect(
    page.getByRole("heading", { name: "已授权助手", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "暂无助手授权" }),
  ).toBeVisible();
  expect(writes).toHaveLength(0);
  await page.getByRole('textbox',{name:'设备代码'}).fill('');
  await expect(page.getByRole('button',{name:'查看授权请求'})).toBeDisabled();
  await expect(page.getByRole('button',{name:'查看授权请求'})).toHaveAccessibleDescription(/AstrBot 私聊发送 \/sylu-connect/);
  await page.getByRole('textbox',{name:'设备代码'}).fill('ABCD-1234');
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await expect(
    page.getByLabel("公开帖子与评论、作者昵称、互动统计、公开图片和表情目录"),
  ).toBeVisible();
  await expect(page.getByLabel("本账号已同步成绩（私聊，非学校实时查询）")).not.toBeChecked();
  await expect(page.getByLabel("本账号已同步二课摘要（私聊）")).not.toBeChecked();
  await expect(page.getByText("本连接不提供站内私信", { exact: false })).toBeVisible();
  await page.screenshot({
    path: test.info().outputPath("consent-public-media.png"),
    fullPage: true,
  });
  const writeScope = page.getByLabel("创建待本人确认的帖子或评论草稿");
  await expect(writeScope).not.toBeChecked();
  await expect(page.getByLabel("查看本人签到状态，并按本人指令每日签到（不含补签）")).not.toBeChecked();
  await expect(page.getByRole("button", { name: "授权此助手" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "授权此助手" })).toHaveAccessibleDescription(/请先核对设备代码与账号/);
  await page.getByLabel("我已核对设备代码与当前账号，并了解外发范围").check();
  await page.getByRole("button", { name: "授权此助手" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "已授权。" }),
  ).toBeVisible();
  const decision = writes.find((x) => x.path.endsWith("/decision"))!;
  expect(decision.body.scopes).not.toContain("community:propose");
  expect(decision.body.scopes).not.toContain("checkin:write");
  expect(decision.body.confirmation_nonce).toBe("owner-nonce");
  expect(decision.body).not.toHaveProperty("qq");
  expect(decision.body).not.toHaveProperty("owner_id");
});

test("官方网页真实登录交互后重读当前账号，能够继续设备授权", async ({
  page,
}) => {
  await fixture(page);
  let loggedIn = false;
  await page.route("**/api/user/profile", (route) =>
    route.fulfill(
      loggedIn
        ? { json: { id: 991, nickname: "登录后的合成账号", role: "user" } }
        : { status: 401, json: { code: "authentication_required" } },
    ),
  );
  await page.route("**/api/refresh", (route) =>
    route.fulfill({ status: 401, json: { code: "authentication_required" } }),
  );
  await page.route("**/api/login", (route) => {
    expect(route.request().postDataJSON()).toMatchObject({
      account: "synthetic",
      password: "synthetic-password",
    });
    loggedIn = true;
    return route.fulfill({
      json: { user: { id: 991 } },
      headers: {
        "set-cookie":
          "jwt=synthetic-http-only; HttpOnly; SameSite=Lax; Path=/api",
      },
    });
  });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page
    .getByRole("main")
    .getByRole("button", { name: "登录", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("邮箱或账号").fill("synthetic");
  await dialog.getByLabel("密码", { exact: true }).fill("synthetic-password");
  await dialog.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByText(/当前账号：登录后的合成账号/)).toBeVisible();
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await expect(page.getByRole("button", { name: "授权此助手" })).toBeVisible();
});

test("正式发布必须本人核对，重复点击只发送一次确认并展示真实结果", async ({
  page,
}) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps/actions/action-one");
  await expect(page.getByText(action.payload.content)).toBeVisible();
  await expect(page.getByRole("button", { name: "确认并发布" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "确认并发布" })).toHaveAccessibleDescription(/请先核对全文/);
  await page.getByLabel("我已核对全文、回复目标和发布账号").check();
  await page.getByRole("button", { name: "确认并发布" }).click();
  await expect(page.getByRole("button", { name: "正在提交…" })).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "查看真实帖子" }),
  ).toHaveAttribute("href", "/web/post/123");
  const decisions = writes.filter((x) => x.path.endsWith("/decision"));
  expect(decisions).toHaveLength(1);
  expect(decisions[0].body).toMatchObject({
    confirmation_nonce: "approval-nonce",
    draft_version: 1,
    payload_hash: "hash-one",
    allow: true,
  });
});

test("过旧登录只要求当前账号密码，不跳完整登录或自动授权", async ({ page }) => {
  const writes = await fixture(page, { recent: true });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "无需重新登录",
  );
  await expect(
    page.getByLabel("当前账号密码", { exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("邮箱或账号")).toHaveCount(0);
  expect(writes.filter((x) => x.path.endsWith("/decision"))).toHaveLength(0);
});

test("当前会话密码验证后保留设备代码并重读请求，错误密码可重试", async ({ page }) => {
  const options = { recent: true }, writes = await fixture(page, options);
  const attempts: Record<string, unknown>[] = [];
  let fullLogins = 0;
  await page.route("**/api/login", route => { fullLogins++; return route.fulfill({ status: 500 }); });
  await page.route("**/api/auth/reauthenticate", route => {
    const body = route.request().postDataJSON(); attempts.push(body);
    if (body.password !== "synthetic-password") return route.fulfill({ status: 403, json: { code: "reauthentication_failed", message: "密码不正确，请重新输入" } });
    options.recent = false;
    return route.fulfill({ json: { authenticated: true, user_id: 991 } });
  });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await page.getByLabel("当前账号密码", { exact: true }).fill("wrong-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect(page.getByText("密码不正确，请重新输入", { exact: true })).toBeVisible();
  await expect(page.getByLabel("当前账号密码", { exact: true })).toHaveValue("");
  await expect(page.getByLabel("设备代码", { exact: true })).toHaveValue("ABCD-1234");
  await page.getByLabel("当前账号密码", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toBeVisible();
  await expect(page.getByLabel("我已核对设备代码与当前账号，并了解外发范围")).not.toBeChecked();
  expect(fullLogins).toBe(0);
  expect(attempts).toEqual([{ password: "wrong-password", expected_user_id: 991 }, { password: "synthetic-password", expected_user_id: 991 }]);
  expect(writes.filter(x => x.path.endsWith("/decision"))).toHaveLength(0);
});

test("验证取消后迟到响应不会自动继续，期间不会重复提交", async ({ page }) => {
  await fixture(page, { recent: true });
  let resolve!: () => void, requests = 0, lookups = 0;
  await page.route("**/api/connected-apps/device-requests/lookup", route => { lookups++; return route.fulfill({ status: 403, json: { code: "recent_authentication_required" } }); });
  await page.route("**/api/auth/reauthenticate", async route => {
    requests++;
    await new Promise<void>(done => { resolve = done; });
    await route.fulfill({ json: { authenticated: true, user_id: 991 } }).catch(() => {});
  });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await page.getByLabel("当前账号密码", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect(page.getByRole("button", { name: "正在验证…", exact: true })).toBeDisabled();
  await expect.poll(() => requests).toBe(1);
  await page.getByRole("button", { name: "取消验证", exact: true }).click();
  resolve();
  await expect(page.getByLabel("当前账号密码", { exact: true })).toHaveValue("");
  await expect(page.getByText("signal is aborted", { exact: false })).toHaveCount(0);
  expect(lookups).toBe(1);
  expect(requests).toBe(1);
});

test("密码验证限流保留页面且不当作账号退出", async ({ page }) => {
  await fixture(page, { recent: true });
  await page.route("**/api/auth/reauthenticate", route => route.fulfill({ status: 429, json: { code: "reauthentication_throttled", message: "验证次数过多，请稍后重试" } }));
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await page.getByLabel("当前账号密码", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect(page.getByText("验证次数过多，请稍后重试", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "登录状态已失效，重新登录", exact: true })).toHaveCount(0);
  await expect(page.getByLabel("设备代码", { exact: true })).toHaveValue("ABCD-1234");
});

test("草稿补充密码验证后仍需重新核对，不能自动重放发布", async ({ page }) => {
  await fixture(page);
  let verified = false, publishAttempts = 0;
  await page.route("**/api/connected-apps/actions/action-one/decision", route => {
    publishAttempts++;
    return route.fulfill({ status: verified ? 500 : 403, json: { code: verified ? "unexpected_replay" : "recent_authentication_required" } });
  });
  await page.route("**/api/auth/reauthenticate", route => { verified = true; return route.fulfill({ json: { authenticated: true, user_id: 991 } }); });
  await page.goto("./connected-apps/actions/action-one");
  await page.getByLabel("我已核对全文、回复目标和发布账号").check();
  await page.getByRole("button", { name: "确认并发布", exact: true }).click();
  await page.getByLabel("当前账号密码", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect(page.getByLabel("当前账号密码", { exact: true })).toHaveCount(0);
  await expect(page.getByLabel("我已核对全文、回复目标和发布账号")).not.toBeChecked();
  await expect(page.getByRole("button", { name: "确认并发布", exact: true })).toBeDisabled();
  expect(publishAttempts).toBe(1);
});

test("验证中跨标签切号不会把旧响应当作新账号的验证或授权", async ({ page }) => {
  const writes = await fixture(page, { recent: true });
  let userId = 991, release!: () => void, pending = false;
  await page.route("**/api/user/profile", route => route.fulfill({ json: { id: userId, nickname: `合成账号${userId}`, role: "user" } }));
  await page.route("**/api/auth/reauthenticate", async route => {
    pending = true;
    await new Promise<void>(resolve => { release = resolve; });
    await route.fulfill({ json: { authenticated: true, user_id: 991 } }).catch(() => {});
  });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await page.getByLabel("当前账号密码", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "验证并继续", exact: true }).click();
  await expect.poll(() => pending).toBe(true);
  userId = 992;
  await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  await expect(page.getByText(/当前账号：合成账号992/)).toBeVisible();
  release();
  await expect(page.getByRole("button", { name: "授权此助手", exact: true })).toHaveCount(0);
  await expect(page.getByText("signal is aborted", { exact: false })).toHaveCount(0);
  expect(writes.filter(value => value.path.endsWith("/decision"))).toHaveLength(0);
});

for (const theme of ["light", "dark"]) for (const width of [390, 1440]) {
  test(`${theme}-${width}px当前账号密码验证可操作`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await fixture(page, { recent: true });
    await page.goto("./connected-apps?user_code=ABCD-1234");
    await page.getByRole("button", { name: "查看授权请求" }).click();
    await expect(page.getByLabel("当前账号密码", { exact: true })).toBeFocused();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: test.info().outputPath(`password-verification-${theme}-${width}.png`), fullPage: true });
  });
}

test("草稿读取失败可重试，来源变化禁止发布", async ({ page }) => {
  await fixture(page);
  let calls = 0;
  await page.route("**/api/connected-apps/actions/action-one", (route) =>
    route.fulfill(
      calls++ === 0
        ? { status: 503, json: { code: "integration_unavailable" } }
        : { status: 409, json: { code: "source_changed" } },
    ),
  );
  await page.goto("./connected-apps/actions/action-one");
  await expect(
    page.getByRole("button", { name: "重新加载", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "重新加载", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("原帖或回复内容已变化");
  await expect(page.getByRole("button", { name: "确认并发布" })).toHaveCount(0);
});

test("账号切换中止旧授权请求，旧账号响应不能恢复确认按钮", async ({ page }) => {
  await fixture(page);
  let release!: () => void;
  const paused = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route(
    "**/api/connected-apps/device-requests/lookup",
    async (route) => {
      await paused;
      await route.fulfill({ json: consent }).catch(() => {});
    },
  );
  await page.goto("./connected-apps?user_code=ABCD-1234");
  const started = page.waitForRequest(
    "**/api/connected-apps/device-requests/lookup",
  );
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await started;
  await page.route("**/api/user/profile", (route) =>
    route.fulfill({
      json: { id: 992, nickname: "切换后的账号", role: "user" },
    }),
  );
  await page.evaluate(() => {
    const c = new BroadcastChannel("sylulive-auth");
    c.postMessage("changed");
    c.close();
  });
  await expect(page.getByText(/当前账号：切换后的账号/)).toBeVisible();
  release();
  await expect(page.getByRole("button", { name: "授权此助手" })).toHaveCount(0);
});

test("表情加载失败时阻止确认发布，可重试恢复实际图片", async ({ page }) => {
  await fixture(page);
  let imageFails = true;
  const groups = JSON.parse(
    readFileSync(
      new URL(
        "../../server/internal/handlers/sticker_assets/catalog.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const sticker = groups[0].items[0];
  await page.route("**/stickers/test_sticker", (route) =>
    imageFails
      ? route.fulfill({ status: 503 })
      : route.fulfill({
          contentType: sticker.mime_type,
          body: readFileSync(
            new URL(
              "../../server/internal/handlers/sticker_assets/" + sticker.file,
              import.meta.url,
            ),
          ),
        }),
  );
  await page.goto("./connected-apps/actions/action-one");
  await page.getByLabel("我已核对全文、回复目标和发布账号").check();
  await expect(
    page.getByText("表情未能加载，请重试并核对后再发布。"),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "确认并发布" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "确认并发布" })).toHaveAccessibleDescription(/先点「重新加载表情」/);
  imageFails = false;
  await page.getByRole("button", { name: "重新加载表情" }).click();
  await expect(page.getByRole("button", { name: "确认并发布" })).toBeEnabled();
  expect(
    await page
      .getByRole("img", { name: "内置表情 test_sticker" })
      .evaluate((img: HTMLImageElement) => img.naturalWidth),
  ).toBeGreaterThan(0);
});

for (const width of [375, 1440])
  test(`授权与确认在${width}px真实渲染无横向溢出`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await fixture(page);
    await page.goto("./connected-apps?user_code=ABCD-1234");
    await page.getByRole("button", { name: "查看授权请求" }).click();
    await expect(
      page.getByRole("button", { name: "授权此助手" }),
    ).toBeVisible();
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    ).toBe(true);
    await page.screenshot({
      path: `test-results/connected-apps-${width}.png`,
      fullPage: true,
    });
    await page.goto("./connected-apps/actions/action-one");
    await expect(page.getByText(action.payload.content)).toBeVisible();
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    ).toBe(true);
    await page.screenshot({
      path: `test-results/connected-action-${width}.png`,
      fullPage: true,
    });
  });
