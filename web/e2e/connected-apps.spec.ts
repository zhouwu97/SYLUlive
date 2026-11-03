import { readFileSync } from "node:fs";
import { test, expect, type Page } from "@playwright/test";

for (const [theme, width] of [["light", 375], ["dark", 1440]] as const) {
  test(`机器人心跳状态刷新和失败恢复不覆盖资料草稿 ${theme}`, async ({page}) => {
    await page.addInitScript(theme => localStorage.setItem("sylulive-theme", theme), theme);
    await page.setViewportSize({width, height:1000});
    await page.clock.install();
    const writes = await fixture(page);
    let mode = "loading", requests = 0;
    const now = new Date().toISOString();
    await page.route("**/api/connected-apps/bot**", async route => {
      const path = new URL(route.request().url()).pathname;
      const runtime = {state:mode, last_seen_at:now, last_read_at:now, next_run_at:now,
        last_action:{kind:"reply", completed_at:now, post_id:1, reply_id:2}};
      if (path.endsWith("/runtime")) {
        requests++;
        return mode === "failed" ? route.fulfill({status:503, json:{code:"unavailable"}}) : route.fulfill({json:{runtime}});
      }
      return route.fulfill({json:{
        bot:{bot_user_id:2001, name:"合成机器人", avatar:"", enabled:true, owner:{id:991,nickname:"合成账号"}, policy:{...defaultPolicy}},
        policy_supported:true, sections:[{slug:"campus_life",name:"校园生活"}], runtime_supported:true, runtime,
        auto_reply_server_enabled:true, auto_reply_authorized:true
      }});
    });
    await page.goto("./connected-apps");
    const runtime = page.getByRole("region", {name:"后台运行状态"});
    await expect(runtime.getByText("正在浏览", {exact:true})).toBeVisible();
    await page.getByLabel("机器人名称", {exact:true}).fill("未保存的名字");
    await runtime.screenshot({path:test.info().outputPath(`runtime-${theme}.png`)});
    const before = requests;
    mode = "offline";
    await page.clock.fastForward(31000);
    await expect.poll(()=>requests).toBeGreaterThan(before);
    await expect(runtime.getByText("执行端离线或尚未连接", {exact:true})).toBeVisible();
    await expect(page.getByLabel("机器人名称", {exact:true})).toHaveValue("未保存的名字");
    mode = "failed";
    await runtime.getByRole("button", {name:"刷新运行状态", exact:true}).click();
    await expect(runtime.getByText("运行状态尚未核验", {exact:true})).toBeVisible();
    await expect(page.getByLabel("机器人名称", {exact:true})).toHaveValue("未保存的名字");
    mode = "completed";
    await runtime.getByRole("button", {name:"刷新运行状态", exact:true}).click();
    await expect(runtime.getByText("本轮已完成", {exact:true})).toBeVisible();
    expect(writes).toHaveLength(0);
    expect(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}

test('自动发帖和配图默认关闭，独立保存并授权，不继承评论权限',async({page})=>{
  const writes=await fixture(page,{postEnabled:true});
  await page.goto('./connected-apps?user_code=ABCD-1234');
  const post=page.getByLabel('自动发布帖子',{exact:false}),image=page.getByLabel('使用已审核公开配图',{exact:false});
  await expect(post).not.toBeChecked();await expect(image).not.toBeChecked();await expect(image).toBeDisabled();
  await page.getByRole('button',{name:'新建机器人',exact:true}).click();
  await post.check();await image.check();
  await page.getByRole('button',{name:'保存资料与权限',exact:true}).click();
  await expect.poll(()=>writes.filter(w=>w.path.endsWith('/bot')).length).toBe(2);
  expect(writes.filter(w=>w.path.endsWith('/bot')).at(-1)!.body.policy).toMatchObject({post_enabled:true,image_enabled:true,reply_enabled:false,sticker_enabled:false});
  await page.getByRole('button',{name:'查看授权请求',exact:true}).click();
  const grant=page.getByRole('checkbox',{name:/以独立AI机器人自动发帖/});
  await expect(grant).not.toBeChecked();await grant.check();
  await page.getByRole('checkbox',{name:/我已核对设备代码与当前账号/}).check();
  await expect(page.getByRole('button',{name:'授权此助手',exact:true})).toBeDisabled();
  await page.getByRole('checkbox',{name:'创建待本人确认的帖子或评论草稿',exact:true}).check();
  await page.getByRole('button',{name:'授权此助手',exact:true}).click();
  await expect.poll(()=>writes.some(w=>w.path.endsWith('/decision'))).toBe(true);
  const decision=writes.find(w=>w.path.endsWith('/decision'))!;
  expect(decision.body.scopes).toContain('community:bot_post');
  expect(decision.body.scopes).not.toContain('community:bot_reply');
});

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
    "community:bot_reply",
    "community:bot_post",
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
const defaultPolicy = {
  post_enabled: false, image_enabled: false,
  public_read_enabled: true, reply_enabled: false, sticker_enabled: false,
  allowed_post_types: ["campus_life", "course_study"], blocked_terms: [] as string[],
  block_links: true, daily_reply_limit: 3, min_reply_interval_minutes: 30,
};
async function fixture(
  page: Page,
  options: { recent?: boolean; slow?: boolean; postEnabled?: boolean } = {},
) {
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  let decisions = 0;
  let bot: { bot_user_id: number; name: string; enabled: boolean; avatar: string; owner: { id: number; nickname: string }; policy: typeof defaultPolicy } | null = null;
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
      writes.push({ path, body: path === "/api/upload" ? { upload: true } : request.postDataJSON() });
    if (path === "/api/upload") return route.fulfill({ json: { url: "/uploads/bot-avatar.png", file_id: 123 } });
    if (path === "/api/user/profile")
      return route.fulfill({
        json: { id: 991, nickname: "合成账号", role: "user" },
      });
    if (path === "/api/connected-apps")
      return route.fulfill({ json: { bindings: [] } });
    if (path === "/api/connected-apps/bot") {
      if (request.method() === "POST") {
        const body = request.postDataJSON();
        bot = { bot_user_id: 2001, name: bot?.name || "大肥鱼", avatar: "", owner: { id: 991, nickname: "合成账号" }, policy: { ...defaultPolicy }, ...bot, ...body };
      }
      return route.fulfill({ json: { bot, policy_supported: true, sections: [{ slug: "campus_life", name: "校园生活" }, { slug: "course_study", name: "课程学习" }, { slug: "campus_activity", name: "校园活动" }], auto_reply_server_enabled: false, auto_reply_authorized: false, auto_post_server_enabled:options.postEnabled===true,auto_post_authorized:false } });
    }
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
  await page.route("**/uploads/bot-avatar.png", route => route.fulfill({ contentType: sticker.mime_type, body: readFileSync(new URL("../../server/internal/handlers/sticker_assets/" + sticker.file, import.meta.url)) }));
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
  await expect(page.getByLabel(/以本人管理的独立AI机器人自动评论/)).not.toBeChecked();
  await expect(page.getByLabel("查看本人签到状态，并按本人指令每日签到（不含补签）")).not.toBeChecked();
  await expect(page.getByRole("button", { name: "授权此助手" })).toBeDisabled();
  await page.getByLabel("我已核对设备代码与当前账号，并了解外发范围").check();
  await page.getByRole("button", { name: "授权此助手" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "已授权。" }),
  ).toBeVisible();
  const decision = writes.find((x) => x.path.endsWith("/decision"))!;
  expect(decision.body.scopes).not.toContain("community:propose");
  expect(decision.body.scopes).not.toContain("checkin:write");
  expect(decision.body.scopes).not.toContain("community:bot_reply");
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

test("机器人新建头像权限编辑启用暂停完整链路，自动评论授权默认不选", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await expect(page.getByText("尚未创建机器人", {exact: true})).toBeVisible();
  await page.getByLabel("机器人名称").fill("本鱼");
  await expect(page.getByLabel("自动文字评论", { exact: false })).not.toBeChecked();
  await expect(page.getByLabel("发表内置表情", { exact: false })).not.toBeChecked();
  await page.getByRole("button", {name: "新建机器人", exact: true}).click();
  await expect(page.getByText("机器人 #2001 · 已暂停")).toBeVisible();
  expect(writes.find(w => w.path.endsWith("/bot"))!.body).toEqual({name: "本鱼", avatar: "", enabled: false, policy: defaultPolicy});
  await expect(page.getByText("合成账号 的 AI", { exact: false })).toBeVisible();
  await page.getByLabel("上传机器人头像").setInputFiles({ name: "avatar.png", mimeType: "image/png", buffer: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7ioAAAAASUVORK5CYII=", "base64") });
  await expect(page.getByText("头像已上传，保存机器人资料后会公开显示。", { exact: true })).toBeVisible();
  await expect.poll(() => page.getByRole("img", { name: "机器人头像", exact: true }).evaluate((image: HTMLImageElement) => image.naturalWidth)).toBeGreaterThan(0);
  await page.getByLabel("自动文字评论", { exact: false }).check();
  await page.getByLabel("发表内置表情", { exact: false }).check();
  await page.getByLabel("课程学习", { exact: true }).uncheck();
  await page.getByLabel("屏蔽词", { exact: true }).fill("禁止词\n私人资料");
  await page.getByLabel("每 24 小时最多评论数").selectOption("1");
  await page.getByLabel("评论间隔（分钟）").fill("90");
  await page.getByRole("button", {name: "保存资料与权限"}).click();
  expect(writes.filter(w => w.path.endsWith("/bot")).at(-1)!.body).toMatchObject({name:"本鱼",avatar:"/uploads/bot-avatar.png",enabled:false,policy:{...defaultPolicy,reply_enabled:true,sticker_enabled:true,allowed_post_types:["campus_life"],blocked_terms:["禁止词","私人资料"],daily_reply_limit:1,min_reply_interval_minutes:90}});
  await page.locator(".bot-panel").screenshot({ path: "scratch/bot-management-20261102/web-bot-managed-light.png", style: ".topbar {visibility:hidden !important;}" });
  await page.getByRole("button", {name: "保存并启用", exact: true}).click();
  await expect(page.getByText("机器人 #2001 · 已启用")).toBeVisible();
  await page.getByLabel("机器人名称").fill("尚未保存的名字");
  await page.getByRole("button", {name: "暂停机器人", exact: true}).click();
  await expect(page.getByText("机器人 #2001 · 已暂停")).toBeVisible();
  expect(writes.filter(w => w.path.endsWith("/bot")).at(-1)!.body).toEqual({enabled:false});
  await expect(page.getByLabel("机器人名称")).toHaveValue("尚未保存的名字");
  await expect(page.getByText("群聊只保留短期上下文，不写长期记忆。", {exact: true})).toBeVisible();
  await page.getByRole("button", {name: "查看授权请求"}).click();
  await page.getByLabel("我已核对设备代码与当前账号，并了解外发范围").check();
  await page.getByLabel(/以本人管理的独立AI机器人自动评论/).check();
  await expect(page.getByRole("button", {name:"授权此助手"})).toBeDisabled();
  await page.getByLabel("创建待本人确认的帖子或评论草稿").check();
  await expect(page.getByRole("button", {name:"授权此助手"})).toBeEnabled();
  // 暂停中的独立账号与评论授权条件同屏可核对。
  await page.screenshot({path: test.info().outputPath("bot-management.png"), fullPage:true});
});

test("机器人读取有加载反馈，失败可重试且不伪造账号状态", async ({ page }) => {
  await fixture(page);
  let fail = true, first = true;
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps/bot", async route => {
    if (first) { first = false; await pending; }
    await route.fulfill(fail ? {status:503,json:{code:"integration_unavailable"}}
      : {json:{bot:null,policy_supported:true,sections:[{slug:"campus_life",name:"校园生活"}],auto_reply_server_enabled:false,auto_reply_authorized:false}});
  });
  await page.goto("./connected-apps");
  const panel = page.locator(".bot-panel");
  await expect(panel.getByRole("status").filter({hasText:"正在加载"})).toBeVisible();
  await expect(panel.getByText("尚未创建机器人", {exact:true})).toHaveCount(0);
  await panel.screenshot({path:"scratch/bot-management-20261102/web-bot-loading.png",style:".topbar {visibility:hidden !important;}"});
  release();
  const retry = panel.getByRole("button",{name:"重试读取机器人状态"});
  await expect(retry).toBeVisible();
  await expect(retry).toHaveCount(1);
  expect((await renderedBotContrast(page)).filter(item => item.ratio < 4.5)).toEqual([]);
  await panel.screenshot({path:"scratch/bot-management-20261102/web-bot-error.png",style:".topbar {visibility:hidden !important;}"});
  fail = false;
  await retry.click();
  await expect(panel.getByText("尚未创建机器人",{exact:true})).toBeVisible();
});

test("未升级的服务明确不可用，旧服务权限不能伪保存", async ({ page }) => {
  const writes = await fixture(page);
  await page.route("**/api/connected-apps/bot", route => route.fulfill({ status: 404, json: { code: "resource_unavailable" } }));
  await page.goto("./connected-apps");
  const panel = page.locator(".bot-panel");
  await expect(panel.getByRole("alert")).toContainText("当前服务端尚未支持机器人管理");
  await expect(panel.getByText("尚未创建机器人", { exact: true })).toHaveCount(0);
  await expect(panel.getByRole("button", { name: "新建机器人", exact: true })).toHaveCount(0);
  await page.route("**/api/connected-apps/bot", route => route.fulfill({ json: { bot: null, auto_reply_server_enabled: false, auto_reply_authorized: false } }));
  await panel.getByRole("button", { name: "重试读取机器人状态" }).click();
  await expect(panel.getByRole("alert")).toContainText("尚未支持头像与社区权限管理");
  await expect(panel.getByRole("button", { name: "新建机器人", exact: true })).toBeDisabled();
  await expect(panel.getByLabel("浏览公开社区", { exact: false })).toBeDisabled();
  expect(writes.filter(write => write.path.endsWith("/bot"))).toHaveLength(0);
});

test("保存失败保留名字和权限草稿，重复点击只产生一次创建", async ({ page }) => {
  await fixture(page);
  let requests = 0, release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/connected-apps/bot", async route => {
    if (route.request().method() === "GET") return route.fallback();
    requests++;
    await pending;
    return route.fulfill({ status: 503, json: { code: "integration_unavailable" } });
  });
  await page.goto("./connected-apps");
  await page.getByLabel("机器人名称").fill("失败后仍保留");
  await page.getByLabel("自动文字评论", { exact: false }).check();
  await page.getByLabel("屏蔽词", { exact: true }).fill("私人资料");
  const create = page.getByRole("button", { name: "新建机器人", exact: true });
  await create.dblclick();
  await expect(page.locator(".bot-panel").getByRole("button", { name: "正在保存…" })).toBeDisabled();
  expect(requests).toBe(1);
  release();
  await expect(page.locator(".bot-panel").getByRole("alert")).toContainText("服务暂时不可用");
  await expect(page.getByLabel("机器人名称")).toHaveValue("失败后仍保留");
  await expect(page.getByLabel("屏蔽词", { exact: true })).toHaveValue("私人资料");
  await expect(page.getByLabel("自动文字评论", { exact: false })).toBeChecked();
  await expect(page.getByText("机器人 #2001", { exact: false })).toHaveCount(0);
});

