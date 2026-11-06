import { test, expect } from "@playwright/test";
import { paths } from "../src/icons";

for (const theme of ["light", "dark"]) {
  test(`共享图标、工具入口和表单交互 ${theme}`, async ({ page }) => {
    await page.addInitScript(value => localStorage.setItem("sylulive-theme", value), theme);
    await page.route("**/api/**", route => route.fulfill({ json: { items: [] } }));
    await page.route("**/api/user/profile", route => route.fulfill({ json: { id: 991, nickname: "图标验收同学", role: "user" } }));
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto("toolbox");
    await expect(page.locator(".tool-card")).toHaveCount(6);
    await expect(page.locator(".tool-icon .svg-icon").first()).toHaveCSS("width", "24px");
    await expect(page.locator(".nav-icon .svg-icon").first()).toHaveCSS("width", "20px");
    await expect(page.locator(".tool-icon [data-tone]").first()).toHaveCSS("fill-opacity", "0.14");
    await page.screenshot({ path: `.codex-captures/icons-ui/toolbox-${theme}.png` });

    const gpa = page.locator(".tool-card").filter({ has: page.getByRole("heading", { name: "GPA 计算", exact: true }) });
    await gpa.getByRole("button", { name: "打开", exact: true }).click();
    const dialog = page.getByRole("dialog", { name: "GPA 计算", exact: true });
    await expect(dialog.locator('[data-icon="close"]')).toHaveCSS("width", "18px");
    await dialog.getByRole("textbox").fill("3,4\n2,3");
    await dialog.getByRole("button", { name: "计算", exact: true }).click();
    await expect(dialog).toContainText("加权 GPA：3.600");
    await dialog.getByRole("textbox").fill("3,6");
    await dialog.getByRole("button", { name: "计算", exact: true }).click();
    await expect(dialog).toContainText("请输入有效学分和 0–5 的绩点");
    await page.keyboard.press("Escape");
    await expect(gpa.getByRole("button", { name: "打开", exact: true })).toBeFocused();
    const free = page.locator(".tool-card").filter({ has: page.getByRole("heading", { name: "空闲时间", exact: true }) });
    await free.getByRole("button", { name: "上移", exact: true }).click();
    await expect(page.locator(".tool-card").first()).toContainText("空闲时间");
    await page.reload();
    await expect(page.locator(".tool-card").first()).toContainText("空闲时间");
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
