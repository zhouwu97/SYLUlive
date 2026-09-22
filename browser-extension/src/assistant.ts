import { isProvider } from "@sylulive/academic-contracts";
import {
  origins,
  entrances,
  isPhysicalProviderEnabled,
  physicalLogin,
  setPhysicalProviderEnabled,
} from "./school";
const provider = new URLSearchParams(location.search).get("provider");
const root = document.querySelector<HTMLDivElement>("#app")!;
if (!isProvider(provider)) {
  root.innerHTML =
    '<main class="panel"><h1>沈理校园教务助手</h1><p>请从沈理校园的课表或成绩页面发起连接。</p></main>';
} else {
  const name = {
    undergraduate: "本科教务",
    graduate: "研究生教务",
    erke: "二课 WebVPN",
    physical: "体测",
  }[provider];
  root.innerHTML = `<main class="panel"><h1>${name}</h1><p>本机连接 ${origins[provider]}，学校登录会话由浏览器管理。</p>${provider === "physical" ? '<p class="warning">体测服务使用 HTTP 明文传输，密码会先做 MD5，但抓包得到的 MD5 值仍可能被重放。默认关闭；只有在你明确接受此风险后才会开启。</p><label class="check-label"><input id="physical-risk" type="checkbox">我已阅读并接受体测服务的明文传输与可重放风险</label>' : ""}<button id="authorize">授予权限并连接</button><form id="login" hidden><label>账号<input name="account" autocomplete="username" required></label><label>密码<input name="password" type="password" autocomplete="current-password" required></label><button>登录</button></form><p id="status" role="status"></p></main>`;
  const status = document.querySelector<HTMLElement>("#status")!;
  const physicalRisk = document.querySelector<HTMLInputElement>("#physical-risk");
  if (physicalRisk) {
    physicalRisk.checked = await isPhysicalProviderEnabled();
    physicalRisk.addEventListener("change", async () => {
      try {
        await setPhysicalProviderEnabled(physicalRisk.checked);
        if (!physicalRisk.checked)
          document.querySelector<HTMLFormElement>("#login")!.hidden = true;
        status.textContent = physicalRisk.checked
          ? "体测连接已手动开启，请确认学校服务仍可信。"
          : "体测连接已关闭，已清除本机体测会话。";
      } catch (error) {
        physicalRisk.checked = false;
        status.textContent = error instanceof Error ? error.message : "体测开关更新失败";
      }
    });
  }
  document.querySelector("#authorize")!.addEventListener("click", async () => {
    try {
      if (provider === "physical" && !physicalRisk?.checked)
        throw new Error("请先勾选风险确认并手动开启体测连接");
      const granted = await chrome.permissions.request({
        origins: [`${origins[provider]}/*`],
        ...(provider === 'physical' ? {permissions:['cookies']} : {}),
      });
      if (!granted) throw new Error("未授予访问权限，可以再次尝试");
      if (provider === "physical") {
        document.querySelector<HTMLFormElement>("#login")!.hidden = false;
      } else {
        // 授权必须由助手页的点击触发；授权完成后复用当前标签打开学校登录页，
        // 避免连续留下助手页和学校页两个重复标签。
        await chrome.tabs.update({ url: entrances[provider] });
      }
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : "连接失败";
    }
  });
  document
    .querySelector<HTMLFormElement>("#login")!
    .addEventListener("submit", async (event) => {
      event.preventDefault();
      const target = event.currentTarget as HTMLFormElement,
        form = new FormData(target);
      status.textContent = "正在登录…";
      try {
        await physicalLogin(
          String(form.get("account")),
          String(form.get("password")),
        );
        target.reset();
        status.textContent = "登录成功，请返回沈理校园核对身份。";
      } catch (error) {
        status.textContent =
          error instanceof Error ? error.message : "登录失败";
      }
    });
}
