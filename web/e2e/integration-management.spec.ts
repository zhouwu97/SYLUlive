import { test, expect, type Page } from "@playwright/test";

const binding = {
  binding_id: "00000000-0000-4000-8000-000000000001", nickname: "合成同学甲",
  installation_name: "QQ 100001 · 校园助手", state: "active", epoch: 1,
  scopes: ["profile:read_minimal", "academic:grades:read", "academic:erke:read", "checkin:write"],
  created_at: "2026-11-01T00:00:00Z",
};
async function fixture(page: Page, options: { role?: string; empty?: boolean; fail?: boolean; conflict?: boolean; holdWrite?: boolean; holdList?: boolean; total?: number; longName?: boolean; revoked?: boolean } = {}) {
  const writes: Record<string, unknown>[] = [];
  const listRequests: string[] = [];
  let releaseWrite!: () => void, releaseList!: () => void;
  const writeGate = new Promise<void>(resolve => { releaseWrite = resolve; });
  const listGate = new Promise<void>(resolve => { releaseList = resolve; });
  if (!options.holdWrite) releaseWrite();
  if (!options.holdList) releaseList();
  let current = structuredClone(binding), failed = !!options.fail;
  if (options.longName) current.installation_name = "共享校园助手".repeat(22);
  if (options.revoked) current.state = "revoked";
  await page.route("**/api/**", async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 900, nickname: "合成管理员", role: options.role || "admin" } });
    if (path === "/api/admin/integrations") {
      listRequests.push(new URL(req.url()).search);
      await listGate;
      if (failed) return route.fulfill({ status: 503, json: { code: "integration_unavailable", message: "服务暂时不可用" } });
      const filter = new URL(req.url()).searchParams.get("state"), visible = !options.empty && (!filter || filter === current.state);
      return route.fulfill({ json: { items: visible ? [current] : [], total: visible ? options.total ?? 1 : 0, personal_data_enabled: true } });
    }
    if (path.endsWith("/audits")) return route.fulfill({ json: { items: [{ event: "grades_read", actor_id: 100, reason: "", created_at: "2026-11-01T00:01:00Z" }] } });
    if (path.endsWith("/restrict")) {
      const body = req.postDataJSON(); writes.push(body);
      await writeGate;
      if (options.conflict) return route.fulfill({ status: 409, json: { code: "binding_conflict" } });
      current = { ...current, epoch: 2, scopes: body.scopes, state: body.revoke ? "revoked" : "active" };
      return route.fulfill({ json: { message: "已保存" } });
    }
    return route.fulfill({ json: {} });
  });
  return { writes, listRequests, releaseWrite, releaseList, recover: () => { failed = false; } };
}

test("管理员可视化缩减权限并查看无正文审计", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.goto("/web/admin?tab=integrations");
  await expect(page.getByRole("heading", { name: "助手授权管理" })).toBeVisible();
  await expect(page.getByText("合成同学甲", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "查看操作审计" }).click();
  await expect(page.getByText(/读取本人成绩/)).toBeVisible();
  await page.getByRole("button", { name: "管理此授权" }).click();
  await page.getByRole("checkbox", { name: /已同步成绩/ }).uncheck();
  await page.getByRole("textbox", { name: "处理原因" }).fill("合成隐私处置");
  const save = page.getByRole("button", { name: "保存缩减权限" });
  await expect(save).toBeDisabled();
  await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: test.info().outputPath("integration-admin-desktop.png"), fullPage: true });
  await save.click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toMatchObject({ expected_epoch: 1, revoke: false, reason: "合成隐私处置" });
  expect(writes[0].scopes).not.toContain("academic:grades:read");
  expect(JSON.stringify(writes)).not.toContain("access_token");
});

