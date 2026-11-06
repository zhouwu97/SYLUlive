import { test, expect } from "@playwright/test";
import { fillSchoolLogin } from "../../browser-extension/src/school-login-script";

test("学校脚本自动填写并通过原按钮提交，重复导航和验证码保留人工入口", async ({ page }) => {
  await page.route("https://jxw.sylu.edu.cn/**", route => route.fulfill({ contentType: "text/html; charset=utf-8", body: `<form><input id=yhm><input id=mm type=password><button id=dl type=button onclick="window.submitted={account:yhm.value,password:mm.value}">登录</button></form>` }));
  await page.goto("https://jxw.sylu.edu.cn/xtgl/login_slogin.html");
  const result = await page.evaluate('(' + fillSchoolLogin.toString() + ')("undergraduate",location.origin+location.pathname,"2099000001","synthetic-secret")');
  expect(result.state).toBe("submitted");
  expect(await page.evaluate("window.submitted")).toEqual({ account: "2099000001", password: "synthetic-secret" });
  await page.evaluate("window.submitted=null;document.querySelector('form').insertAdjacentHTML('beforeend','<input id=yzm>')");
  const manual = await page.evaluate('(' + fillSchoolLogin.toString() + ')("undergraduate",location.origin+location.pathname,"2099000001","synthetic-secret")');
  expect(manual.state).toBe("manual");
  expect(await page.evaluate("window.submitted")).toBeNull();
  const changed = await page.evaluate('(' + fillSchoolLogin.toString() + ')("undergraduate","https://other.example/login","2099000002","another-secret")');
  expect(changed.state).toBe("waiting");
  await expect(page.locator("#yhm")).toHaveValue("2099000001");
});

test("统一认证只填可见密码框，保留学校加密字段；跨源表单不填写", async ({ page }) => {
  await page.route("https://webvpn.sylu.edu.cn/**", route => route.fulfill({ contentType: "text/html; charset=utf-8", body: `<form><input id=username><input id=password type=hidden value=school-encrypted><input name=userPassword type=password><button id=login_submit type=button onclick="window.submitted=true">登录</button></form>` }));
  await page.goto("https://webvpn.sylu.edu.cn/authserver/login");
  const run = '(' + fillSchoolLogin.toString() + ')("vpn",location.origin+location.pathname,"2099000001","synthetic-cas-secret")';
  expect((await page.evaluate(run)).state).toBe("submitted");
  await expect(page.locator('[name="userPassword"]')).toHaveValue("synthetic-cas-secret");
  await expect(page.locator("#password")).toHaveValue("school-encrypted");
  await page.evaluate(() => { document.querySelector("form")!.action = "https://other.example/login"; (document.querySelector('[name="userPassword"]') as HTMLInputElement).value = ""; });
  expect((await page.evaluate(run)).state).toBe("manual");
  await expect(page.locator('[name="userPassword"]')).toHaveValue("");
});

test("正方页面重写 Array.some 后，自动填写仍通过学校原按钮提交", async ({ page }) => {
  await page.route("https://jxw.sylu.edu.cn/**", route => route.fulfill({ contentType: "text/html; charset=utf-8", body: `<form><input id=yhm><input id=mm type=password><button id=dl type=button onclick="window.submitted=true">登录</button></form>` }));
  await page.goto("https://jxw.sylu.edu.cn/xtgl/login_slogin.html");
  // 学校 jquery.extends.contact-min.js 覆盖原生数组方法，MAIN world 注入
  // 必须在这个真实边界上验证，不能只在干净的页面上测试 DOM 选择器。
  await page.evaluate(() => { Array.prototype.some = function () { throw new Error("school Array.some replacement"); }; });
  const result = await page.evaluate('(' + fillSchoolLogin.toString() + ')("undergraduate",location.origin+location.pathname,"2099000001","synthetic-secret")');
  expect(result.state).toBe("submitted");
  expect(await page.evaluate("window.submitted")).toBe(true);
});

