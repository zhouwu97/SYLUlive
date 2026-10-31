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
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await expect(
    page.getByLabel("公开帖子与评论、作者昵称、互动统计、公开图片和表情目录"),
  ).toBeVisible();
  await expect(page.getByText("本连接不提供站内私信", { exact: false })).toBeVisible();
  await page.screenshot({
    path: test.info().outputPath("consent-public-media.png"),
    fullPage: true,
  });
  const writeScope = page.getByLabel("创建待本人确认的帖子或评论草稿");
  await expect(writeScope).not.toBeChecked();
  await expect(page.getByRole("button", { name: "授权此助手" })).toBeDisabled();
  await page.getByLabel("我已核对设备代码与当前账号，并了解外发范围").check();
  await page.getByRole("button", { name: "授权此助手" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "已授权。" }),
  ).toBeVisible();
  const decision = writes.find((x) => x.path.endsWith("/decision"))!;
  expect(decision.body.scopes).not.toContain("community:propose");
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

test("过旧登录给出重新登录入口，不发送授权确认", async ({ page }) => {
  const writes = await fixture(page, { recent: true });
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "刷新页面或刷新凭证不能代替重新登录",
  );
  await expect(
    page.getByRole("button", { name: "重新登录验证" }),
  ).toBeVisible();
  expect(writes.filter((x) => x.path.endsWith("/decision"))).toHaveLength(0);
});

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
