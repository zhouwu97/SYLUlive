import {test,expect} from '@playwright/test';

test.beforeEach(async({page})=>{
  await page.route('**/api/**',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'布局测试',role:'user'}}));
});
test('原型主要页签和右栏范围恢复',async({page})=>{
  await page.goto('canteen');
  for(const name of ['食堂主页','店铺菜品','食堂排行','我的贡献'])await expect(page.getByRole('tab',{name,exact:true})).toBeVisible();
  await page.getByRole('tab',{name:'食堂排行'}).click();await expect(page).toHaveURL(/tab=ranking/);
  await page.goto('competition');
  for(const name of ['推荐','竞赛目录','我的日历','我的获奖','能力档案'])await expect(page.getByRole('tab',{name,exact:true})).toBeVisible();
  await page.goto('community');
  await expect(page.getByRole('tab',{name:'我的发布'})).toBeVisible();await expect(page.getByRole('tab',{name:'收藏'})).toBeVisible();
  await page.goto('campus');await expect(page.locator('.quick-grid .quick')).toHaveCount(4);await expect(page.locator('.right-rail')).toHaveCount(0);
  await page.goto('market');await expect(page.locator('.right-rail')).toHaveCount(0);
});
test('工具箱在宽屏三列、窄屏单列，切换主题不破坏布局',async({page})=>{
  for(const width of [1920,1440,1040,760]){
    await page.setViewportSize({width,height:1000});await page.goto('toolbox');
    const cards=page.locator('.three-col > section');await expect(cards).toHaveCount(6);
    const points=await cards.evaluateAll(es=>es.slice(0,2).map(e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y}}));
    if(width>=1040)expect(Math.abs(points[0].y-points[1].y)).toBeLessThan(2);else expect(points[1].y).toBeGreaterThan(points[0].y);
    await page.getByRole('button',{name:'切换主题'}).click();await expect(page.locator('html')).toHaveAttribute('data-theme',/dark|light/);
  }
});
test('保存竞赛偏好使用服务端字段并更新回读',async({page})=>{
  let saved:Record<string,unknown>|undefined;
  await page.route('**/api/user/competition-preference',async route=>{
    if(route.request().method()==='PUT'){saved=route.request().postDataJSON();await route.fulfill({json:{message:'已保存'}})}
    else await route.fulfill({json:{goals:['ability'],preferred_roles:['developer'],direction_tags:['算法'],skill_tags:['TypeScript'],weekly_hours:5,experience_level:'beginner'}});
  });
  await page.goto('competition');await page.getByRole('button',{name:'偏好设置'}).click();
  await page.getByLabel('每周可投入小时').fill('8');await page.getByRole('button',{name:'保存',exact:true}).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(saved).toMatchObject({goals:['ability'],preferred_roles:['developer'],weekly_hours:8,direction_tags:['算法'],skill_tags:['TypeScript']});
});
