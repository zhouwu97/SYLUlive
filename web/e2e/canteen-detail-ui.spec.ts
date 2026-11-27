import {test,expect,type Page} from '@playwright/test';

const image='<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="750"><rect width="1000" height="750" fill="#efddc3"/><rect x="100" y="100" width="800" height="210" rx="20" fill="#b7593d"/><text x="500" y="225" font-size="70" text-anchor="middle" fill="white">CAMPUS KITCHEN</text><rect x="100" y="340" width="800" height="300" fill="#9ca68a"/></svg>';
const shop={id:34,name:'川渝椒香',image:'/uploads/store.jpg',location_area:'一食堂',location_floor:'二楼'};
const review={id:1,user_id:8,user_name:'用餐同学',comment:'味道不错，分量也很足。',overall_score:4.8,taste_score:5,value_score:5,queue_score:4,hygiene_score:5,service_score:5,images:['/uploads/review.jpg'],created_at:'2026-11-01T10:00:00Z'};

async function setup(page:Page){
  await page.route('**/api/**',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'验收同学',role:'user'}}));
  await page.route('**/uploads/**',route=>route.fulfill({contentType:'image/svg+xml',body:image}));
  await page.route('**/api/canteens/34',route=>route.fulfill({json:{canteen:shop,reviewer_count:9,visit_review_count:14,average_star:4.8,dimension_scores:{taste:5,value:4.8,queue:4.8,hygiene:5,service:5}}}));
  await page.route('**/api/canteens/34/dishes',route=>route.fulfill({json:[{id:7,name:'辣椒炒肉',cover_image:'/uploads/dish.jpg',photo_count:3,average_score:4.7}]}));
  await page.route('**/api/canteens/34/reviews',route=>route.fulfill({json:{items:[review]}}));
}

for(const profile of [{name:'desktop',width:1440,dark:false},{name:'mobile',width:390,dark:false},{name:'tablet',width:900,dark:false},{name:'dark',width:1440,dark:true}]){
  test(`食堂详情 ${profile.name} 显示完整概览，图片不撑宽，预览可打开`,async({page},testInfo)=>{
    await setup(page);
    await page.setViewportSize({width:profile.width,height:1000});
    if(profile.dark)await page.addInitScript(()=>localStorage.setItem('sylulive-theme','dark'));
    await page.goto('canteen/34');
    if(profile.dark)await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
    await expect(page.getByRole('heading',{name:'川渝椒香',exact:true})).toHaveCount(1);
    await expect(page.getByLabel('店铺概览')).toContainText('9 人评分 · 14 条就餐评价');
    await expect(page.getByLabel('分项评分')).toContainText('性价比');
    const cover=page.locator('.canteen-detail-cover img');
    await expect.poll(()=>cover.evaluate((el:HTMLImageElement)=>el.naturalWidth)).toBeGreaterThan(0);
    const coverBox=(await cover.boundingBox())!;
    expect(coverBox.width).toBeGreaterThan(200);
    expect(coverBox.height).toBeLessThan(500);
    const photo=page.locator('.canteen-review-media img');
    const photoBox=(await photo.boundingBox())!;
    expect(photoBox.width).toBeLessThanOrEqual(301);
    expect(photoBox.height).toBeLessThanOrEqual(211);
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    await page.screenshot({path:testInfo.outputPath(`canteen-detail-${profile.name}.png`),fullPage:true});
    await page.getByRole('button',{name:'用餐同学的就餐实拍第 1 张',exact:true}).click();
    await expect(page.getByRole('dialog')).toBeVisible();
    await expect(page.getByRole('link',{name:'打开原图'})).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('dialog')).toHaveCount(0);
  });
}

