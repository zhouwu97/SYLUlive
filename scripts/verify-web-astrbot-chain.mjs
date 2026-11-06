// Synthetic loopback acceptance only. The Go test owns the HTTP server and database.
import { chromium, expect } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const origin = process.env.SYLULIVE_FULL_CHAIN_ORIGIN;
if (new URL(origin).hostname !== '127.0.0.1') throw new Error('Loopback test server required');
const browser = await chromium.launch({headless:true});
const context = await browser.newContext();
const action = process.argv[2];
const diagnostics = { action, phase: 'cookie_seed', passed: false, events: [] };
const diagnosticDirectory = process.env.SYLULIVE_FULL_CHAIN_DIAGNOSTIC_DIR;
const started = Date.now();
const requestStarted = new WeakMap();
const safePath = value => {
  const parsed = new URL(value);
  if (parsed.origin !== origin) return null;
  if (!/^\/api\/(?:user\/profile|refresh|auth\/refresh|connected-apps(?:\/.*)?|personal-snapshots\/erke|water-sections)$/.test(parsed.pathname)) return null;
  return parsed.pathname.replace(/\/[0-9]+(?=\/|$)/g, '/:id');
};
const record = value => { if (diagnostics.events.length < 120) diagnostics.events.push({at_ms:Date.now()-started,phase:diagnostics.phase,...value}); };
try {
  await context.addCookies([{name:'jwt',value:process.env.SYLULIVE_FULL_CHAIN_JWT,url:origin,httpOnly:true,sameSite:'Lax'}]);
  await context.route('**/*',route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
  const page = await context.newPage();
  if (diagnosticDirectory) {
    page.on('request',request=>{const route=safePath(request.url());if(route){requestStarted.set(request,Date.now());record({kind:'request',path:route,method:request.method()});}});
    page.on('response',response=>{const route=safePath(response.url());if(route)record({kind:'response',path:route,status:response.status(),elapsed_ms:Date.now()-(requestStarted.get(response.request())||Date.now())});});
    page.on('requestfailed',request=>{const route=safePath(request.url());if(route){const failure=request.failure()?.errorText||'';record({kind:'request_failed',path:route,classification:failure.includes('ERR_ABORTED')?'aborted':failure.includes('ERR_CONNECTION')?'connection':'other'});}});
    const cookies=await context.cookies(origin);
    const cookie=cookies.find(item=>item.name==='jwt');
    diagnostics.cookie_seed={present:!!cookie,http_only:cookie?.httpOnly===true,secure:cookie?.secure===true,path_matches:cookie?.path==='/',session_cookie:cookie?.expires===-1};
  }
  await page.addInitScript(() => {
    window.addEventListener('message',event => {
      const r=event.data;
      if(r?.channel!=='sylulive-academic-v1'||r.direction!=='request')return;
      const p=r.payload?.provider||'undergraduate';
      const connection=provider=>({appUserId:91234,provider,studentId:'2099000001',displayName:'跨端合成学校身份',epoch:provider+'-synthetic',state:'connected'});
      const data=p==='erke'?{earned:12,required:16,categories:[{name:'合成分类',earned:2,required:6}]}:[{id:'synthetic-grade',name:'跨端合成课程',score:'88',credit:2,gpa:3.5,nature:'必修',term:'2026-3'}];
      const result=r.operation==='hello'?{version:1,connections:['undergraduate','erke'].map(connection)}:r.operation==='session'?connection(p):{...connection(p),dataset:p==='erke'?'erke':'grades',fetchedAt:new Date().toISOString(),term:{year:'2026',semester:'3'},data};
      window.postMessage({...r,direction:'response',ok:true,result},location.origin);
    });
  });
  diagnostics.phase='navigation';
  await page.goto(origin+'/web/connected-apps'+(action==='approve'?'?user_code='+encodeURIComponent(process.env.SYLULIVE_FULL_CHAIN_CODE):''));
  diagnostics.phase='auth_ready';
  await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
  diagnostics.phase=action;
  if(action==='approve') {
    await page.getByRole('button',{name:'查看授权请求',exact:true}).click();
    for(const name of [/读取本人主动同步的成绩/,/读取本人主动同步的二课/]) {
      const box=page.getByRole('checkbox',{name});
      await expect(box).not.toBeChecked();
      await box.check();
    }
    for(const name of [/待本人确认的帖子或评论草稿/,/以本人管理的独立AI机器人自动评论/,/以独立AI机器人自动发帖/]) {
      const box=page.getByRole('checkbox',{name});await expect(box).not.toBeChecked();await box.check();
    }
    await page.getByRole('checkbox',{name:/我已核对连接码与当前账号/}).check();
    await page.getByRole('button',{name:'授权此助手',exact:true}).click();
    await expect(page.getByText(/已授权。返回 AstrBot/)).toBeVisible();
  } else if(action==='bot') {
    await page.getByLabel('机器人名称').fill('跨端合成机器人');
    await page.getByRole('button',{name:'新建机器人',exact:true}).click();
    await expect(page.getByText(/机器人 #.*已暂停/)).toBeVisible();
    for(const label of ['自动文字评论','发表内置表情','自动发布帖子','使用已审核公开配图']) await page.getByLabel(label,{exact:false}).check();
    await page.getByLabel(/禁止在.*发送链接/).uncheck();
    await page.getByRole('button',{name:'保存并启用',exact:true}).click();
    await expect(page.getByText(/机器人 #.*已启用/)).toBeVisible();
  } else if(action==='sync') {
    await page.getByRole('navigation',{name:'助手管理分区'}).getByRole('button',{name:'个人资料同步',exact:true}).click();
    for(const dataset of ['grades','erke']) {
      await page.getByRole('combobox',{name:'资料类型'}).selectOption(dataset);
      await page.getByRole('button',{name:'从本机教务助手读取',exact:true}).click();
      await page.getByRole('button',{name:'查询并更新资料',exact:true}).click();
      await expect(page.locator('.dialog-form')).toHaveCount(0);
      const confirm=page.getByRole('button',{name:'确认同步最小资料',exact:true});
      await expect(confirm).toBeDisabled();
      await page.getByRole('checkbox',{name:/我确认仅操作当前账号的资料/}).check();
      const path=dataset==='grades'?'/api/connected-apps/personal-sync/grades':'/api/personal-snapshots/erke';
      const [response]=await Promise.all([page.waitForResponse(r=>new URL(r.url()).pathname===path),confirm.click()]);
      if(!response.ok())throw new Error(`Synthetic ${dataset} upload failed (${response.status()}): ${await response.text()}`);
      await expect(page.getByText(/已同步最小资料/)).toBeVisible();
    }
  } else if(action==='revoke') {
    await page.getByRole('navigation',{name:'助手管理分区'}).getByRole('button',{name:'连接 AstrBot',exact:true}).click();
    await page.getByRole('button',{name:'断开此连接',exact:true}).click();
    const disconnect=page.getByRole('group',{name:'确认断开连接',exact:true});
    await expect(disconnect.getByRole('button',{name:'确认断开连接',exact:true})).toBeDisabled();
    await disconnect.getByRole('checkbox',{name:'我确认断开这条连接',exact:true}).check();
    await disconnect.getByRole('button',{name:'确认断开连接',exact:true}).click();
    await expect(page.getByText(/^已断开这条连接。旧凭证/)).toBeVisible();
  } else throw new Error('Unknown test action');
  diagnostics.passed=true;
  console.log(JSON.stringify({action,passed:true}));
} finally {
  if (diagnosticDirectory) {
    await mkdir(diagnosticDirectory,{recursive:true});
    await writeFile(path.join(diagnosticDirectory,action+'.json'),JSON.stringify(diagnostics,null,2)+'\n');
    if(!diagnostics.passed) console.error(JSON.stringify({safe_web_diagnostic:diagnostics}));
  }
  await context.close();await browser.close();
}
