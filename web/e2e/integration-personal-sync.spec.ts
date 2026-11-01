import { test, expect } from "@playwright/test";

test("服务端关闭时不允许本机读取和上传但保留删除入口", async ({page}) => {
  await page.route('**/api/**', route => {
    const path=new URL(route.request().url()).pathname;
    if(path==='/api/user/profile')return route.fulfill({json:{id:7,nickname:'合成用户',role:'user'}});
    if(path==='/api/connected-apps')return route.fulfill({json:{bindings:[],personal_data_enabled:false}});
    return route.fulfill({json:{}});
  });
  await page.goto('/web/connected-apps');
  await expect(page.getByText(/服务端尚未开放个人查询/)).toBeVisible();
  await expect(page.getByRole('button',{name:'从本机教务助手读取'})).toBeDisabled();
  await expect(page.getByRole('button',{name:'确认同步最小资料'})).toBeDisabled();
  await page.getByRole('checkbox',{name:/我确认仅操作当前账号/}).check();
  await expect(page.getByRole('button',{name:'删除该类上传副本'})).toBeEnabled();
});

for (const dataset of ["grades", "erke"] as const) {
  test(`本人明确确认后才能同步${dataset}最小资料`, async ({ page }) => {
    const writes: { path: string; body: Record<string, unknown> }[] = [];
    await page.route("**/api/**", route => {
      const request = route.request(), path = new URL(request.url()).pathname;
      if (path === "/api/user/profile") return route.fulfill({ json: { id: 7, nickname: "合成同步用户", role: "user" } });
      if (path === "/api/connected-apps") return route.fulfill({ json: { bindings: [], personal_data_enabled: true } });
      if (path.includes("personal-sync") || path.includes("personal-snapshots")) {
        writes.push({ path, body: request.postDataJSON() });
        return route.fulfill({ json: { message: "已同步" } });
      }
      return route.fulfill({ json: {} });
    });
    await page.addInitScript(() => {
      window.addEventListener("message", event => {
        const request = event.data;
        if (request?.direction !== "request") return;
        const erke = request.payload?.dataset === "erke";
        const results: Record<string, unknown> = {
          hello: { version: 1 },
          session: { appUserId: 7, provider: request.payload?.provider, studentId: "do-not-upload-student-id", displayName: "合成同步用户", epoch: "synthetic-epoch" },
          query: { version: 1, provider: erke ? "erke" : "undergraduate", dataset: erke ? "erke" : "grades", term: { year: "2026", semester: "3" }, fetchedAt: new Date().toISOString(), studentId: "do-not-upload-student-id", parserVersion: 1,
            data: erke ? { earned: 8, required: 10, categories: [{ name: "志愿公益", earned: 1, required: 4 }] } : [{ id: "do-not-upload-internal-id", name: "同步测试课程", score: "优秀", credit: 2, gpa: 4, nature: "必修", term: "学校内部字段" }] },
        };
        window.postMessage({ ...request, direction: "response", ok: true, result: results[request.operation] }, location.origin);
      });
    });
    await page.goto("/web/connected-apps");
    await page.getByRole("combobox", { name: "资料类型" }).selectOption(dataset);
    const confirm = page.getByRole("button", { name: "确认同步最小资料" });
    await expect(confirm).toBeDisabled();
    await page.getByRole("button", { name: "从本机教务助手读取" }).click();
    await page.getByRole("button", { name: "连接并读取资料" }).click();
    await expect(page.getByText("资料已在本机准备，尚未上传。")).toBeVisible();
    expect(writes).toHaveLength(0);
    await expect(confirm).toBeDisabled();
    await page.getByRole("checkbox", { name: /我确认仅操作当前账号的资料/ }).check();
    await confirm.click();
    await expect.poll(() => writes.length).toBe(1);
    expect(JSON.stringify(writes)).not.toMatch(/do-not-upload|password|cookie|学校内部字段/);
    expect(writes[0].path).toBe(dataset === "grades" ? "/api/connected-apps/personal-sync/grades" : "/api/personal-snapshots/erke");
    await expect(page.getByText(/已同步最小资料/)).toBeVisible();
  });
}

test("二课接口退役时不声称副本已删除", async ({ page }) => {
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 7, nickname: "合成用户", role: "user" } });
    if (path === "/api/connected-apps") return route.fulfill({ json: { bindings: [], personal_data_enabled: false } });
    if (path === "/api/personal-snapshots/erke") return route.fulfill({ status: 410, json: { code: "SCHOOL_AUTHORITY_RETIRED" } });
    return route.fulfill({ json: {} });
  });
  await page.goto("/web/connected-apps");
  await page.getByRole("combobox", { name: "资料类型" }).selectOption("erke");
  await page.getByRole("checkbox", { name: /我确认仅操作当前账号/ }).check();
  await page.getByRole("button", { name: "删除该类上传副本" }).click();
  await expect(page.getByText(/服务端已停用二课云资料接口，本次操作未完成/)).toBeVisible();
  await expect(page.getByText(/该类上传副本已删除/)).toHaveCount(0);
});
