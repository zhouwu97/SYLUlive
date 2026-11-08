import { BridgeFailure, bridgeErrorCode, isBridgeErrorCode, type AcademicProvider, type AssistantLoginPhase } from "@sylulive/academic-contracts";
import { credentialScope, loadCredentials, type SchoolCredentials } from "./credentials";
import { entrances, identity, origins, vpnPath } from "./school";
import { fillSchoolLogin, type LoginStage } from "./school-login-script";

export function loginStage(provider: AcademicProvider, href: string): LoginStage | undefined {
  const url = new URL(href);
  if (url.origin !== origins[provider]) return;
  if (provider === "undergraduate" && url.pathname === "/xtgl/login_slogin.html") return "undergraduate";
  if (provider !== "erke") return;
  if (url.pathname.toLowerCase() === vpnPath("/SyluTW/Sys/UserLogin.aspx").toLowerCase()) return "erke";
  // 统一认证必须是学校 WebVPN 的认证页面；不向普通代理页面注入密码。
  if (["/authserver/login", ...["http", "https"].map(scheme => vpnPath("/authserver/login", "authserver.sylu.edu.cn", scheme))].includes(url.pathname.replace(/\/$/, ""))) return "vpn";
}

export function mountSchoolAssistant(provider: AcademicProvider, root: HTMLElement) {
  const name = { undergraduate: "本科教务", graduate: "研究生教务", erke: "二课 WebVPN", physical: "体测" }[provider];
  const automatic = provider === "undergraduate" || provider === "erke";
  root.innerHTML = `<main class="panel"><h1>${name}</h1>
    <p>首次授予学校访问权限；登录成功后自动返回发起连接的网页并读取资料。</p>
    <form id="school-login">
      ${automatic ? `<label>学号<input name="account" autocomplete="username" inputmode="numeric" pattern="[0-9]{8,20}" required></label>
      ${provider === "erke" ? '<label>统一认证密码（WebVPN）<input name="vpnPassword" type="password" autocomplete="current-password" required></label>' : ""}
      <label>${provider === "erke" ? "二课系统密码" : "教务密码"}<input name="password" type="password" autocomplete="current-password" required></label>
      <label class="check-label"><input name="remember" type="checkbox">授权在此浏览器保存凭据，下次自动填写、登录并返回</label>
      <p>凭据仅保存在本机扩展中，使用浏览器加密，不上传沈理校园。共用电脑请勿保存。</p>
      <button id="automatic" type="submit">授权并自动登录</button>` : ""}
      <button id="manual" type="button">授权并手动登录</button>
      <button id="forget" type="button" hidden>清除已保存凭据</button>
    </form>
    <button id="edit" type="button" hidden>修改登录信息并重试</button>
    <button id="cancel" type="button" hidden>取消本次登录</button>
    <p id="status" role="status" aria-live="polite"></p>
  </main>`;
  const form = root.querySelector<HTMLFormElement>("#school-login")!;
  const status = root.querySelector<HTMLElement>("#status")!;
  const forget = root.querySelector<HTMLButtonElement>("#forget")!;
  const cancel = root.querySelector<HTMLButtonElement>("#cancel")!;
  const edit = root.querySelector<HTMLButtonElement>("#edit")!;
  const flowId = new URLSearchParams(location.search).get("flow");
  let scope = "", busy = false, cancelled = false, schoolTabId: number | undefined;
  let saved: SchoolCredentials | undefined, forgetting = false;
  let attempt: AbortController | undefined, editing = false;
  let heartbeat: ReturnType<typeof setInterval> | undefined, heartbeatPending = false;
  let reportedPhase: AssistantLoginPhase | undefined;
  async function context(action = "context", studentId?: string, credentials?: SchoolCredentials, phase?: AssistantLoginPhase) {
    if (!flowId) throw new Error("请从沈理校园网页重新发起连接。");
    let result;
    for (let retry = 0; retry < 4; retry++) {
      result = await chrome.runtime.sendMessage({ kind: "assistant-login", flowId, action, studentId, credentials, phase });
      if (result?.ok || result?.code !== "site_login_required" || cancelled) break;
      // 由原网页刷新本站 HttpOnly 会话；助手只等待，不自行读取或保存 Token。
      status.textContent = "本站会话正在恢复，请稍候；账号变化时会停止登录。";
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    if (!result?.ok) throw new BridgeFailure(isBridgeErrorCode(result?.code) ? result.code : "failed", result?.message || "登录任务已失效，请重新连接。");
    if (result.result.provider !== provider) throw new Error("学校系统不匹配，请重新连接。");
    return result.result as { origin: string; appUserId: number; provider: AcademicProvider };
  }
  async function report(phase: AssistantLoginPhase) {
    if (reportedPhase === phase) return;
    await context("progress", undefined, undefined, phase);
    reportedPhase = phase;
  }
  function setBusy(value: boolean) {
    busy = value;
    for (const input of form.querySelectorAll<HTMLInputElement | HTMLButtonElement>("input,button")) input.disabled = input.id !== "forget" && (value || cancelled);
    cancel.hidden = !value;
    cancel.disabled = false;
  }
  function stopIfStale(error: unknown) {
    const code = bridgeErrorCode(error);
    if (code !== "connection_stale" && code !== "site_login_required") return;
    cancelled = true;
    clearInterval(heartbeat);
    for (const input of form.querySelectorAll<HTMLInputElement | HTMLButtonElement>("input,button")) input.disabled = input.id !== "forget";
  }
  async function run(credentials?: SchoolCredentials, remember = false) {
    if (busy) return;
    cancelled = false;
    editing = false;
    attempt = new AbortController();
    const signal = attempt.signal;
    setBusy(true);
    edit.hidden = !credentials;
    edit.disabled = false;
    let finished = false;
    const submitted = new Set<LoginStage>();
    try {
      await context();
      await report(credentials ? "logging_in" : "verification_required");
      status.textContent = "正在核对学校登录状态…";
      const deadline = Date.now() + 5 * 60_000;
      let nextAccountCheck = Date.now() + 10_000;
      let opened = false, enteredErke = false;
      while (!signal.aborted && Date.now() < deadline) {
        if (Date.now() >= nextAccountCheck) { await context(); nextAccountCheck = Date.now() + 10_000; }
        if (signal.aborted) break;
        let current: { studentId: string } | undefined;
        try { current = await identity(provider, signal); } catch { /* 会话未建立时继续学校登录，不修改已有资料。 */ }
        if (signal.aborted) break;
        if (current) {
          if (credentials && current.studentId !== credentials.account)
            throw new Error("学校当前学号与已填写凭据不一致，请在学校退出旧账号后重试；原资料已保留。");
          await context("complete", current.studentId, remember ? credentials : undefined);
          finished = true;
          form.reset();
          status.textContent = "登录成功，已返回沈理校园继续读取资料。";
          if (schoolTabId !== undefined) await chrome.tabs.remove(schoolTabId).catch(() => undefined);
          const tab = await chrome.tabs.getCurrent();
          if (tab?.id !== undefined) await chrome.tabs.remove(tab.id);
          return;
        }
        if (!opened) {
          if (schoolTabId !== undefined) await chrome.tabs.remove(schoolTabId).catch(() => undefined);
          const tab = await chrome.tabs.create({ url: provider === "erke" ? origins.erke + vpnPath("/SyluTW/Sys/UserLogin.aspx") : entrances[provider] });
          schoolTabId = tab.id;
          opened = true;
          status.textContent = credentials ? "正在学校页面自动填写并登录；如出现验证码，请在学校页完成。" : "请在学校页完成登录；成功后会自动返回并读取资料。";
        }
        if (schoolTabId !== undefined) {
          const tab = await chrome.tabs.get(schoolTabId);
          if (signal.aborted) break;
          if (tab.status === "complete" && tab.url) {
            const stage = loginStage(provider, tab.url);
            if (credentials && stage && !submitted.has(stage)) {
              await context();
              if (signal.aborted) break;
              // 只向已核对的顶层登录页传入该步骤所需的一个密码。
              const url = new URL(tab.url);
              const [result] = await chrome.scripting.executeScript({
                target: { tabId: schoolTabId, frameIds: [0] }, world: "MAIN",
                func: fillSchoolLogin,
                args: [stage, url.origin + url.pathname, credentials.account, stage === "vpn" ? credentials.vpnPassword! : credentials.password],
              }).catch(() => [{ result: { state: "manual" as const, message: "学校页面暂不能自动填写，请在学校页完成登录；成功后会自动返回。" } }]);
              if (result?.result?.state === "submitted" || result?.result?.state === "manual") submitted.add(stage);
              if (result?.result?.message) status.textContent = result.result.message;
              else if (result?.result?.state === "submitted") status.textContent = "已提交学校登录；若学校拒绝或出现验证码，请在学校页处理，成功后自动返回。";
              if (result?.result?.state === "manual") await report("verification_required");
            }
            if (provider === "erke" && new URL(tab.url).origin === origins.erke && !stage && ["/", "/index", "/login"].includes(new URL(tab.url).pathname)) {
              const [landing] = await chrome.scripting.executeScript({
                target: { tabId: schoolTabId, frameIds: [0] },
                func: () => {
                  const link = document.querySelector<HTMLAnchorElement>('a[href*="cas_login"]');
                  return link && new URL(link.href).origin === location.origin ? link.href : "";
                },
              }).catch(() => []);
              if (landing?.result) await chrome.tabs.update(schoolTabId, { url: landing.result });
              else if (!enteredErke && (submitted.has("vpn") || !credentials)) {
                // CAS 成功有时返回 VPN 门户，不会继续打开原来的二课目标。
                enteredErke = true;
                await chrome.tabs.update(schoolTabId, { url: origins.erke + vpnPath("/SyluTW/Sys/UserLogin.aspx") });
              }
            }
          }
        }
        await new Promise(resolve => setTimeout(resolve, 1500));
      }
      throw new Error(cancelled ? "本次自动登录已取消，请返回网页重新连接。" : editing ? "请修改登录信息后重试，本次网页会继续等待，原资料已保留。" : "登录等待已超时，请返回网页重新连接；原资料已保留。");
    } catch (error) {
      // 清除入口负责最后的结果提示，已中止的旧请求不能把它改回登录失败。
      if (forgetting) return;
      status.textContent = error instanceof Error ? error.message : "学校登录失败，请重试。";
      stopIfStale(error);
      // 密码或学校网络错误可在同一任务内修正，不能先取消任务再展示一个无效的重试按钮。
      if (!cancelled) await report("retry_required").catch(() => undefined);
    } finally {
      setBusy(false);
      edit.hidden = true;
      if (cancelled) for (const input of form.querySelectorAll<HTMLInputElement | HTMLButtonElement>("input,button")) input.disabled = input.id !== "forget";
      // 失败不删除或覆盖上一次成功保存的凭据。
      if (!finished) forget.hidden = !saved;
    }
  }
  async function authorize(credentials?: SchoolCredentials, remember = false) {
    if (busy) return;
    // 在当前用户手势内发起权限请求，再等待浏览器原生授权框。
    try {
      const permission = chrome.permissions.request({ origins: [`${origins[provider]}/*`] });
      cancelled = false;
      setBusy(true);
      status.textContent = "请在浏览器授权提示中允许访问学校系统…";
      const granted = await permission;
      setBusy(false);
      if (cancelled) throw new Error("本次登录已取消。");
      if (!granted) throw new Error("未授予学校访问权限，可以再次尝试。");
      await run(credentials, remember);
    } catch (error) {
      setBusy(false);
      status.textContent = error instanceof Error ? error.message : "学校授权失败，请重试。";
    }
  }
  form.addEventListener("submit", event => {
    event.preventDefault();
    const data = new FormData(form);
    const credentials: SchoolCredentials = {
      account: String(data.get("account") || "").trim(), password: String(data.get("password") || ""),
      ...(provider === "erke" ? { vpnPassword: String(data.get("vpnPassword") || "") } : {}),
    };
    // permissions.request 必须直接由点击触发，不能放到账号核对等异步调用之后。
    void authorize(credentials, data.get("remember") === "on");
  });
  root.querySelector("#manual")!.addEventListener("click", () => {
    void authorize();
  });
  forget.addEventListener("click", () => {
    cancelled = true;
    forgetting = true;
    clearInterval(heartbeat);
    attempt?.abort();
    void context("forget").then(() => {
      saved = undefined; form.reset(); forget.hidden = true;
      setBusy(false);
      status.textContent = "已停止自动登录并清除本机凭据。请回到网页重新连接。";
    }).catch(() => { status.textContent = "清除凭据失败，请重试。"; });
  });
  edit.addEventListener("click", () => { editing = true; edit.disabled = true; attempt?.abort(); });
  cancel.addEventListener("click", () => { cancelled = true; clearInterval(heartbeat); cancel.disabled = true; attempt?.abort(); void context("abandon").catch(() => undefined); });
  window.addEventListener("pagehide", () => {
    cancelled = true; attempt?.abort(); clearInterval(heartbeat);
    void context("abandon").catch(() => undefined);
  });
  void (async () => {
    setBusy(true);
    try {
      const owner = await context();
      heartbeat = setInterval(() => {
        if (heartbeatPending) return;
        heartbeatPending = true;
        void context("heartbeat").catch(error => {
          if (cancelled) return;
          const code = bridgeErrorCode(error);
          if (code === "connection_stale" || code === "site_login_required") {
            clearInterval(heartbeat); attempt?.abort(); stopIfStale(error);
            status.textContent = error.message;
          }
        }).finally(() => { heartbeatPending = false; });
      }, 1500);
      scope = credentialScope(owner.origin, owner.appUserId, provider);
      try {
        saved = automatic ? await loadCredentials(scope) : undefined;
        if (provider === "erke" && saved && !saved.vpnPassword) throw new Error("本机统一认证密码缺失，请重新输入或清除旧凭据。");
      } catch (error) {
        forget.hidden = false;
        throw error;
      }
      forget.hidden = !saved;
      if (saved) {
        (form.elements.namedItem("account") as HTMLInputElement).value = saved.account;
        (form.elements.namedItem("password") as HTMLInputElement).value = saved.password;
        if (provider === "erke") (form.elements.namedItem("vpnPassword") as HTMLInputElement).value = saved.vpnPassword || "";
        (form.elements.namedItem("remember") as HTMLInputElement).checked = true;
      }
      const granted = await chrome.permissions.contains({ origins: [`${origins[provider]}/*`] });
      if (granted && saved) { setBusy(false); await run(saved, true); }
      else {
        await report(granted ? "awaiting_input" : "awaiting_permission");
        status.textContent = "请授权并登录。保存凭据后，下次连接会自动完成。";
        setBusy(false);
      }
    } catch (error) {
      setBusy(false);
      status.textContent = error instanceof Error ? error.message : "无法读取本机授权，请重新连接。";
      stopIfStale(error);
    }
  })();
}
