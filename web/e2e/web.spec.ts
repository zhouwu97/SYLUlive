import {test,expect} from '@playwright/test';
test('课表编辑、冲突校验和 URL 周次',async({page})=>{
 const errors:string[]=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('schedule');
 await page.getByRole('button',{name:'＋ 添加课程'}).click();
 await page.getByLabel('课程名称',{exact:true}).fill('本地测试课程');
 await page.getByLabel('地点',{exact:true}).fill('测试教室');
 await page.getByRole('button',{name:'保存',exact:true}).click();
 await expect(page.getByRole('button',{name:'本地测试课程 测试教室'})).toHaveCount(1);
 await page.getByRole('button',{name:'＋ 添加课程'}).click();
 await page.getByLabel('课程名称',{exact:true}).fill('冲突课程');
 await page.getByRole('button',{name:'保存',exact:true}).click();
 await expect(page.getByRole('alert')).toContainText('冲突');
 await page.getByRole('button',{name:'关闭',exact:true}).click();
 await page.getByRole('button',{name:'下一周'}).click();
 await expect(page).toHaveURL(/week=2/);
 await page.getByRole('button',{name:'本地测试课程 测试教室'}).first().click();
 await page.getByRole('button',{name:'删除本地课程'}).click();
 await expect(page.getByRole('button',{name:'本地测试课程 测试教室'})).toHaveCount(0);
 expect(errors).toEqual([]);
});
test('主要路由和移动端导航无运行时错误',async({page})=>{
 const errors:string[]=[];page.on('pageerror',e=>errors.push(e.message));
 for(const route of ['','community','market','schedule','grades','exams','campus','canteen','competition','ratings','polls','ai','toolbox','feedback','profile','notifications','admin','post/1']){await page.goto(route||'./');await expect(page.locator('#mainContent')).toBeVisible()}
 await page.setViewportSize({width:760,height:900});await page.goto('./');
 await page.getByRole('button',{name:'打开导航'}).click();await expect(page.getByRole('link',{name:'课表',exact:true})).toBeInViewport();
 await page.getByRole('link',{name:'课表',exact:true}).click();await expect(page).toHaveURL(/schedule/);
 expect(errors).toEqual([]);
});
