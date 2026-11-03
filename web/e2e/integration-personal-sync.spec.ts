import { test, expect, type Page } from "@playwright/test";

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
  await expect(page.getByRole('checkbox',{name:/我确认仅操作当前账号/})).toBeDisabled();
  await expect(page.getByRole('button',{name:'从本机教务助手读取'})).toHaveAccessibleDescription(/当前服务尚未开放个人查询/);
  await expect(page.getByRole('button',{name:'重新检查服务状态'})).toBeEnabled();
  await page.getByText('删除云端上传副本', {exact:true}).click();
  await page.getByRole('checkbox',{name:'确认删除当前选择的上传副本'}).check();
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
    await expect(confirm).toHaveAccessibleDescription(/请先点「从本机教务助手读取」/);
    await expect(page.getByRole('checkbox',{name:/我确认仅操作当前账号/})).toHaveAccessibleDescription(/有了资料预览后/);
    await page.getByRole("button", { name: "从本机教务助手读取" }).click();
    await page.getByRole("button", { name: "连接并读取资料" }).click();
    await expect(page.getByText("资料已在本机准备，尚未上传。")).toBeVisible();
    const preview = page.getByRole("region", { name: "待同步资料预览" });
    await expect(preview).toBeVisible();
    await expect(page.getByRole("status").filter({ hasText: "学校资料已更新" })).toHaveCount(0);
    await expect(preview.getByText("尚未上传", { exact: true })).toBeVisible();
    if (dataset === "grades") await expect(preview.getByRole("cell", { name: "同步测试课程", exact: true })).toBeVisible();
    else await expect(preview.getByText("志愿公益：还差 3 分", { exact: true })).toBeVisible();
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: test.info().outputPath(`sync-${dataset}-preview.png`), fullPage: true });
    expect(writes).toHaveLength(0);
    await expect(confirm).toBeDisabled();
    await expect(confirm).toHaveAccessibleDescription(/请先核对上方预览/);
    await page.getByRole("checkbox", { name: /我确认仅操作当前账号的资料/ }).check();
    await confirm.click();
    await expect.poll(() => writes.length).toBe(1);
    expect(JSON.stringify(writes)).not.toMatch(/do-not-upload|password|cookie|学校内部字段/);
    expect(writes[0].path).toBe(dataset === "grades" ? "/api/connected-apps/personal-sync/grades" : "/api/personal-snapshots/erke");
    await expect(page.getByText(/已同步最小资料/)).toBeVisible();
    await expect(page.getByText('本次上传已完成，待同步预览已清空。')).toBeVisible();
    await expect(confirm).toBeDisabled();
    await expect(confirm).toHaveAccessibleDescription(/本次已同步，确认项已重置/);
    await expect(page.getByRole('checkbox',{name:/我确认仅操作当前账号/})).toBeDisabled();
    const completed = page.getByRole('region',{name:'个人资料同步',exact:true});
    await completed.evaluate(node => node.scrollIntoView({block:'center'}));
    await completed.screenshot({path:test.info().outputPath(`sync-${dataset}-completed.png`)});
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
  await page.getByText('删除云端上传副本', {exact:true}).click();
  await page.getByRole("checkbox", { name: "确认删除当前选择的上传副本" }).check();
  await page.getByRole("button", { name: "删除该类上传副本" }).click();
  await expect(page.getByText(/服务端已停用二课云资料接口，本次操作未完成/)).toBeVisible();
  await expect(page.getByText(/该类上传副本已删除/)).toHaveCount(0);
});