test('食堂详情错误重试，缺图、无评分和空评价保留可理解的状态',async({page})=>{
  await setup(page);
  let broken=true;
  await page.route('**/api/canteens/34',route=>route.fulfill(broken?{status:500,json:{error:'店铺信息暂时不可用'}}:{json:{canteen:{...shop,image:''},rating_count:0,average_star:0}}));
  await page.route('**/api/canteens/34/reviews',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/canteens/34/dishes',route=>route.fulfill({json:[]}));
  await page.goto('canteen/34');
  await expect(page.getByText('店铺信息暂时不可用',{exact:true})).toBeVisible();
  broken=false;
  await page.locator('#mainContent').getByRole('button',{name:'重试',exact:true}).click();
  await expect(page.getByText('暂无店铺封面',{exact:true})).toBeVisible();
  await expect(page.getByText('暂时还没有评分',{exact:true})).toBeVisible();
  await expect(page.getByRole('heading',{name:'还没有就餐评价'})).toBeVisible();
  await expect(page.getByRole('heading',{name:'还没有菜品实拍'})).toBeVisible();
});

test('封面加载失败可以点击重试，不留空白占位',async({page})=>{
  await setup(page);
  let broken=true;
  await page.route('**/uploads/store.jpg',route=>route.fulfill(broken?{status:404,body:''}:{contentType:'image/svg+xml',body:image}));
  await page.goto('canteen/34');
  await expect(page.locator('.canteen-detail-cover').getByText('图片加载失败 · 点击重试',{exact:true})).toBeVisible();
  broken=false;
  await page.locator('.canteen-detail-cover .media-tile').click();
  await expect.poll(()=>page.locator('.canteen-detail-cover img').evaluate((el:HTMLImageElement)=>el.naturalWidth)).toBeGreaterThan(0);
});

test('评价下一页失败保留已读内容，重试可继续读取',async({page})=>{
  await setup(page);
  let broken=true;
  await page.route('**/api/canteens/34/reviews**',route=>{
    if(!new URL(route.request().url()).searchParams.has('cursor'))return route.fulfill({json:{items:[review],next_cursor:'next'}});
    return route.fulfill(broken?{status:503,json:{error:'下一页暂不可用'}}:{json:{items:[{...review,id:2,comment:'第二页的就餐评价'}]}});
  });
  await page.goto('canteen/34');
  await page.getByRole('button',{name:'加载更多评价',exact:true}).click();
  await expect(page.getByRole('alert')).toHaveText('下一页暂不可用');
  await expect(page.getByText(review.comment,{exact:true})).toBeVisible();
  broken=false;
  await page.getByRole('button',{name:'重试加载更多',exact:true}).click();
  await expect(page.getByText('第二页的就餐评价',{exact:true})).toBeVisible();
  await expect(page.locator('.canteen-review-card')).toHaveCount(2);
});

test('切换店铺后晚到的评价分页不能混入新店',async({page})=>{
  await setup(page);
  let release!:()=>void,reads=0;
  const pending=new Promise<void>(resolve=>{release=resolve});
  await page.route('**/api/canteens/34/reviews',route=>route.fulfill({json:{items:[review],next_cursor:'old'}}));
  await page.route('**/api/canteens/34/reviews?**',async route=>{reads++;await pending;await route.fulfill({json:{items:[{...review,id:2,comment:'不属于新店的旧分页'}]}})});
  await page.route('**/api/canteens/home',route=>route.fulfill({json:{hero:{canteen_id:35,canteen_name:'另一个食堂'},ranking_entry:{total:1},hot_dishes:[],feed:[]}}));
  await page.route('**/api/canteens/35',route=>route.fulfill({json:{canteen:{id:35,name:'另一个食堂'}}}));
  await page.route('**/api/canteens/35/dishes',route=>route.fulfill({json:[]}));
  await page.route('**/api/canteens/35/reviews',route=>route.fulfill({json:{items:[{...review,id:3,comment:'当前食堂的评价'}]}}));
  await page.goto('canteen/34');
  await page.getByRole('button',{name:'加载更多评价',exact:true}).click();
  await expect.poll(()=>reads).toBe(1);
  await page.getByRole('link',{name:'返回列表',exact:true}).click();
  await page.getByRole('link',{name:'查看店铺与点评',exact:true}).click();
  release();
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('当前食堂的评价',{exact:true})).toBeVisible();
  await expect(page.getByText('不属于新店的旧分页',{exact:true})).toHaveCount(0);
});