async function expectContrast(page: Page, selector: string) {
  await expect(page.locator(selector).first()).toBeVisible();
  const lowContrast = await page.evaluate(selector => {
    const ctx = document.createElement("canvas").getContext("2d")!;
    const luminance = (color: string) => {
      ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = color; ctx.fillRect(0, 0, 1, 1);
      const c = Array.from(ctx.getImageData(0, 0, 1, 1).data).slice(0, 3).map(x => x / 255).map(x => x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4);
      return .2126 * c[0] + .7152 * c[1] + .0722 * c[2];
    };
    return Array.from(document.querySelectorAll<HTMLElement>(selector)).map(el => {
      let surface: HTMLElement | null = el;
      while (surface && getComputedStyle(surface).backgroundColor === "rgba(0, 0, 0, 0)") surface = surface.parentElement;
      const ink = luminance(getComputedStyle(el).color), paper = luminance(getComputedStyle(surface || document.body).backgroundColor);
      return { label: el.innerText, color: getComputedStyle(el).color, surface: getComputedStyle(surface || document.body).backgroundColor, hover: matchMedia('(hover: hover) and (pointer: fine)').matches, paper: getComputedStyle(el).getPropertyValue('--color-paper-2'), transition: getComputedStyle(el).transition, ratio: (Math.max(ink, paper) + .05) / (Math.min(ink, paper) + .05) };
    }).filter(row => row.ratio < 4.5);
  }, selector);
  expect(lowContrast).toEqual([]);
}

test("移动端可撤销授权且无横向溢出", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/web/admin?tab=integrations");
  await page.getByRole("button", { name: "管理此授权" }).click();
  await page.getByRole("radio", { name: "撤销连接", exact: true }).check();
  await page.getByRole("textbox", { name: "处理原因" }).fill("合成撤销确认");
  await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
  await page.getByRole("button", { name: "撤销此授权" }).hover();
  await expectContrast(page, ".integration-revoke-note, .integration-submit .btn.danger");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: test.info().outputPath("integration-admin-mobile.png"), fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.getByRole("button", { name: "撤销此授权" }).click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0].revoke).toBe(true);
});

test("普通用户没有管理入口", async ({ page }) => {
  await fixture(page, { role: "user" });
  await page.goto("/web/admin?tab=integrations");
  await expect(page.getByText("当前账号没有管理权限")).toBeVisible();
  await expect(page.getByRole("button", { name: "管理此授权" })).toHaveCount(0);
});

test("空状态可理解", async ({ page }) => {
  await fixture(page, { empty: true });
  await page.goto("/web/admin?tab=integrations");
  await expect(page.getByText("没有符合条件的助手授权")).toBeVisible();
});

test("读取失败可重试恢复", async ({ page }) => {
  const control = await fixture(page, { fail: true });
  await page.goto("/web/admin?tab=integrations");
  await expect(page.getByText("加载未完成")).toBeVisible();
  control.recover();
  await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.getByText("合成同学甲", { exact: true })).toBeVisible();
});

test("并发状态变化不显示保存成功", async ({ page }) => {
  await fixture(page, { conflict: true });
  await page.goto("/web/admin?tab=integrations");
  await page.getByRole("button", { name: "管理此授权" }).click();
  await page.getByRole("radio", { name: "撤销连接", exact: true }).check();
  await page.getByRole("textbox", { name: "处理原因" }).fill("合成过期状态");
  await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
  await page.getByRole("button", { name: "撤销此授权" }).click();
  await expect(page.getByText("授权状态已变化，请刷新列表后重新核对。")).toBeVisible();
});

test("更改权限或处理方式后必须重新确认，取消恢复焦点", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.goto("/web/admin?tab=integrations");
  const manage = page.getByRole("button", { name: "管理此授权" });
  await manage.click();
  await page.getByRole("checkbox", { name: /已同步成绩/ }).uncheck();
  await expect(page.getByText("将移除：本人已同步成绩", { exact: true })).toBeVisible();
  await page.getByRole("textbox", { name: "处理原因" }).fill("合成处理原因");
  const confirm = page.getByRole("checkbox", { name: /确认使旧凭证失效/ });
  await confirm.check();
  await page.getByRole("checkbox", { name: /已同步二课/ }).uncheck();
  await expect(confirm).not.toBeChecked();
  await expect(page.getByRole("button", { name: "保存缩减权限" })).toBeDisabled();
  await confirm.check();
  await page.getByRole("radio", { name: "撤销连接", exact: true }).check();
  await expect(confirm).not.toBeChecked();
  await expect(page.getByRole("button", { name: "撤销此授权" })).toBeDisabled();
  await page.getByRole("button", { name: "取消", exact: true }).click();
  await expect(manage).toBeFocused();
  await expect(manage).toHaveAttribute("aria-expanded", "false");
  expect(writes).toHaveLength(0);
});