async function syncFixture(page: Page, options: { stale?: boolean; holdWrite?: boolean; failWrite?: boolean } = {}) {
  const writes: { method: string; body: unknown }[] = [];
  let listFailed = false, writeFailed = !!options.failWrite, release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  if (!options.holdWrite) release();
  await page.route("**/api/**", async route => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 7, nickname: "合成同步用户", role: "user" } });
    if (path === "/api/connected-apps") return listFailed
      ? route.fulfill({ status: 503, json: { code: "temporary_unavailable" } })
      : route.fulfill({ json: { bindings: [], personal_data_enabled: true } });
    if (path.includes("personal-sync") || path.includes("personal-snapshots")) {
      writes.push({ method: request.method(), body: request.postDataJSON() });
      await gate;
      return writeFailed ? route.fulfill({ status: 503, json: { code: "temporary_unavailable" } }) : route.fulfill({ json: { message: "已同步" } });
    }
    return route.fulfill({ json: {} });
  });
  await page.addInitScript(stale => {
    window.addEventListener("message", event => {
      const request = event.data;
      if (request?.direction !== "request") return;
      const results: Record<string, unknown> = {
        hello: { version: 1 },
        session: { appUserId: 7, provider: "undergraduate", studentId: "private-id-not-uploaded", epoch: "synthetic-epoch" },
        query: { version: 1, provider: "undergraduate", dataset: "grades", term: { year: "2026", semester: "3" }, fetchedAt: new Date(Date.now() - (stale ? 6 * 86400000 : 0)).toISOString(), studentId: "private-id-not-uploaded", parserVersion: 1,
          data: Array.from({ length: 7 }, (_, i) => ({ id: `private-internal-${i}`, name: `同步测试课程 ${i + 1}`, score: "优秀", credit: 2, gpa: 4, nature: "必修" })) },
      };
      window.postMessage({ ...request, direction: "response", ok: true, result: results[request.operation] }, location.origin);
    });
  }, !!options.stale);
  return { writes, release, failList: () => { listFailed = true; }, restoreList: () => { listFailed = false; }, succeed: () => { writeFailed = false; } };
}
async function prepareGrades(page: Page) {
  await page.getByRole("button", { name: "从本机教务助手读取" }).click();
  await page.getByRole("button", { name: "连接并读取资料" }).click();
  await expect(page.getByRole("region", { name: "待同步资料预览" })).toBeVisible();
}

test("预览限定范围且标出过期资料，换资料类型不沿用旧确认", async ({ page }) => {
  const control = await syncFixture(page, { stale: true });
  await page.goto("/web/connected-apps");
  await prepareGrades(page);
  const preview = page.getByRole("region", { name: "待同步资料预览" });
  await expect(preview.getByRole("row")).toHaveCount(6);
  await expect(preview.getByText(/同步将包含本次读取的全部 7 门课程/)).toBeVisible();
  await expect(preview.getByText(/这份资料已超过 5 天/)).toBeVisible();
  await expect(preview.getByText(/private-id|private-internal/)).toHaveCount(0);
  await page.getByRole("checkbox", { name: /我确认仅操作当前账号/ }).check();
  await page.getByRole("combobox", { name: "资料类型" }).selectOption("erke");
  await expect(preview).toHaveCount(0);
  await expect(page.getByRole("checkbox", { name: /我确认仅操作当前账号/ })).not.toBeChecked();
  await expect(page.getByRole("button", { name: "确认同步最小资料" })).toBeDisabled();
  expect(control.writes).toHaveLength(0);
});

test("刷新失败不能沿用缓存的开放状态", async ({ page }) => {
  const control = await syncFixture(page);
  await page.goto("/web/connected-apps");
  await expect(page.getByRole("button", { name: "从本机教务助手读取" })).toBeEnabled();
  control.failList();
  await page.getByRole("button", { name: "刷新连接列表" }).click();
  await expect(page.getByText(/尚未确认服务端个人查询状态/)).toBeVisible();
  await expect(page.getByRole("button", { name: "从本机教务助手读取" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "确认同步最小资料" })).toBeDisabled();
  expect(control.writes).toHaveLength(0);
  control.restoreList();
  await page.getByRole('button',{name:'重新检查服务状态'}).click();
  await expect(page.getByRole('button',{name:'从本机教务助手读取'})).toBeEnabled();
  await expect(page.getByRole('button',{name:'确认同步最小资料'})).toHaveAccessibleDescription(/请先点「从本机教务助手读取」/);
});