for (const dataset of ["grades", "erke"]) {
  test(`${dataset}授权登录成功后自动续拉资料，第二次无需重开助手`, async ({ page }) => {
    const operations: string[] = [];
    await page.route("**/api/**", route => route.fulfill({ json: route.request().url().endsWith("/user/profile") ? { id: 7, nickname: "测试用户", role: "user" } : { ok: true } }));
    await page.route('**/api/student-identity/bind',route=>{
      expect(route.request().headers()['x-expected-app-user']).toBe('7');
      return route.fulfill({json:{ok:true}});
    });
    await page.addInitScript(({ dataset }) => {
      let ready = false, polls = 0;
      (window as any).__ops = [];
      window.addEventListener("message", event => {
        const request = event.data;
        if (request?.direction !== "request") return;
        (window as any).__ops.push(request.operation);
        let result: unknown;
        if (request.operation === "hello") result = { version: 1, automaticLogin: true };
        else if (request.operation === "session" && !ready) {
          window.postMessage({ ...request, direction: "response", ok: false, error: { code: "authorization_required", message: "首次需要授权" } }, location.origin); return;
        } else if (request.operation === "connect") result = { flowId: "test-flow", state: "awaiting_login" };
        else if (request.operation === "loginStatus") { ready = ++polls >= 2; result = { flowId: "test-flow", state: ready ? "ready" : "awaiting_login" }; }
        else if (request.operation === "session") result = { appUserId: 7, provider: dataset === "erke" ? "erke" : "undergraduate", studentId: "2099000001", displayName: "", epoch: "test-epoch" };
        else if (request.operation === "query") result = { fetchedAt: new Date().toISOString(), data: dataset === "grades" ? [{ id: "g1", name: "自动读取测试课程", credit: 2, score: "92", gpa: 4, nature: "必修", term: "2026-3" }] : { required: 10, earned: 8, categories: [{ name: "思想成长", required: 2, earned: 2 }] } };
        window.postMessage({ ...request, direction: "response", ok: true, result }, location.origin);
      });
    }, { dataset });
    await page.goto(dataset === "erke" ? "grades?tab=erke" : "grades");
    await page.getByRole("button", { name: "更新本地资料" }).click();
    await page.getByRole("button", { name: "连接并读取资料", exact: true }).click();
    await expect(page.locator(".dialog-form [role=status]")).toContainText("成功后自动返回");
    await expect(page.getByText(dataset === "grades" ? "自动读取测试课程" : "思想成长", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "更新本地资料" }).click();
    await page.getByRole("button", { name: "连接并读取资料", exact: true }).click();
    await expect(page.locator(".dialog-form")).toHaveCount(0);
    operations.push(...await page.evaluate(() => (window as any).__ops));
    expect(operations.filter(x => x === "connect")).toHaveLength(1);
    expect(operations.filter(x => x === "query")).toHaveLength(2);
  });
}

test("取消等待后不读取、不绑定，旧登录结果不能写回", async ({ page }) => {
  await page.route("**/api/**", route => route.fulfill({ json: { id: 7, nickname: "测试用户", role: "user" } }));
  await page.addInitScript(() => {
    (window as any).__ops = [];
    window.addEventListener("message", event => {
      const r = event.data;
      if (r?.direction !== "request") return;
      (window as any).__ops.push(r.operation);
      if (r.operation === "session") return window.postMessage({ ...r, direction: "response", ok: false, error: { code: "school_login_required", message: "会话过期" } }, location.origin);
      const result = r.operation === "hello" ? { version: 1, automaticLogin: true } : { flowId: "pending-flow", state: "awaiting_login" };
      window.postMessage({ ...r, direction: "response", ok: true, result }, location.origin);
    });
  });
  await page.goto("grades");
  await page.getByRole("button", { name: "更新本地资料" }).click();
  await page.getByRole("button", { name: "连接并读取资料", exact: true }).click();
  await expect(page.locator(".dialog-form [role=status]")).toContainText("成功后自动返回");
  await page.getByRole("button", { name: "取消连接" }).click();
  await expect(page.locator(".dialog-form [role=status]")).toContainText("原资料已保留");
  await expect(page.getByRole("button", { name: "连接并读取资料", exact: true })).toBeEnabled();
  expect(await page.evaluate(() => (window as any).__ops)).not.toContain("query");
});
