import {test,expect} from '@playwright/test';

test('贡献列表按真实接口结构展示一次，并保留审核原因和合并结果',async({page})=>{
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'测试用户',role:'user'}}));
  await page.route('**/api/user/canteen-contributions',route=>route.fulfill({json:{items:[
    {type:'dish',dish_id:12,dish_name:'测试菜品',canteen_id:1,canteen_name:'测试食堂',status:'rejected',reject_reason:'请补充菜品信息'},
    {type:'dish_review',dish_id:13,dish_name:'合并前菜名',canteen_id:1,status:'merged',merged_into_dish_name:'合并后的菜品'}
  ]}}));
  await page.goto('canteen');
  await page.getByRole('tab',{name:'我的贡献',exact:true}).click();
  const dialog=page.locator('#mainContent');
  await expect(dialog.getByText('测试菜品',{exact:true})).toHaveCount(1);
  await expect(dialog.getByText('请补充菜品信息',{exact:true})).toBeVisible();
  await expect(dialog.getByText('已合并至：合并后的菜品',{exact:true})).toBeVisible();
  await expect(dialog.getByRole('link',{name:'查看食堂'})).toHaveCount(2);
});

test('校园地图使用 App 资源，支持放大和复位',async({page})=>{
  await page.goto('campus');
  await page.getByRole('button',{name:'校园地图',exact:true}).click();
  const map=page.getByRole('dialog').getByRole('img',{name:'沈阳理工大学校园地图'});
  await expect(map).toBeVisible();
  await expect.poll(()=>map.evaluate((img:HTMLImageElement)=>img.naturalWidth)).toBeGreaterThan(0);
  await page.getByRole('button',{name:'放大',exact:true}).click();
  await expect(map).toHaveAttribute('style','width: 150%;');
  await page.getByRole('button',{name:'复位地图',exact:true}).click();
  await expect(map).toHaveAttribute('style','width: 100%;');
});

test('编辑评价先读取权威上下文，保存保留菜品与实拍',async({page})=>{
  let saved:Record<string,any>|undefined;
  const review={id:9,user_id:991,comment:'原评价',taste_score:4,value_score:4,queue_score:4,hygiene_score:4,service_score:4};
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'测试用户',role:'user'}}));
  await page.route('**/api/canteens/1',route=>route.fulfill({json:{canteen:{id:1,name:'测试食堂'}}}));
  await page.route('**/api/canteens/1/dishes',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/canteens/1/reviews',route=>route.fulfill({json:{items:[review]}}));
  await page.route('**/api/canteens/reviews/9/edit-context',route=>route.fulfill({json:{review:{...review,
    images:'["/uploads/old.jpg"]',tags:'["午餐"]',updated_at:'2026-09-20T10:00:00Z',
    recommended_dish_details:[{dish_id:7,name:'已有菜品'}],dish_photos:[{dish_id:7,file_id:81}],dish_reviews:[]}}}));
  await page.route('**/api/canteens/reviews/9',async route=>{saved=route.request().postDataJSON();await route.fulfill({json:{message:'已保存'}})});
  await page.goto('canteen/1');
  await page.getByRole('button',{name:'编辑',exact:true}).click();
  await page.getByLabel('就餐体验（不超过 500 字）').fill('修改文字');
  await page.getByRole('button',{name:'保存',exact:true}).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(saved).toMatchObject({comment:'修改文字',images:['/uploads/old.jpg'],tags:['午餐'],
    base_updated_at:'2026-09-20T10:00:00Z',dishes:[{dish_id:7,photo_file_ids:[81]}]});
});