test("同步不会重复提交，失败保留预览并允许本人重试", async ({ page }) => {
  const control = await syncFixture(page, { holdWrite: true, failWrite: true });
  try {
    await page.goto("/web/connected-apps");
    await prepareGrades(page);
    await page.getByRole("checkbox", { name: /我确认仅操作当前账号/ }).check();
    await page.getByRole("button", { name: "确认同步最小资料" }).evaluate((button: HTMLButtonElement) => { button.click(); button.click(); });
    await expect(page.getByRole("button", { name: "正在同步…" })).toBeDisabled();
    await expect(page.getByRole("button", { name: "正在同步…" })).toHaveAccessibleDescription(/正在同步，请等待结果/);
    await expect(page.getByRole('combobox',{name:'资料类型'})).toHaveAccessibleDescription(/暂时锁定/);
    await expect.poll(() => control.writes.length).toBe(1);
  } finally { control.release(); }
  await expect(page.getByRole("alert").filter({ hasText: /操作未完成/ })).toBeVisible();
  await expect(page.getByRole("region", { name: "待同步资料预览" })).toBeVisible();
  expect(JSON.stringify(control.writes)).not.toMatch(/private-id|private-internal/);
  control.succeed();
  await page.getByRole("button", { name: "确认同步最小资料" }).click();
  await expect(page.getByText(/已同步最小资料。QQ 查询还需本人绑定/)).toBeVisible();
  expect(control.writes).toHaveLength(2);
  expect(control.writes[0].body).toEqual(control.writes[1].body);
});

test("同步确认不代替删除确认，切换类型后重新核对删除", async ({ page }) => {
  const control = await syncFixture(page);
  await page.goto("/web/connected-apps");
  await prepareGrades(page);
  await page.getByRole("checkbox", { name: /我确认仅操作当前账号/ }).check();
  await page.getByText("删除云端上传副本", { exact: true }).click();
  const remove = page.getByRole("button", { name: "删除该类上传副本" });
  await expect(remove).toBeDisabled();
  await expect(remove).toHaveAccessibleDescription(/请先核对资料类型，再勾选删除确认/);
  const confirm = page.getByRole("checkbox", { name: "确认删除当前选择的上传副本" });
  await confirm.check();
  await expect(remove).toBeEnabled();
  await expect(remove).toHaveAccessibleDescription(/已确认删除当前类型/);
  await page.getByRole("combobox", { name: "资料类型" }).selectOption("erke");
  await expect(confirm).not.toBeChecked();
  await expect(remove).toBeDisabled();
  expect(control.writes).toHaveLength(0);
});

for (const width of [390, 1440]) for (const theme of ["light", "dark"]) {
  test(`${theme} ${width}px同步预览与删除区域可操作`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.addInitScript(theme => localStorage.setItem("sylulive-theme", theme), theme);
    await syncFixture(page);
    await page.goto("/web/connected-apps");
    await prepareGrades(page);
    await page.getByText("删除云端上传副本", { exact: true }).click();
    await expect(page.getByRole("checkbox", { name: "确认删除当前选择的上传副本" })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const deleteBox = page.getByRole("checkbox", { name: "确认删除当前选择的上传副本" });
    await deleteBox.focus();
    await page.keyboard.press("Space");
    await expect(deleteBox).toBeChecked();
    await expect(page.getByRole("button", { name: "删除该类上传副本" })).toBeEnabled();
    await page.evaluate(() => { (document.activeElement as HTMLElement)?.blur(); scrollTo(0, 0); });
    await page.screenshot({ path: test.info().outputPath(`sync-${theme}-${width}.png`), fullPage: true });
  });
}
