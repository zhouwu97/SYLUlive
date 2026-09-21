import { isProvider } from "@sylulive/academic-contracts";
import { origins, entrances, physicalLogin } from "./school";
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
  root.innerHTML = `<main class="panel"><h1>${name}</h1><p>本机连接 ${origins[provider]}，学校登录会话由浏览器管理。</p>${provider === "physical" ? "<p>当前体测服务使用 HTTP，凭据通过该服务传输。密码只用于本次登录，不保存。</p>" : ""}<button id="authorize">授予权限并连接</button><form id="login" hidden><label>账号<input name="account" autocomplete="username" required></label><label>密码<input name="password" type="password" autocomplete="current-password" required></label><button>登录</button></form><p id="status" role="status"></p></main>`;
  const status = document.querySelector<HTMLElement>("#status")!;
  document.querySelector("#authorize")!.addEventListener("click", async () => {
    try {
      const granted = await chrome.permissions.request({
        origins: [`${origins[provider]}/*`],
        ...(provider === 'physical' ? {permissions:['cookies']} : {}),
      });
      if (!granted) throw new Error("未授予访问权限，可以再次尝试");
      if (provider === "physical") {
        document.querySelector<HTMLFormElement>("#login")!.hidden = false;
      } else {
        await chrome.tabs.create({ url: entrances[provider] });
        status.textContent =
          "请在官网完成登录，然后返回沈理校园点击“核对已登录身份”。";
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
