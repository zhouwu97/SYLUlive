import { test, expect, chromium } from "@playwright/test";
import { mkdtemp, rm, mkdir, cp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

async function command(page: import('@playwright/test').Page, operation: string, payload: Record<string, unknown>) {
  return page.evaluate(({operation,payload})=>new Promise<any>((resolve,reject)=>{
    const id=crypto.randomUUID(),timer=setTimeout(()=>reject(new Error('助手命令超时')),8000);
    const listener=(event:MessageEvent)=>{if(event.data?.id!==id||event.data.direction!=='response')return;clearTimeout(timer);window.removeEventListener('message',listener);resolve(event.data)};
    window.addEventListener('message',listener);window.postMessage({channel:'sylulive-academic-v1',direction:'request',version:1,id,operation,payload},location.origin);
  }),{operation,payload});
}

async function vaultKeys(worker: import('@playwright/test').Worker) {
  return worker.evaluate(async () => {
    const db = await new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('sylulive-academic',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
    const keys = await new Promise<IDBValidKey[]>((resolve,reject)=>{const r=db.transaction('data').objectStore('data').getAllKeys();r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
    db.close();return keys.filter(key=>String(key).startsWith('school-credentials:'));
  });
}

for (const provider of ["undergraduate", "erke"] as const) {
  test(`${provider}真实扩展首次保存授权、第二次自动登录回跳并拉取、断开清除凭据`, async () => {
    test.setTimeout(120_000);
    const profileDir = await mkdtemp(resolve(tmpdir(), "sylulive-autologin-"));
    const extension = resolve(profileDir, "extension");
    await cp(resolve("browser-extension/dist-dev"), extension, { recursive: true });
    const manifest = JSON.parse(await readFile(resolve(extension, "manifest.json"), "utf8"));
    // Headless Chromium 无法操作浏览器原生的 optional host 权限弹窗；仅在临时
    // 测试包预授予本用例学校域名，扩展源码与生产 manifest 仍按点击请求权限。
    manifest.host_permissions.push(provider === "erke" ? "https://webvpn.sylu.edu.cn/*" : "https://jxw.sylu.edu.cn/*");
    await writeFile(resolve(extension, "manifest.json"), JSON.stringify(manifest));
    const launch = () => chromium.launchPersistentContext(resolve(profileDir, "profile"), { channel: "chromium", headless: true,
      args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`, "--host-resolver-rules=MAP *.sylu.edu.cn ~NOTFOUND"] });
    let context = await launch();
    const browserErrors: string[] = [];
    try {
      let worker = context.serviceWorkers()[0] || await context.waitForEvent("serviceworker");
      const origin = provider === "erke" ? "https://webvpn.sylu.edu.cn" : "https://jxw.sylu.edu.cn";
      const account = "2099000001";
      let schoolReady = false, vpnReady = false, logins = 0, vpnLogins = 0, loginAttempts = 0;
      let holdIdentity = false, releaseIdentity: (()=>void)|undefined;
      let expectedPassword = "synthetic-school-secret";
      const loginHtml = provider === "undergraduate"
        ? `<form><input id=yhm><input id=mm type=password><button id=dl type=button>登录</button></form><script>Array.prototype.some=function(){throw new Error('school Array.some replacement')};dl.onclick=async()=>{const r=await fetch('/fixture-login',{method:'POST',body:JSON.stringify({account:yhm.value,password:mm.value})});if(!(await r.json()).ok)return;location.href='/home'}</script>`
        : `<form><input id=UserName><input id=Password type=password><input id=codeInput><span id=code-box>K777</span><button id=queryBtn type=button>登录</button></form><script>queryBtn.onclick=async()=>{const r=await fetch('/fixture-login',{method:'POST',body:JSON.stringify({account:UserName.value,password:Password.value,code:codeInput.value})});if(!(await r.json()).ok)return;location.href='main.htm'}</script>`;
      const identityHtml = provider === "undergraduate"
        ? `<span id=col_xh>${account}</span><input id=xh_id value=${account}><input id=curXh_id value=${account}><span id=col_xm>合成测试</span>`
        : `<a href=ExitWindows.aspx>退出系统</a><div>${account}</div>`;
      const erkeData = ["SunCount", "SunCount1", ...["A", "B", "C", "D", "E"].flatMap(c => ["Count" + c, "Count" + c + "1"])].map(id => `<span id=${id}>10</span>`).join("");
      const gradeJson = { items: [{ kch_id: "fixture", kcmc: "自动拉取合成课程", xf: "2", cj: "92", jd: "4", kcxzmc: "必修", xnm: "2026", xqm: "3" }] };
      async function prepareContext() {
      context.on("page", page => {
        page.on("pageerror", error => browserErrors.push(error.message));
        page.on("console", message => { if (message.type() === "error") browserErrors.push(message.text()); });
      });
      // 扩展 chrome.tabs.create 的首个导航早于 Playwright 路由接管。学校页改由
      // 已接管的空白测试标签导航到夹具，域名解析同时封锁真实学校网络。
      await context.exposeBinding("__fixtureSchoolTab", async (_source, url: string) => {
        const school = await context.newPage();
        await school.goto(url);
        return worker.evaluate(async href => (await chrome.tabs.query({})).find(tab => tab.url === href), school.url());
      });
      await context.addInitScript(({ origin }) => {
        if (location.protocol !== "chrome-extension:") return;
        const create = chrome.tabs.create.bind(chrome.tabs);
        chrome.tabs.create = ((options: chrome.tabs.CreateProperties) => typeof options.url === "string" && options.url.startsWith(origin + "/")
          ? (window as any).__fixtureSchoolTab(options.url) : create(options)) as typeof chrome.tabs.create;
      }, { origin });
      // Service Worker 请求无法由 page.route 覆盖；只提供固定夹具，禁止真实外联。
      await worker.evaluate(({ origin, identityHtml, loginHtml, erkeData, gradeJson }) => {
        (self as any).__schoolReady = false;
        (self as any).__appUserId = 7;
        self.fetch = (async (input: RequestInfo | URL) => {
          const url = String(input), path = new URL(url).pathname;
          let body: string;
          if (url === "http://127.0.0.1:5173/api/user/profile") body = JSON.stringify({ id: (self as any).__appUserId, nickname: "合成测试", role: "user" });
          else if (new URL(url).origin !== origin) throw new Error("测试禁止外联");
          else if (!(self as any).__schoolReady) body = loginHtml;
          else if (path.includes("xsgrxx") || path.endsWith("top.aspx")) body = identityHtml;
          else if (path.includes("cjcx_cxXsgrcj")) body = JSON.stringify(gradeJson);
          else if (path.endsWith("StuFinishStudentScore.aspx")) body = erkeData;
          else body = "<html><body>学校夹具</body></html>";
          const response = new Response(body, { status: url.endsWith('/api/user/profile') && !(self as any).__appUserId ? 401 : 200, headers: { "content-type": "text/html; charset=utf-8" } });
          Object.defineProperty(response, "url", { value: url });
          return response;
        }) as typeof fetch;
      }, { origin, identityHtml, loginHtml, erkeData, gradeJson });
      await context.route("**/api/**", route => route.fulfill({ json: route.request().url().endsWith("/user/profile") ? { id: 7, nickname: "合成测试", role: "user" } : { ok: true } }));
      await context.route(`${origin}/**`, async route => {
        const path = new URL(route.request().url()).pathname;
        if (holdIdentity && (path.includes('xsgrxx') || path.endsWith('top.aspx'))) await new Promise<void>(resolve=>{releaseIdentity=resolve});
        if (path === "/fixture-login") {
          const credentials = JSON.parse(route.request().postData()!);
          expect(credentials.account).toBe(account);
          loginAttempts++;
          if (credentials.password !== expectedPassword) { await route.fulfill({json:{ok:false}}); return; }
          if (provider === "erke") expect(credentials.code).toBe("K777");
          logins++; schoolReady = true;
          await worker.evaluate(() => { (self as any).__schoolReady = true; });
          await route.fulfill({ json: { ok: true } }); return;
        }
        if (path === "/fixture-vpn-login") {
          expect(JSON.parse(route.request().postData()!)).toEqual({ account, password: "synthetic-vpn-secret" });
          vpnReady = true; vpnLogins++;
          await route.fulfill({ json: { ok: true } }); return;
        }
        let body = loginHtml;
        if (provider === "erke" && path.toLowerCase().endsWith("userlogin.aspx") && !vpnReady) {
          // 浏览器对 fulfill(302) 的后续请求不再经过同一路由，改用页面导航，
          // 使全部认证跳转继续由夹具接管，DNS 封锁也一直有效。
          await route.fulfill({ contentType: "text/html", body: '<script>location.href="/login"</script>' }); return;
        }
        if (path === "/login") body = '<a href="/cas_login">统一认证登录</a>';
        else if (path === "/cas_login") body = '<script>location.href="/authserver/login"</script>';
        else if (path === "/authserver/login") body = `<form><input id=username><input id=userPassword type=password><button id=login_submit type=button>统一认证登录</button></form><script>login_submit.onclick=async()=>{await fetch('/fixture-vpn-login',{method:'POST',body:JSON.stringify({account:username.value,password:userPassword.value})});location.href='/'}</script>`;
        else if (path === "/" && vpnReady) body = "<p>已登录 VPN 门户</p>";
        else if (path.includes("xsgrxx") || path.endsWith("top.aspx")) body = schoolReady ? identityHtml : loginHtml;
        else if (path.includes("/home") || path.endsWith("main.htm")) body = "<p>学校登录成功</p>";
        await route.fulfill({ contentType: "text/html; charset=utf-8", body });
      });
      }
      await prepareContext();
      let page = await context.newPage();
      await page.goto(`http://127.0.0.1:5173/web/grades${provider === "erke" ? "?tab=erke" : ""}`);
      await page.evaluate(() => { (window as any).__bridgeMessages = []; window.addEventListener("message", event => { if (event.data?.channel === "sylulive-academic-v1") (window as any).__bridgeMessages.push(event.data); }); });
      await expect(page.getByRole("button", { name: "我的账号" })).toBeVisible();
      await page.getByRole("button", { name: "更新本地资料" }).click();
      await page.getByRole("button", { name: "连接并读取资料", exact: true }).click();
      await expect.poll(() => context.pages().some(p => p.url().includes("assistant.html?provider="))).toBe(true);
      const assistant = context.pages().find(p => p.url().includes("assistant.html?provider="))!;
      await expect(assistant.getByLabel("学号")).toBeEnabled().catch(async error=>{
        const state=await worker.evaluate(async()=>({flows:Object.entries(await chrome.storage.session.get(null)).filter(([k])=>k.startsWith('login-flow:')),tabs:(await chrome.tabs.query({})).map(t=>({id:t.id,url:t.url,pendingUrl:t.pendingUrl,status:t.status}))}));
        throw new Error(`${error.message}\n助手：${await assistant.locator('#status').innerText()}\n${JSON.stringify(state)}`);
      });
      await expect(assistant.getByRole("checkbox")).not.toBeChecked();
      await assistant.getByLabel("学号").fill(account);
      await assistant.getByLabel(provider === "erke" ? "二课系统密码" : "教务密码", { exact: true }).fill("synthetic-school-secret");
      if (provider === "erke") await assistant.getByLabel("统一认证密码（WebVPN）").fill("synthetic-vpn-secret");
      // 拒绝授权不打开学校页、不保存凭据，按钮可以再次尝试。
      await assistant.evaluate(() => { (window as any).__requestPermission = chrome.permissions.request; chrome.permissions.request = (async () => false) as typeof chrome.permissions.request; });
      await assistant.getByRole("button", { name: "授权并自动登录", exact: true }).click();
      await expect(assistant.locator("#status")).toContainText("未授予学校访问权限");
      expect(logins).toBe(0);
      await assistant.evaluate(()=>{chrome.permissions.request=(()=>{throw new Error('授权调用暂时失败')}) as typeof chrome.permissions.request});
      await assistant.getByRole('button',{name:'授权并自动登录',exact:true}).click();
      await expect(assistant.locator('#status')).toContainText('授权调用暂时失败');
      await expect(assistant.getByLabel('学号')).toBeEnabled();
      await assistant.evaluate(() => { chrome.permissions.request = (window as any).__requestPermission; });
      await assistant.getByRole("checkbox").check();
      await mkdir(resolve("artifacts/assistant-login"), { recursive: true });
      await assistant.screenshot({ path: resolve(`artifacts/assistant-login/${provider}-first-consent.png`), fullPage: true });
      await assistant.setViewportSize({ width: 375, height: 812 });
      expect(await assistant.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await assistant.screenshot({ path: resolve(`artifacts/assistant-login/${provider}-mobile-consent.png`), fullPage: true });
      await assistant.getByRole("button", { name: "授权并自动登录", exact: true }).click();
      await expect(page.locator(".dialog-form")).toHaveCount(0, { timeout: 20_000 }).catch(async error => {
        const status = assistant.isClosed() ? "已关闭" : await assistant.locator("#status").innerText();
        throw new Error(`${error.message}\n助手状态：${status}\n页面：${context.pages().map(p => p.url()).join(", ")}\n浏览器错误：${browserErrors.join(" | ")}`);
      });
      await expect(page.getByText(provider === "erke" ? "思想成长" : "自动拉取合成课程", { exact: true })).toBeVisible();
      expect(logins).toBe(1);
      if (provider === "erke") expect(vpnLogins).toBe(1);
      await expect.poll(() => assistant.isClosed()).toBe(true);
      // 过期学校会话，第二次只点击网页更新，不再次输入或点击助手页。
      schoolReady = false; vpnReady = false;
      await worker.evaluate(() => { (self as any).__schoolReady = false; });
      await page.getByRole("button", { name: "更新本地资料" }).click();
      await page.getByRole("button", { name: "连接并读取资料", exact: true }).click();
      await expect(page.locator(".dialog-form")).toHaveCount(0, { timeout: 20_000 });
      expect(logins).toBe(2);
      if (provider === "erke") expect(vpnLogins).toBe(2);
      // 保存的旧密码被学校拒绝后，可在同一任务中修改，不能取消后假装还能重试。
      expectedPassword = "synthetic-updated-secret";
      schoolReady = false; vpnReady = false;
      await worker.evaluate(() => { (self as any).__schoolReady = false; });
      await page.getByRole('button',{name:'更新本地资料'}).click();
      await page.getByRole('button',{name:'连接并读取资料',exact:true}).click();
      await expect.poll(()=>loginAttempts,{timeout:20000}).toBe(3);
      const retryAssistant = context.pages().find(p=>p.url().includes('assistant.html?provider='))!;
      const retryUrl = retryAssistant.url();
      await retryAssistant.getByRole('button',{name:'修改登录信息并重试'}).click();
      const passwordField = retryAssistant.getByLabel(provider==='erke'?'二课系统密码':'教务密码',{exact:true});
      await expect(passwordField).toBeEnabled();
      expect(loginAttempts).toBe(3);
      expect(retryAssistant.url()).toBe(retryUrl);
      await passwordField.fill(expectedPassword);
      await retryAssistant.getByRole('button',{name:'授权并自动登录',exact:true}).click();
      await expect(page.locator('.dialog-form')).toHaveCount(0,{timeout:20000});
      expect(logins).toBe(3); expect(loginAttempts).toBe(4);
      const previousMessages = await page.evaluate(()=>JSON.stringify((window as any).__bridgeMessages));
      // 真正关闭并重开同一浏览器 profile，验证 IndexedDB CryptoKey 和双密码可重读。
      await context.close();
      schoolReady=false;vpnReady=false;
      context=await launch();
      worker=context.serviceWorkers()[0]||await context.waitForEvent('serviceworker');
      await prepareContext();
      page=await context.newPage();
      await page.goto(`http://127.0.0.1:5173/web/grades${provider==='erke'?'?tab=erke':''}`);
      await page.evaluate(()=>{(window as any).__bridgeMessages=[];window.addEventListener('message',event=>{if(event.data?.channel==='sylulive-academic-v1')(window as any).__bridgeMessages.push(event.data)})});
      await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
      await page.getByRole('button',{name:'更新本地资料'}).click();
      await page.getByRole('button',{name:'连接并读取资料',exact:true}).click();
      await expect(page.locator('.dialog-form')).toHaveCount(0,{timeout:20000});
      expect(logins).toBe(4);expect(loginAttempts).toBe(5);
      const publicMessages = await page.evaluate(() => JSON.stringify((window as any).__bridgeMessages));
      for(const secret of ['synthetic-school-secret','synthetic-vpn-secret','synthetic-updated-secret','"password"','"vpnPassword"']) expect(previousMessages+publicMessages).not.toContain(secret);
      await page.screenshot({ path: resolve(`artifacts/assistant-login/${provider}-returned-data.png`), fullPage: true });
      // 站点已经退出时仍可清除本机连接，保存凭据保持按本人账号隔离。
      await worker.evaluate(()=>{(self as any).__appUserId=0});
      expect((await command(page,'disconnect',{provider,localOnly:true,appUserId:7})).ok).toBe(true);
      expect(await vaultKeys(worker)).toHaveLength(1);
      expect(await worker.evaluate(async()=>Object.keys(await chrome.storage.session.get(null)).filter(k=>k.startsWith('connection:')))).toHaveLength(0);
      await worker.evaluate(()=>{(self as any).__appUserId=7});
      await page.getByRole('button',{name:'更新本地资料'}).click();
      await page.getByRole('button',{name:'连接并读取资料',exact:true}).click();
      await expect(page.locator('.dialog-form')).toHaveCount(0);
      await page.getByRole("button", { name: "更新本地资料" }).click();
      await expect(page.getByRole("button", { name: "断开并清除当前资料" })).toBeVisible();
      await page.getByRole("button", { name: "断开并清除当前资料" }).click();
      await expect(page.getByRole("button", { name: "断开并清除当前资料" })).toHaveCount(0);
      expect(await vaultKeys(worker)).toHaveLength(0);
      // 损坏密文不会自动删除或挡住恢复入口，用户可明确清除后再连接。
      await worker.evaluate(async provider=>{
        const db=await new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('sylulive-academic',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
        await new Promise<void>((resolve,reject)=>{const tx=db.transaction('data','readwrite');tx.objectStore('data').put({iv:[0],data:[1]},`school-credentials:http://127.0.0.1:5173:7:${provider}`);tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error)});
        db.close();
      },provider);
      const damagedFlow=await command(page,'connect',{provider});
      await expect.poll(()=>context.pages().some(p=>p.url().includes(`flow=${damagedFlow.result.flowId}`))).toBe(true);
      const damaged=context.pages().find(p=>p.url().includes(`flow=${damagedFlow.result.flowId}`))!;
      await expect(damaged.locator('#status')).toContainText('无法解密');
      await damaged.getByRole('button',{name:'清除已保存凭据'}).click();
      await expect(damaged.locator('#status')).toContainText('已停止自动登录并清除');
      expect(await vaultKeys(worker)).toHaveLength(0);
      // 在 connect 响应前关闭/取消的竞态也必须使后台登录任务失效。
      await page.evaluate(provider => new Promise<void>((resolve, reject) => {
        const id = "cancel-during-connect", timer = setTimeout(() => reject(new Error("取消登录任务超时")), 5000);
        const listener = (event: MessageEvent) => {
          if (event.data?.id !== id || event.data.direction !== "response") return;
          clearTimeout(timer); window.removeEventListener("message", listener); resolve();
        };
        window.addEventListener("message", listener);
        const base = { channel: "sylulive-academic-v1", direction: "request", version: 1 };
        window.postMessage({ ...base, id, operation: "connect", payload: { provider } }, location.origin);
        window.postMessage({ ...base, id: "cancel-message", operation: "cancel", payload: { requestId: id } }, location.origin);
      }), provider);
      await expect.poll(() => worker.evaluate(async () => Object.entries(await chrome.storage.session.get(null))
        .filter(([key, value]) => key.startsWith("login-flow:") && value.requestId === "cancel-during-connect")
        .every(([, value]) => value.state === "cancelled"))).toBe(true);
      // 身份请求在途时切号：提交密码前必须再核对一次当前账号。
      schoolReady=false;vpnReady=false;
      const priorVpnLogins=vpnLogins;
      await worker.evaluate(()=>{(self as any).__schoolReady=false});
      const connect = await command(page,'connect',{provider});
      expect(connect.ok).toBe(true);
      await expect.poll(()=>context.pages().some(p=>p.url().includes(`flow=${connect.result.flowId}`))).toBe(true);
      const switched = context.pages().find(p=>p.url().includes(`flow=${connect.result.flowId}`))!;
      await expect(switched.getByLabel('学号')).toBeEnabled();
      await switched.getByLabel('学号').fill(account);
      await switched.getByLabel(provider==='erke'?'二课系统密码':'教务密码',{exact:true}).fill(expectedPassword);
      if(provider==='erke')await switched.getByLabel('统一认证密码（WebVPN）').fill('synthetic-vpn-secret');
      holdIdentity=true;
      await switched.getByRole('button',{name:'授权并自动登录',exact:true}).click();
      await expect.poll(()=>Boolean(releaseIdentity)).toBe(true);
      await worker.evaluate(()=>{(self as any).__appUserId=8});
      holdIdentity=false;releaseIdentity!();
      await expect(switched.locator('#status')).toContainText('账号已改变',{timeout:10000});
      expect(loginAttempts).toBe(5);
      expect(vpnLogins).toBe(priorVpnLogins);
      await expect(switched.getByRole('button',{name:'授权并自动登录',exact:true})).toBeDisabled();
      // 助手标签被导航离开时也算结束，不能仅凭标签 ID 仍存在而等待五分钟。
      await worker.evaluate(()=>{(self as any).__appUserId=7});
      await switched.goto('http://127.0.0.1:5173/web/grades');
      const navigated = await command(page,'loginStatus',{provider,flowId:connect.result.flowId});
      expect(navigated.ok).toBe(true);expect(navigated.result.state).toBe('cancelled');
      // 登录请求在途时清除已保存凭据：旧请求结束不能提交或覆盖清除成功状态。
      await worker.evaluate(async({provider,account,password})=>{
        const scope=`school-credentials:http://127.0.0.1:5173:7:${provider}`;
        const key=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
        const iv=crypto.getRandomValues(new Uint8Array(12));
        const credentials={account,password,...(provider==='erke'?{vpnPassword:'synthetic-vpn-secret'}:{})};
        const data=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:new TextEncoder().encode(scope)},key,new TextEncoder().encode(JSON.stringify(credentials)));
        const db=await new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('sylulive-academic',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
        await new Promise<void>((resolve,reject)=>{const tx=db.transaction('data','readwrite');tx.objectStore('data').put({key,iv:[...iv],data:[...new Uint8Array(data)]},scope);tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error)});
        db.close();(self as any).__schoolReady=false;
      },{provider,account,password:expectedPassword});
      holdIdentity=true;releaseIdentity=undefined;
      const clearFlow=await command(page,'connect',{provider});
      await expect.poll(()=>Boolean(releaseIdentity)).toBe(true);
      const clearing=context.pages().find(p=>p.url().includes(`flow=${clearFlow.result.flowId}`))!;
      await clearing.getByRole('button',{name:'清除已保存凭据'}).click();
      await expect(clearing.locator('#status')).toContainText('已停止自动登录并清除');
      holdIdentity=false;releaseIdentity!();
      await clearing.waitForTimeout(1800);
      await expect(clearing.locator('#status')).toContainText('已停止自动登录并清除');
      expect(await vaultKeys(worker)).toHaveLength(0);
      expect(loginAttempts).toBe(5);expect(vpnLogins).toBe(priorVpnLogins);
    } finally {
      await context.close();
      if (!resolve(profileDir).startsWith(resolve(tmpdir(), "sylulive-autologin-"))) throw new Error("临时目录超出预期范围");
      await rm(profileDir, { recursive: true, force: true });
    }
  });
}
