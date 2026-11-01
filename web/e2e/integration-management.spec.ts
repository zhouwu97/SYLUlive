import { test, expect, type Page } from "@playwright/test";

const binding = {
  binding_id: "00000000-0000-4000-8000-000000000001", nickname: "合成同学甲",
  installation_name: "QQ 100001 · 校园助手", state: "active", epoch: 1,
  scopes: ["profile:read_minimal", "academic:grades:read", "academic:erke:read", "checkin:write"],
  created_at: "2026-11-01T00:00:00Z",
};
async function fixture(page: Page, options: { role?: string; empty?: boolean; fail?: boolean; conflict?: boolean } = {}) {
  const writes: Record<string, unknown>[] = [];
  let current = structuredClone(binding), failed = !!options.fail;
  await page.route("**/api/**", async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    if (path === "/api/user/profile") return route.fulfill({ json: { id: 900, nickname: "合成管理员", role: options.role || "admin" } });
    if (path === "/api/admin/integrations") {
      if (failed) return route.fulfill({ status: 503, json: { code: "integration_unavailable", message: "服务暂时不可用" } });
      return route.fulfill({ json: { items: options.empty ? [] : [current], total: options.empty ? 0 : 1, personal_data_enabled: true } });
    }
    if (path.endsWith("/audits")) return route.fulfill({ json: { items: [{ event: "grades_read", actor_id: 100, reason: "", created_at: "2026-11-01T00:01:00Z" }] } });
    if (path.endsWith("/restrict")) {
      const body = req.postDataJSON(); writes.push(body);
      if (options.conflict) return route.fulfill({ status: 409, json: { code: "binding_conflict" } });
      current = { ...current, epoch: 2, scopes: body.scopes, state: body.revoke ? "revoked" : "active" };
      return route.fulfill({ json: { message: "已保存" } });
    }
    return route.fulfill({ json: {} });
  });
  return { writes, recover: () => { failed = false; } };
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

test("移动端可撤销授权且无横向溢出", async ({ page }) => {
  const { writes } = await fixture(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/web/admin?tab=integrations");
  await page.getByRole("button", { name: "管理此授权" }).click();
  await page.getByRole("textbox", { name: "处理原因" }).fill("合成撤销确认");
  await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
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
  await page.getByRole("textbox", { name: "处理原因" }).fill("合成过期状态");
  await page.getByRole("checkbox", { name: /确认使旧凭证失效/ }).check();
  await page.getByRole("button", { name: "撤销此授权" }).click();
  await expect(page.getByText("授权状态已变化，请刷新列表后重新核对。")).toBeVisible();
});
