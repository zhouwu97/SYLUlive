import {test,expect} from '@playwright/test';

async function openConnectionDialog(page: import('@playwright/test').Page) {
  await page.route('**/api/user/profile', route => route.fulfill({json:{id:7,nickname:'测试用户',role:'user'}}));
  await page.route('**/assistant/assistant.json', route => route.fulfill({status:404,body:'not found'}));
  await page.goto('schedule?week=1');
  await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
  await page.getByRole('button',{name:'连接教务助手 / 刷新'}).click();
}

test('本机授权完成后不刷新页面自动恢复，且不自动读取资料', async ({page}) => {
  let bindCalls = 0;
  await page.route('**/api/student-identity/bind', route => {bindCalls++;return route.fulfill({json:{ok:true}});});
  await page.addInitScript(() => {
    const state = window as unknown as {__bridgeOperations:string[]};
    state.__bridgeOperations = [];
    // 模拟「弹窗已打开但还没在助手页点授权，三秒后才授予本科教务权限」。
    const grantedAt = Date.now() + 3000;
    window.addEventListener('message', event => {
      const request = event.data;
      if (request?.direction !== 'request') return;
      state.__bridgeOperations!.push(request.operation);
      if (request.operation !== 'hello') return;
      const granted = Date.now() >= grantedAt;
      window.postMessage({...request,direction:'response',ok:true,result:{version:1,extensionVersion:'0.1.0',
        capabilities:['undergraduate','graduate','erke','physical'],connections:[],
        authorized:{undergraduate:granted,graduate:false,erke:false,physical:false}}}, location.origin);
    });
  });
  await openConnectionDialog(page);
  const guidance = page.getByText('本机助手还未获准访问这所学校的教务系统');
  await expect(guidance).toBeVisible();
  await expect(page.getByRole('button',{name:'打开助手完成授权'})).toBeVisible();
  await page.evaluate(() => {(window as unknown as {__noRefreshMarker:string}).__noRefreshMarker = 'same-document';});
  await expect(guidance).toHaveCount(0,{timeout:15000});
  await expect(page.getByRole('button',{name:'学校未登录？打开登录页'})).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as {__noRefreshMarker?:string}).__noRefreshMarker)).toBe('same-document');
  const operations = await page.evaluate(() => (window as unknown as {__bridgeOperations:string[]}).__bridgeOperations);
  expect([...new Set(operations)]).toEqual(['hello']);
  expect(bindCalls).toBe(0);
});

test('未获授权时按错误码给出授权引导，只保留一条状态播报', async ({page}) => {
  let bindCalls = 0;
  await page.route('**/api/student-identity/bind', route => {bindCalls++;return route.fulfill({json:{ok:true}});});
  await page.addInitScript(() => {
    window.addEventListener('message', event => {
      const request = event.data;
      if (request?.direction !== 'request') return;
      // 旧版助手不上报 authorized，页面只能靠失败码判定这一步卡在哪里。
      if (request.operation === 'hello')
        return window.postMessage({...request,direction:'response',ok:true,result:{version:1}}, location.origin);
      window.postMessage({...request,direction:'response',ok:false,
        error:{code:'authorization_required',message:'请在助手页面授予学校域名权限'}}, location.origin);
    });
  });
  await openConnectionDialog(page);
  await page.getByRole('button',{name:'连接并读取资料'}).click();
  await expect(page.locator('.dialog-form [role="status"]')).toHaveText('请在助手页面授予学校域名权限');
  await expect(page.locator('.dialog-form [role="status"]')).toHaveCount(1);
  await expect(page.getByText('本机助手还未获准访问这所学校的教务系统')).toBeVisible();
  await expect(page.getByRole('button',{name:'打开助手完成授权'})).toBeVisible();
  await expect(page.getByRole('button',{name:'连接并读取资料'})).toBeEnabled();
  expect(bindCalls).toBe(0);
});

test('学校对该学期没有排课时保留本机课表', async ({page}) => {
  await page.route('**/api/student-identity/bind', route => route.fulfill({json:{ok:true}}));
  await page.addInitScript(() => {
    let queries = 0;
    window.addEventListener('message', event => {
      const request = event.data;
      if (request?.direction !== 'request') return;
      if (request.operation === 'query')
        return window.postMessage({...request,direction:'response',ok:true,result:{
          fetchedAt:new Date().toISOString(),
          // 首次拉到一节排课，复检时正方按错误学期返回空列表。
          data:++queries===1?[{id:'test-course',name:'连接测试课程',teacher:'',room:'测试教室',day:1,periods:[1,2],weeks:[1]}]:[],
        }}, location.origin);
      const results: Record<string, unknown> = {
        hello: {version:1},
        session: {appUserId:7,provider:'undergraduate',studentId:'2403000001',displayName:'测试同学',epoch:'test-session'},
      };
      window.postMessage({...request,direction:'response',ok:true,result:results[request.operation]}, location.origin);
    });
  });
  await openConnectionDialog(page);
  await page.getByRole('button',{name:'连接并读取资料'}).click();
  const course = page.getByRole('button',{name:'连接测试课程 测试教室'});
  await expect(course).toBeVisible();
  await page.getByRole('button',{name:'连接教务助手 / 刷新'}).click();
  await page.getByRole('button',{name:'连接并读取资料'}).click();
  await expect(page.locator('.dialog-form [role="status"]')).toContainText('已保留本机原有资料');
  await expect(course).toHaveCount(1);
});
