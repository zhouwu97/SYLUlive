import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";

for (const width of [1440, 390]) {
  test(`登录一天冷却可在未登录时查看公开申诉联系方式 ${width}`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    let limited = true, calls = 0;
    const errors: string[] = [];
    page.on("pageerror", error => errors.push(error.message));
    const privacy = await readFile("server/static/legal/privacy.html", "utf8");
    await page.context().route("**/privacy", route => route.fulfill({ contentType: "text/html; charset=utf-8", body: privacy }));
    await page.route("**/api/**", route => {
      const path = new URL(route.request().url()).pathname;
      if (path === "/api/login") {
        calls++;
        return route.fulfill(limited
          ? { status: 429, headers: { "Retry-After": "86400" }, json: { code: "LOGIN_COOLDOWN", error: "连续登录失败次数过多，请在1天后重试，或向开发者申诉" } }
          : { status: 401, json: { code: "INVALID_CREDENTIALS", error: "账号或密码错误" } });
      }
      if (path === "/api/user/profile" || path === "/api/refresh") {
        return route.fulfill({ status: 401, json: { error: "未登录" } });
      }
      return route.fulfill({ json: { items: [], posts: [], has_more: false } });
    });
    await page.goto("./");
    await page.getByRole("button", { name: width <= 600 ? "发布校园内容" : "登录", exact: true }).click();
    const dialog = page.getByRole("dialog", { name: "登录沈理校园", exact: true });
    await dialog.getByLabel("邮箱或账号").fill("blocked@example.invalid");
    await dialog.getByLabel("密码", { exact: true }).fill("synthetic-password42");
    await dialog.getByRole("button", { name: "登录", exact: true }).click();
    await expect(dialog.getByRole("alert")).toContainText("1天后重试");
    const appeal = dialog.getByRole("link", { name: "查看开发者联系方式并申诉" });
    await expect(appeal).toBeVisible();
    await expect(appeal).toHaveAttribute("href", "/privacy");
    await expect(dialog.getByRole("status")).toContainText("无需提供密码或验证码");
    await page.screenshot({ path: testInfo.outputPath(`cooldown-${width}.png`) });
    const popupPromise = page.waitForEvent("popup");
    await appeal.click();
    const contact = await popupPromise;
    await contact.waitForLoadState("domcontentloaded");
    await expect(contact.getByText("3170305904@qq.com", { exact: false })).toBeVisible();
    expect(contact.url()).not.toContain("blocked");
    await contact.close();
    expect(calls).toBe(1);
    limited = false;
    await dialog.getByRole("button", { name: "登录", exact: true }).click();
    await expect(dialog.getByRole("alert")).toContainText("账号或密码错误");
    await expect(appeal).toHaveCount(0);
    expect(calls).toBe(2);
    expect(errors).toEqual([]);
  });
}