test("公共读取总闸关闭时停用发言权限，限制规则输入不能绕过", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  await page.getByLabel("自动文字评论", { exact: false }).check();
  await page.getByLabel("发表内置表情", { exact: false }).check();
  await page.getByLabel("浏览公开社区", { exact: false }).uncheck();
  await expect(page.getByLabel("自动文字评论", { exact: false })).toBeChecked();
  await expect(page.getByLabel("自动文字评论", { exact: false })).toBeDisabled();
  await expect(page.getByLabel("发表内置表情", { exact: false })).toBeChecked();
  await expect(page.getByLabel("校园生活", { exact: true })).toBeDisabled();
  await page.getByLabel("评论间隔（分钟）").fill("29");
  await expect(page.getByRole("button", { name: "新建机器人", exact: true })).toBeDisabled();
  await page.getByLabel("评论间隔（分钟）").fill("30");
  await page.getByLabel("屏蔽词", { exact: true }).fill("长".repeat(25));
  await page.getByRole("button", { name: "新建机器人", exact: true }).click();
  await expect(page.locator(".bot-panel").getByRole("alert")).toContainText("屏蔽词最多 20 个");
  expect(writes.filter(write => write.path.endsWith("/bot"))).toHaveLength(0);
});

test("头像坏文件可恢复，账号切换中止上传且不写入新账号", async ({ page }) => {
  const writes = await fixture(page);
  await page.goto("./connected-apps");
  await page.getByLabel("上传机器人头像").setInputFiles({ name: "broken.png", mimeType: "image/png", buffer: Buffer.from("not-an-image") });
  await expect(page.locator(".bot-panel").getByRole("alert")).toContainText("头像未能上传");
  expect(writes.filter(write => write.path === "/api/upload")).toHaveLength(0);
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/api/upload", async route => { await pending; await route.fulfill({ json: { url: "/uploads/bot-avatar.png", file_id: 123 } }).catch(() => {}); });
  const started = page.waitForRequest("**/api/upload");
  await page.getByLabel("上传机器人头像").setInputFiles({ name: "avatar.png", mimeType: "image/png", buffer: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7ioAAAAASUVORK5CYII=", "base64") });
  await started;
  await page.route("**/api/user/profile", route => route.fulfill({ json: { id: 992, nickname: "新账号", role: "user" } }));
  await page.evaluate(() => { const channel = new BroadcastChannel("sylulive-auth"); channel.postMessage("changed"); channel.close(); });
  await expect(page.getByText(/当前账号：新账号/)).toBeVisible();
  release();
  await expect(page.getByRole("button", { name: "选择头像", exact: true })).toBeEnabled();
  await expect(page.getByRole("img", { name: "机器人头像", exact: true })).toHaveCount(0);
  await expect(page.getByText("头像已上传，保存机器人资料后会公开显示。", { exact: true })).toHaveCount(0);
  expect(writes.filter(write => write.path.endsWith("/bot"))).toHaveLength(0);
});

test("设备授权刷新实际条件时保留未保存的机器人草稿", async ({ page }) => {
  await fixture(page);
  await page.goto("./connected-apps?user_code=ABCD-1234");
  await page.getByLabel("机器人名称").fill("尚未保存的机器人");
  await page.getByLabel("屏蔽词", { exact: true }).fill("不公开资料");
  await page.getByRole("button", { name: "查看授权请求" }).click();
  await page.getByLabel("我已核对设备代码与当前账号，并了解外发范围").check();
  await page.getByRole("button", { name: "授权此助手" }).click();
  await expect(page.getByRole("status").filter({ hasText: "已授权。" })).toBeVisible();
  await expect(page.getByLabel("机器人名称")).toHaveValue("尚未保存的机器人");
  await expect(page.getByLabel("屏蔽词", { exact: true })).toHaveValue("不公开资料");
});

async function renderedBotContrast(page: Page) {
  await page.evaluate(() => scrollTo(0, 0));
  const screenshot = await page.screenshot({ fullPage: true, scale: "css", style: ".topbar { visibility: hidden !important; }" });
  return page.evaluate(async (data) => {
    const image = new Image();
    image.src = data;
    await image.decode();
    const shot = document.createElement("canvas");
    shot.width = image.width; shot.height = image.height;
    const pixels = shot.getContext("2d")!;
    pixels.drawImage(image, 0, 0);
    const ink = document.createElement("canvas").getContext("2d")!;
    const luminance = (rgb: ArrayLike<number>) => {
      const values = Array.from(rgb).slice(0, 3).map(c => c / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
      return .2126 * values[0] + .7152 * values[1] + .0722 * values[2];
    };
    // 从实际栅格化截图采样文字旁的底色，验证共享主题下的实际卡片和控件底色。
    // 原生checkbox不绘制文字，单独核对选中态；正文对比不把其勾号当作input文字。
    return Array.from(document.querySelectorAll<HTMLElement>(".bot-panel .integration-description, .bot-panel .integration-hint, .bot-panel dt, .bot-panel dd, .bot-panel .bot-account-state, .bot-panel .bot-owner, .bot-panel h2, .bot-panel h3, .bot-panel h4, .bot-panel legend, .bot-panel strong, .bot-panel small, .bot-panel .bot-privacy p, .bot-panel .btn, .bot-panel input:not([type=checkbox]):not([hidden]), .bot-panel textarea, .bot-panel select, .bot-panel .integration-feedback p")).map(el => {
      const rect = el.getBoundingClientRect(), panel = el.closest(".integration-panel")!.getBoundingClientRect();
      const control = el.matches("button,input,textarea,select");
      const x = Math.round((control ? rect.left + 6 : Math.min(rect.right + 2, panel.right - 6)) + scrollX);
      // 胶囊按钮的左上角属于外部背景；在左侧中线采样实际控件底色。
      const y = Math.round(rect.top + (control ? rect.height / 2 : 2) + scrollY);
      if (x < 0 || y < 0 || x >= shot.width || y >= shot.height) throw new Error("对比度采样越出截图范围");
      ink.clearRect(0, 0, 1, 1);
      ink.fillStyle = getComputedStyle(el).color; ink.fillRect(0, 0, 1, 1);
      const a = luminance(ink.getImageData(0, 0, 1, 1).data), b = luminance(pixels.getImageData(x, y, 1, 1).data);
      return { text: (el.innerText || el.getAttribute("aria-label") || el.tagName).slice(0, 50), ratio: (Math.max(a, b) + .05) / (Math.min(a, b) + .05) };
    });
  }, "data:image/png;base64," + screenshot.toString("base64"));
}

for (const theme of ["light", "dark"]) for (const width of [375, 1440]) {
  test(`机器人管理 ${theme} ${width}px 保留完整文字和操作`, async ({page}) => {
    await page.addInitScript(theme => localStorage.setItem("sylulive-theme", theme), theme);
    await page.setViewportSize({width,height:1000});
    await fixture(page);
    await page.goto("./connected-apps");
    const panel = page.locator(".bot-panel");
    const create = panel.getByRole("button",{name:"新建机器人",exact:true});
    await expect(create).toBeVisible();
    await expect(panel.getByText("尚未创建机器人",{exact:true})).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    expect(await panel.evaluate(el => getComputedStyle(el).backdropFilter)).toBe("none");
    const palette = await panel.evaluate(el => {
      const sample = document.createElement("span");
      sample.style.backgroundColor = "var(--color-surface)";
      el.append(sample);
      const surface = getComputedStyle(sample).backgroundColor;
      sample.style.backgroundColor = "var(--color-accent-fill)";
      const accent = getComputedStyle(sample).backgroundColor;
      sample.remove();
      return {surface, accent, actualSurface: getComputedStyle(el).backgroundColor, actualAccent: getComputedStyle(el.querySelector(".btn.primary")!).backgroundColor};
    });
    expect(palette.actualSurface).toBe(palette.surface);
    expect(palette.actualAccent).toBe(palette.accent);
    expect((await renderedBotContrast(page)).filter(item => item.ratio < 4.5)).toEqual([]);
    await page.getByLabel("机器人名称").fill("");
    await expect(create).toBeDisabled();
    expect((await renderedBotContrast(page)).filter(item => item.ratio < 4.5)).toEqual([]);
    await page.getByLabel("机器人名称").fill("大肥鱼");
    await page.getByLabel("机器人名称").focus();
    await create.focus();
    await expect(create).toBeFocused();
    expect(await create.evaluate(el => getComputedStyle(el).outlineWidth)).toBe("2px");
    expect(await create.evaluate(el => el.getBoundingClientRect().height)).toBeGreaterThanOrEqual(44);
    await page.reload();
    await expect(create).toBeVisible();
    expect(await panel.evaluate(el => getComputedStyle(el).backdropFilter)).toBe("none");
    await panel.screenshot({path:`scratch/bot-management-20261102/web-bot-create-${theme}-${width}.png`, style: ".topbar { visibility: hidden !important; }"});
    await page.evaluate(() => scrollTo(0, 0));
    await page.screenshot({path:`scratch/bot-management-20261102/web-workspace-${theme}-${width}.png`, fullPage:true});
  });
}

test("助手实色卡片在系统降透明度和高对比模式下仍可操作", async ({page}) => {
  await fixture(page);
  await page.goto("./connected-apps");
  const panel = page.locator(".bot-panel");
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setEmulatedMedia", {features:[{name:"prefers-reduced-transparency", value:"reduce"}]});
  expect(await panel.evaluate(el => getComputedStyle(el).backdropFilter)).toBe("none");
  await cdp.send("Emulation.setEmulatedMedia", {features:[]});
  await page.emulateMedia({ forcedColors:"active" });
  await expect(panel.getByRole("button", {name:"新建机器人", exact:true})).toBeEnabled();
  expect(await panel.evaluate(el => getComputedStyle(el).backdropFilter)).toBe("none");
});

test("历史助手毛玻璃偏好不覆盖新版社区主题", async ({page}) => {
  await page.addInitScript(() => localStorage.setItem("sylulive-integrations-glass", "on"));
  await fixture(page);
  await page.goto("./connected-apps");
  await expect(page.getByRole("button", {name:/^毛玻璃/})).toHaveCount(0);
  await expect(page.locator(".bot-panel").getByRole("button", {name:"新建机器人", exact:true})).toBeEnabled();
  expect(await page.locator(".bot-panel").evaluate(el => getComputedStyle(el).backdropFilter)).toBe("none");
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