test("提交中的权限操作不会重复发送", async ({ page }) => {
  const control = await fixture(page, { holdWrite: true });
  try {
    await page.goto("/web/admin?tab=integrations");
    await page.getByRole("button", { name: "管理此授权" }).click();
    await page.getByRole("checkbox", { name: /已同步成绩/ }).uncheck();
    await page.getByRole("textbox", { name: "处理原因" }).fill("合成重复提交");
    await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
    await page.getByRole("button", { name: "保存缩减权限" }).click();
    await expect(page.getByRole("button", { name: "正在保存…" })).toBeDisabled();
    await page.locator(".integration-editor-body").evaluate((form: HTMLFormElement) => { form.requestSubmit(); form.requestSubmit(); });
    expect(control.writes).toHaveLength(1);
  } finally { control.releaseWrite(); }
  await expect(page.getByText(/授权已更新，旧凭证已失效/)).toBeVisible();
});

test("加载时不伪造零授权数量，分页使用服务端总数", async ({ page }) => {
  const control = await fixture(page, { holdList: true, total: 31 });
  try {
    await page.goto("/web/admin?tab=integrations");
    await expect(page.getByText("个人查询状态未确认")).toBeVisible();
    await expect(page.getByText("共 0 个授权")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "正在读取…" })).toBeDisabled();
  } finally { control.releaseList(); }
  await expect(page.getByText("共 31 个授权")).toBeVisible();
  await page.getByRole("button", { name: "下一页" }).click();
  await expect.poll(() => control.listRequests.some(path => path.includes("page=2"))).toBe(true);
  await expect(page.getByText("第 2 / 2 页")).toBeVisible();
  await expect(page.getByRole("button", { name: "下一页" })).toBeDisabled();
});

test("已撤销连接不展示可执行编辑入口", async ({ page }) => {
  await fixture(page, { revoked: true });
  await page.goto("/web/admin?tab=integrations");
  await page.getByRole("combobox", { name: "授权状态" }).selectOption("revoked");
  await expect(page.getByText("合成同学甲", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "管理此授权" })).toHaveCount(0);
  await page.getByRole("button", { name: "查看操作审计" }).click();
  await expect(page.getByRole("region", { name: "操作审计" })).toBeVisible();
});

for (const width of [320, 390, 768, 1440]) for (const theme of ["light", "dark"]) {
  test(`${theme} ${width}px权限编辑可读且无横向溢出`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.addInitScript(theme => localStorage.setItem("sylulive-theme", theme), theme);
    await fixture(page, { longName: width === 320 || width === 768 });
    await page.goto("/web/admin?tab=integrations");
    if (width === 390 || width === 1440) {
      const action = await page.getByRole("button", { name: "管理此授权" }).boundingBox();
      expect(action!.y + action!.height).toBeLessThanOrEqual(900);
      await page.screenshot({ path: test.info().outputPath(`permissions-overview-${theme}-${width}.png`), fullPage: true });
    }
    await page.getByRole("button", { name: "管理此授权" }).click();
    await expect(page.getByRole("textbox", { name: "处理原因" })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const labels = page.locator(".integration-permissions label");
    for (const label of await labels.all()) expect((await label.boundingBox())!.height).toBeGreaterThanOrEqual(44);
    await expectContrast(page, ".integration-heading h2, .integration-muted, .integration-badge, .integration-permissions small, .integration-scope-tags li, .integration-mode label, .integration-submit .btn:not(:disabled)");
    await page.evaluate(() => scrollTo(0, 0));
    if (width === 390 || width === 1440) await page.screenshot({ path: test.info().outputPath(`permissions-${theme}-${width}.png`), fullPage: true });
    await page.getByRole("radio", { name: "撤销连接", exact: true }).check();
    await page.getByRole("textbox", { name: "处理原因" }).fill("合成撤销对比度检查");
    await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
    await page.getByRole("button", { name: "撤销此授权" }).hover();
    await expectContrast(page, ".integration-revoke-note, .integration-submit .btn.danger");
  });
}
