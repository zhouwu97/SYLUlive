import { test, expect } from "@playwright/test";
import { paths } from "../src/icons";

for (const theme of ["light", "dark"]) {
  test(`共享图标、工具入口和表单交互 ${theme}`, async ({ page }) => {
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await page.route("**/api/**", route => route.fulfill({ json: { items: [] } }));
    await page.route("**/api/user/profile", route => route.fulfill({ json: { id: 991, nickname: "图标验收同学", role: "user" } }));
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto("toolbox");
    // 分组与 App 工具箱一致：常用工具 5、校园与娱乐 2；更多工具 5（含 Web 独有的手机扫码同步）
    await expect(page.getByRole("heading", { level: 2 })).toHaveText(["常用工具", "校园与娱乐", "更多工具"]);
    await expect(page.locator(".tool-tile")).toHaveCount(12);
    await expect(page.locator(".tool-icon .svg-icon").first()).toHaveCSS("width", "24px");
    await expect(page.locator(".nav-icon .svg-icon").first()).toHaveCSS("width", "20px");
    await expect(page.locator(".tool-icon [data-tone]").first()).toHaveCSS("fill-opacity", "0.14");
    await page.screenshot({ path: `.codex-captures/icons-ui/toolbox-${theme}.png` });

    const gpa = page.locator(".tool-tile").filter({ hasText: "GPA 计算" });
    await gpa.click();
    const dialog = page.getByRole("dialog", { name: "GPA 计算", exact: true });
    await expect(dialog.locator('[data-icon="close"]')).toHaveCSS("width", "18px");
    await dialog.getByRole("textbox").fill("3,4\n2,3");
    await dialog.getByRole("button", { name: "计算", exact: true }).click();
    await expect(dialog).toContainText("加权 GPA：3.600");
    await dialog.getByRole("textbox").fill("3,6");
    await dialog.getByRole("button", { name: "计算", exact: true }).click();
    await expect(dialog).toContainText("请输入有效学分和 0–5 的绩点");
    await page.keyboard.press("Escape");
    await expect(gpa).toBeFocused();
    // 网站大全与 App 同一份 10 个站点，新标签页打开
    await page.locator(".tool-tile").filter({ hasText: "网站大全" }).click();
    const sites = page.getByRole("dialog", { name: "网站大全", exact: true });
    await expect(sites.locator(".site-link")).toHaveCount(10);
    await expect(sites.getByRole("link", { name: /教务处/ })).toHaveAttribute("target", "_blank");
    await page.keyboard.press("Escape");
    await expect(page.locator(".tool-tile").filter({ hasText: "试卷库" })).toHaveAttribute("href", /exams\?tab=papers$/);
    await page.locator(".tool-tile").filter({ hasText: "手机扫码同步" }).click();
    await expect(page.getByRole("dialog", { name: "手机 App 扫码同步", exact: true }).locator(".phone-scan")).toBeVisible();
    await page.keyboard.press("Escape");
  });
}

test("全部图标轮廓在 24px 画布内，预览覆盖整套资源", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 720 });
  await page.setContent(`<style>
    body { margin: 24px; background: #fff; color: #315df2; font: 12px system-ui; }
    main { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; }
    figure { display: grid; justify-items: center; gap: 10px; margin: 0; padding: 18px; border: 1px solid #dce1e9; border-radius: 12px; }
    svg { width: 32px; height: 32px; fill: none; stroke: currentColor; stroke-width: 1.75; stroke-linecap: round; stroke-linejoin: round; }
    [data-tone] { fill: currentColor; fill-opacity: .14; stroke: none; }
    figcaption { color: #69717e; }
  </style><main>${Object.entries(paths).map(([name, markup]) => `<figure><svg data-icon="${name}" viewBox="0 0 24 24">${markup}</svg><figcaption>${name}</figcaption></figure>`).join("")}</main>`);
  const invalid = await page.locator("svg").evaluateAll(icons => icons.flatMap(icon => {
    const box = (icon as SVGSVGElement).getBBox();
    return box.width <= 0 || box.height <= 0 || box.x < 1 || box.y < 1 || box.x + box.width > 23 || box.y + box.height > 23 ? [icon.dataset.icon] : [];
  }));
  expect(invalid).toEqual([]);
  await page.screenshot({ path: ".codex-captures/icons-ui/icon-set.png", fullPage: true });
});
