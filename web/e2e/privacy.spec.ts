import {test,expect} from '@playwright/test';
test('个人成绩分析入口下线后旧链接不读取或发送成绩摘要',async({page})=>{
  await page.route('**/api/**',route=>route.fulfill({json:{items:[]}}));
  const requests: string[] = [];
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'隐私测试',role:'user'}}));
  await page.route('**/api/ai/local-analysis**', route => {
    requests.push(route.request().method());
    return route.fulfill({json:{models:['test-model'],default_model:'test-model'}});
  });
  await page.goto('schedule');await expect(page.getByRole('button',{name:'我的账号'})).toBeVisible();
  await page.getByRole('button',{name:'课表设置',exact:true}).click();
  const archive={version:1,term:{year:'2026',semester:'3'},termStart:'2026-09-07',courses:[],overrides:{},exams:[],grades:[{id:'grade-private',name:'不应传输的课程名',credit:2,score:'85',gpa:3.5,nature:'必修',term:'2026-3'}]};
  await page.getByLabel('导入本地资料（将替换当前数据）').setInputFiles({name:'data.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(archive))});
  await page.goto('ai');
  await expect(page).toHaveURL(/\/web\/campus$/);
  await expect(page.getByRole('heading',{name:'校园',exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'分析我的成绩摘要'})).toHaveCount(0);
  expect(requests).toEqual([]);
});
