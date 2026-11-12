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

test('下架商家只读：不显示写评价、编辑和删除，并说明原因',async({page})=>{
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'测试用户',role:'user'}}));
  await page.route('**/api/canteens/2',route=>route.fulfill({json:{canteen:{id:2,name:'停业小炒',is_offline:true,operating_status:'offline',offline_reason:'商家已搬走'},is_favorite:false}}));
  await page.route('**/api/canteens/2/dishes',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/canteens/2/reviews',route=>route.fulfill({json:{items:[{id:5,user_id:991,user_name:'测试用户',comment:'以前常来',overall_score:4,created_at:'2026-10-01T04:00:00Z',updated_at:'2026-10-01T04:00:00Z'}]}}));
  await page.goto('canteen/2');
  await expect(page.getByText('以前常来')).toBeVisible();
  await expect(page.getByRole('button',{name:'发表评价',exact:true})).toHaveCount(0);
  await expect(page.getByRole('button',{name:'编辑',exact:true})).toHaveCount(0);
  await expect(page.getByRole('button',{name:'删除',exact:true})).toHaveCount(0);
  await expect(page.getByText('下架原因：商家已搬走')).toBeVisible();
});

test('收藏商家后在食堂主页“我常去”出现，评价支持加载更多',async({page})=>{
  let favorited=false;
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'测试用户',role:'user'}}));
  await page.route('**/api/canteens/3',route=>route.fulfill({json:{canteen:{id:3,name:'川渝椒香',location_area:'一食堂',location_floor:'二楼'},is_favorite:favorited}}));
  await page.route('**/api/canteens/3/dishes',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/canteens/3/reviews**',route=>{
    const more=route.request().url().includes('cursor=');
    return route.fulfill({json:more?{items:[{id:2,user_id:2,user_name:'乙',comment:'第二页评价',overall_score:4}]}:{items:[{id:1,user_id:1,user_name:'甲',comment:'第一页评价',overall_score:5}],next_cursor:'c1'}});
  });
  await page.route('**/api/user/canteen-favorites/3',async route=>{favorited=route.request().method()==='PUT';await route.fulfill({json:{favorited}})});
  await page.route('**/api/user/canteen-favorites',route=>route.fulfill({json:{items:favorited?[{id:3,name:'川渝椒香',rating_count:9,average_star:4.7}]:[]}}));
  await page.route('**/api/canteens/home',route=>route.fulfill({json:{hot_dishes:[],feed:[],recent_reviews:[],ranking_entry:{total:131,rated_total:63}}}));
  await page.goto('canteen/3');
  await page.getByRole('button',{name:'加载更多评价',exact:true}).click();
  await expect(page.getByText('第二页评价')).toBeVisible();
  await expect(page.getByRole('button',{name:'加载更多评价',exact:true})).toHaveCount(0);
  await page.getByRole('button',{name:'收藏',exact:true}).click();
  await expect(page.getByRole('button',{name:'已收藏',exact:true})).toHaveAttribute('aria-pressed','true');
  await page.goto('canteen');
  await expect(page.getByRole('heading',{name:'我常去'})).toBeVisible();
  await expect(page.getByRole('link',{name:/川渝椒香/}).first()).toBeVisible();
});

test('排行里没人评价的店显示“—”，可切换全部排名并标注已下架',async({page})=>{
  const seen:string[]=[];
  await page.route('**/api/canteens/rankings**',route=>{seen.push(route.request().url());return route.fulfill({json:{items:[
    {rank:1,ranked:true,id:1,name:'有评价店',rating_count:3,average_star:4.5},
    {rank:2,ranked:true,id:4,name:'旧店',rating_count:2,average_star:4.2,is_offline:true},
    {rank:3,ranked:false,id:2,name:'新开店',rating_count:0},
  ]}})});
  await page.goto('canteen?tab=ranking');
  await expect(page.getByLabel('暂无评价，不参与排名')).toHaveText('—');
  await expect(page.getByLabel('第1名')).toHaveText('1');
  await page.getByLabel('范围').selectOption('all');
  await expect.poll(()=>seen.some(url=>url.includes('scope=all'))).toBe(true);
  await expect(page.getByText('已下架',{exact:true})).toBeVisible();
});

test('我的贡献展示提交的商家',async({page})=>{
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'测试用户',role:'user'}}));
  await page.route('**/api/user/canteen-contributions',route=>route.fulfill({json:{items:[
    {type:'canteen',canteen_id:5,canteen_name:'新提交的面馆',status:'pending',submitted_at:'2026-11-10T04:00:00Z'},
    {type:'canteen',canteen_id:6,canteen_name:'被驳回的店',status:'rejected',reject_reason:'信息不完整'},
  ]}}));
  await page.goto('canteen?tab=mine');
  await expect(page.getByText('新提交的面馆',{exact:true})).toBeVisible();
  await expect(page.getByText('商家 · 待审核',{exact:true})).toBeVisible();
  await expect(page.getByText('信息不完整',{exact:true})).toBeVisible();
});
