export type LoginStage = "undergraduate" | "vpn" | "erke";
export type LoginScriptResult = { state: "submitted" | "manual" | "waiting"; message?: string };

// 此函数会序列化到学校页面 MAIN world，必须自包含；使用学校自己的提交按钮，
// 让原页面执行 RSA/AES、隐藏字段和验证码检查，不另造一套密码加密协议。
export function fillSchoolLogin(
  stage: LoginStage, expectedUrl: string, account: string, password: string,
): LoginScriptResult {
  if (location.origin + location.pathname !== expectedUrl) return { state: "waiting" };
  const selectors = {
    undergraduate: ["#yhm", "#mm", "#dl"],
    vpn: ['#username, input[name="username"]', '#userPassword, input[name="userPassword"], #password, input[name="password"]', '#login_submit, #loginBtn, button[type="submit"], input[type="submit"]'],
    erke: ['#UserName, input[name="UserName"]', '#Password, input[name="Password"]', '#queryBtn, input[name="queryBtn"]'],
  }[stage];
  const visible = (el: HTMLElement) => el.getClientRects().length > 0 && !el.matches('input[type="hidden"]');
  // 正方页面会重写 Array.prototype.some 等原生方法；MAIN world 内只遍历
  // NodeList，避免学校的扩展方法改变自动填写与验证码判断的语义。
  function firstVisible<T extends HTMLElement>(root: ParentNode, selector: string): T | undefined {
    const elements = root.querySelectorAll<T>(selector);
    for (let i = 0; i < elements.length; i++) if (visible(elements[i])) return elements[i];
  }
  const username = firstVisible<HTMLInputElement>(document, selectors[0]);
  const form = username?.closest("form");
  // CAS 同时有明文输入框与加密用隐藏 password 字段，只填写可见输入框，
  // 隐藏字段交给学校自己的按钮逻辑生成。
  const secret = form && firstVisible<HTMLInputElement>(form, selectors[1]);
  const submit = form && firstVisible<HTMLElement>(form, selectors[2]);
  if (!username || !secret || !form || !submit || !form.contains(secret)) return { state: "waiting" };
  if (new URL(form.action || location.href, location.href).origin !== location.origin)
    return { state: "manual", message: "学校登录目标发生变化，请手动核对后登录。" };
  const setValue = (input: HTMLInputElement, value: string) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  };
  setValue(username, account);
  setValue(secret, password);
  if (stage === "erke") {
    const code = document.querySelector<HTMLInputElement>("#codeInput");
    const text = document.querySelector("#code-box")?.textContent?.trim();
    if (code && text) setValue(code, text);
  }
  let captcha = false, slider = false;
  const codes = form.querySelectorAll<HTMLInputElement>('input[name*="captcha" i], input[id*="captcha" i], #yzm, #codeInput');
  for (let i = 0; i < codes.length; i++) if (visible(codes[i]) && !codes[i].value.trim()) { captcha = true; break; }
  const sliders = document.querySelectorAll<HTMLElement>('[class*="slider" i], [id*="slider" i]');
  for (let i = 0; i < sliders.length; i++) if (visible(sliders[i])) { slider = true; break; }
  if (captcha || slider) return { state: "manual", message: "账号密码已填写，请在学校页面完成验证码；成功后会自动返回。" };
  if (submit.matches(":disabled")) return { state: "waiting" };
  submit.click();
  return { state: "submitted" };
}
