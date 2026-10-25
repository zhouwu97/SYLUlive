import {test, expect} from '@playwright/test';

test('连接一次即可绑定并读取课表，不重复确认身份', async ({page}) => {
  await page.route('**/api/user/profile', route => route.fulfill({json:{id:7,nickname:'测试用户',role:'user'}}));
  let binding: unknown;
  await page.route('**/api/student-identity/bind', route => {
    binding = route.request().postDataJSON();
    return route.fulfill({json:{ok:true}});
  });
  await page.addInitScript(() => {
    window.addEventListener('message', event => {
      const request = event.data;
      if (request?.direction !== 'request') return;
      const results: Record<string, unknown> = {
        hello: {version:1},
        session: {appUserId:7,provider:'undergraduate',studentId:'2403000001',displayName:'测试同学',epoch:'test-session'},
        query: {fetchedAt:new Date().toISOString(),data:[{id:'test-course',name:'连接测试课程',teacher:'',room:'测试教室',day:new Date().getDay() || 7,periods:[1,2],weeks:[1]}]},
      };
      window.postMessage({...request,direction:'response',ok:true,result:results[request.operation]}, location.origin);
    });
  });
  await page.goto('./');
  await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
  await expect(page.locator('.today-card')).toContainText('课表尚未连接');
  await expect(page.locator('.today-time')).toHaveCount(0);
  await page.getByRole('button',{name:'连接教务助手',exact:true}).click();
  await expect(page).toHaveURL(/schedule/);
  await page.getByRole('button',{name:'连接教务助手 / 刷新'}).click();
  await page.getByRole('button',{name:'连接并读取资料'}).click();
  await expect(page.getByRole('button',{name:'连接测试课程 测试教室'})).toBeVisible();
  expect(binding).toEqual({provider_id:'sylu_undergraduate',student_id:'2403000001',verification_method:'local_academic_login'});
  await page.getByRole('link',{name:'校园工作台',exact:true}).click();
  await expect(page.locator('.today-card h2')).toHaveText('连接测试课程');
  await expect(page.locator('.today-time')).toHaveText('1');
  await expect(page.locator('.today-card')).toContainText('测试教室');
  await page.setViewportSize({width:375,height:812});
  await page.getByRole('button',{name:'查看今日课表',exact:true}).click();
  await expect(page).toHaveURL(/schedule/);
});

test('缺少扩展时快速失败并恢复按钮', async ({page}) => {
  await page.route('**/api/user/profile', route => route.fulfill({json:{id:7,nickname:'测试用户',role:'user'}}));
  await page.goto('schedule');
  await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
  await page.getByRole('button',{name:'连接教务助手 / 刷新'}).click();
  await page.getByRole('button',{name:'连接并读取资料'}).click();
  await expect(page.locator('.dialog-form [role="status"]')).toContainText('未检测到教务助手');
  await expect(page.getByRole('button',{name:'连接并读取资料'})).toBeEnabled();
});
