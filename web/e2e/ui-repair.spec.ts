import {test,expect,type Page} from '@playwright/test';

test.use({reducedMotion:'reduce'});

const tall='<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="2400"><rect width="1800" height="2400" fill="#d7b481"/><circle cx="900" cy="1200" r="700" fill="#f7efe0"/><text x="900" y="1200" text-anchor="middle" font-size="160" fill="#9c482c">CAMPUS FOOD</text></svg>';
const shop={id:34,name:'川渝椒香',image:'/uploads/store.jpg',location_area:'一食堂',location_floor:'二楼',rating_count:10,average_star:4.8};
async function setup(page:Page,role='admin'){
  await page.route('**/api/**',route=>route.fulfill({json:{items:[]}}));
  await page.route('**/api/user/profile',route=>route.fulfill({json:{id:991,nickname:'验收同学',role}}));
  await page.route('**/uploads/**',route=>route.fulfill({contentType:'image/svg+xml',body:tall}));
  await page.route('**/api/canteens/34',route=>route.fulfill({json:{canteen:shop,...shop}}));
  await page.route('**/api/canteens/34/reviews',route=>route.fulfill({json:{items:[{id:1,user_id:8,user_name:'用餐同学',comment:'味道不错',images:['/uploads/review.jpg']}]}}));
  await page.route('**/api/canteens/34/dishes',route=>route.fulfill({json:[]}));
}

for(const width of [1440,390])test(`竖图预览适应窗口，没有横向滚动与单图切换按钮 ${width}`,async({page},info)=>{
  await setup(page);await page.setViewportSize({width,height:900});await page.goto('canteen/34');
  await page.getByRole('button',{name:'用餐同学的就餐实拍第 1 张',exact:true}).click();
  const dialog=page.getByRole('dialog');
  await expect.poll(()=>dialog.locator('.media-lightbox-stage img').evaluate((el:HTMLImageElement)=>el.naturalWidth)).toBeGreaterThan(0);
  expect(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
  expect(await dialog.locator('.modal-body').evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
  await expect(dialog.getByRole('button',{name:'上一张',exact:true})).toHaveCount(0);
  await expect(dialog.getByRole('button',{name:'放大',exact:true})).toBeVisible();
  await page.screenshot({path:info.outputPath(`image-viewer-${width}.png`)});
  await dialog.getByRole('button',{name:'放大',exact:true}).click();
  await dialog.getByRole('button',{name:'适应窗口',exact:true}).click();
  await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);
});

test('营业店铺管理员有下架与删除入口',async({page})=>{
  await setup(page);await page.goto('canteen/34');
  await expect(page.getByRole('button',{name:'管理店铺',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'管理店铺',exact:true}).click();
  await expect(page.getByRole('button',{name:'下架店铺',exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'永久删除店铺',exact:true})).toBeVisible();
});

test('通知打开目标不等待已读请求',async({page})=>{
  await setup(page);
  await page.route('**/api/user/notifications',route=>route.fulfill({json:{notifications:[{id:9,type:'feedback_admin_update',related_id:9,content:'收到新的用户工单：二课查询不了',is_read:false}]}}));
  await page.route('**/api/user/notifications/read-selected',async route=>{await new Promise(r=>setTimeout(r,2000));await route.fulfill({status:503,json:{error:'已读同步暂不可用'}})});
  await page.goto('notifications');await page.getByRole('button',{name:/收到新的用户工单/}).click();
  await expect(page).toHaveURL(/admin\/feedback\/9/,{timeout:1000});
});

for(const role of ['user','admin','super_admin'])for(const offline of [false,true])test(`店铺管理权限 ${role} ${offline?'下架':'营业'}`,async({page})=>{
  await setup(page,role);
  await page.route('**/api/canteens/34',route=>route.fulfill({json:{canteen:{...shop,is_offline:offline}}}));
  await page.goto('canteen/34');
  await expect(page.getByRole('heading',{name:shop.name,exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'管理店铺',exact:true})).toHaveCount(role==='super_admin'||role==='admin'&&!offline?1:0);
});

test('下架失败保留原因，重试后只读且能进入怀旧食堂',async({page})=>{
  await setup(page,'super_admin');let offline=false,attempts=0;
  await page.route('**/api/canteens/34',route=>route.fulfill({json:{canteen:{...shop,is_offline:offline,offline_reason:offline?'商家已搬走':''}}}));
  await page.route('**/api/canteens/34/offline',route=>{
    attempts++;expect(route.request().postDataJSON()).toEqual({reason:'商家已搬走'});
    if(attempts===1)return route.fulfill({status:403,json:{error:'管理权限已变化，请重新确认'}});
    offline=true;return route.fulfill({json:{canteen:{...shop,is_offline:true}}});
  });
  await page.goto('canteen/34');await page.getByRole('button',{name:'管理店铺',exact:true}).click();
  await page.getByRole('button',{name:'下架店铺',exact:true}).click();
  const dialog=page.getByRole('dialog');await dialog.getByLabel('下架原因',{exact:true}).fill('商家已搬走');
  await dialog.getByRole('button',{name:'确认下架',exact:true}).click();
  await expect(dialog.getByRole('alert')).toHaveText('管理权限已变化，请重新确认');
  await expect(dialog.getByLabel('下架原因',{exact:true})).toHaveValue('商家已搬走');
  await dialog.getByRole('button',{name:'确认下架',exact:true}).click();await expect(dialog).toHaveCount(0);
  await expect(page.getByText('怀旧存档 · 已下架',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'发表评价',exact:true})).toHaveCount(0);
  await expect(page.getByRole('link',{name:'返回列表',exact:true})).toHaveAttribute('href','/web/canteen?tab=nostalgia');
  await page.getByRole('button',{name:'管理店铺',exact:true}).click();await expect(page.getByRole('button',{name:'恢复营业',exact:true})).toBeVisible();
});

test('永久删除须核对名称，失败可恢复，成功离开详情',async({page})=>{
  await setup(page);let writes=0;
  await page.route('**/api/canteens/34',route=>{
    if(route.request().method()!=='DELETE')return route.fulfill({json:{canteen:shop}});
    writes++;return route.fulfill(writes===1?{status:503,json:{error:'删除暂不可用'}}:{json:{message:'已删除'}});
  });
  await page.goto('canteen/34');await page.getByRole('button',{name:'管理店铺',exact:true}).click();
  await page.getByRole('button',{name:'永久删除店铺',exact:true}).click();
  const dialog=page.getByRole('dialog'),name=dialog.getByRole('textbox');
  await name.fill('写错的名称');await dialog.getByRole('button',{name:'确认永久删除',exact:true}).click();
  await expect(dialog.getByRole('alert')).toContainText('店铺名称不一致');expect(writes).toBe(0);
  await name.fill(shop.name);await dialog.getByRole('button',{name:'确认永久删除',exact:true}).click();
  await expect(dialog.getByRole('alert')).toHaveText('删除暂不可用');await expect(name).toHaveValue(shop.name);
  await dialog.getByRole('button',{name:'确认永久删除',exact:true}).click();await expect(page).toHaveURL(/canteen\?tab=stores/);
  expect(writes).toBe(2);
});

test('多图支持键盘切换、缩放复位和失败重试',async({page})=>{
  await setup(page);let broken=true;
  await page.route('**/api/canteens/34/reviews',route=>route.fulfill({json:{items:[{id:1,user_name:'用餐同学',images:['/uploads/review.jpg','/uploads/broken.jpg']}]}}));
  await page.route('**/uploads/broken.jpg',route=>route.fulfill(broken?{status:404,body:''}:{contentType:'image/svg+xml',body:tall}));
  await page.goto('canteen/34');const trigger=page.getByRole('button',{name:'用餐同学的就餐实拍第 1 张',exact:true});await trigger.click();
  const dialog=page.getByRole('dialog');await dialog.getByRole('button',{name:'放大',exact:true}).click();
  await expect(dialog.getByLabel('缩放比例')).toHaveText('150%');await page.keyboard.press('ArrowRight');
  await expect(dialog.getByRole('alert')).toContainText('图片加载失败');await expect(dialog.getByLabel('缩放比例')).toHaveText('100%');
  broken=false;await dialog.getByRole('button',{name:'重新加载',exact:true}).click();
  await expect.poll(()=>dialog.locator('.media-lightbox-stage img').evaluate((el:HTMLImageElement)=>el.naturalWidth)).toBeGreaterThan(0);
  await page.keyboard.press('ArrowLeft');await expect(dialog.locator('.media-lightbox-count')).toHaveText('1 / 2');
  await page.keyboard.press('Escape');await expect(trigger).toBeFocused();
});

for(const width of [1440,390])for(const dark of [false,true])test(`店铺、排行、通知与工单真实渲染 ${width} ${dark?'深色':'浅色'}`,async({page},info)=>{
  await setup(page);await page.setViewportSize({width,height:1000});
  if(dark)await page.addInitScript(()=>localStorage.setItem('sylulive-theme','dark'));
  const items=[shop,{...shop,id:35,name:'秀香园美食',average_star:4.7,dish_count:3},{...shop,id:36,name:'杂粮煎饼 · 煎饼果子',average_star:4.6},{...shop,id:37,name:'我家有面',image:'',average_star:4.4},{id:38,name:'新开的店铺',rating_count:0}];
  await page.route('**/api/canteens?**',route=>route.fulfill({json:items}));
  await page.route('**/api/canteens/rankings**',route=>route.fulfill({json:{items:items.map((item,i)=>({...item,rank:i+1,ranked:item.rating_count>0}))}}));
  await page.goto('canteen?tab=stores');await expect(page.locator('.canteen-store-card')).toHaveCount(5);
  await page.screenshot({path:info.outputPath('stores.png'),fullPage:true});
  await page.getByRole('tab',{name:'食堂排行',exact:true}).click();
  await expect(page.locator('.canteen-podium-card')).toHaveCount(3);await expect(page.getByLabel('暂无评价，不参与排名')).toHaveText('—');
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.screenshot({path:info.outputPath('ranking.png'),fullPage:true});
  await page.getByRole('combobox').selectOption('rating');await expect(page.locator('.canteen-podium-card')).toHaveCount(0);
  await page.route('**/api/user/notifications',route=>route.fulfill({json:{notifications:[{id:9,type:'feedback_admin_update',related_id:9,content:'收到新的用户工单：二课查询不了',is_read:false,created_at:'2026-11-16T05:03:53Z'},{id:10,type:'reply',post_id:12,content:'同学回复了你的评论：这个方法很有帮助。',is_read:true,created_at:'2026-11-15T13:01:07Z'}]}}));
  await page.goto('notifications');await expect(page.locator('.notification-row')).toHaveCount(2);await page.screenshot({path:info.outputPath('notifications.png'),fullPage:true});
  await page.route('**/api/admin/feedback/tickets/9',route=>route.fulfill({json:{ticket:{id:9,ticket_no:'SY2611168564',title:'二课查询不了',description:'更新二课查询的时候出现异常，附上截图供排查。',status:'pending',type:'bug',priority:'P2',user_id:28,user:{nickname:'提交同学'},app_version:'1.7.6',build_number:'1711',device_model:'Android Device',os_version:'Android 11',created_at:'2026-11-16T05:03:53Z'},initial_submission:{attachments:[{file_id:99}]},messages:[{id:1,sender_type:'admin',content:'已收到，我们正在排查。',visible_to_user:true}],history:[{id:1,new_status:'pending',note:'工单已提交'}]}}));
  await page.route('**/api/feedback/attachments/99',route=>route.fulfill({contentType:'image/svg+xml',body:tall}));
  await page.goto('admin/feedback/9');await expect(page.getByRole('heading',{name:'沟通记录',exact:true})).toBeVisible();
  await page.locator('.reply-form select[name=scope]').selectOption('internal');await expect(page.locator('.ticket-reply-head')).toContainText('仅管理员可见');
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.screenshot({path:info.outputPath('ticket.png'),fullPage:true});
});

test('已读通知不重复写回执，无目标通知立即展示全文',async({page})=>{
  await setup(page);let writes=0;
  await page.route('**/api/user/notifications',route=>route.fulfill({json:{notifications:[{id:9,type:'system',content:'校园服务维护时间说明',is_read:true}]}}));
  await page.route('**/api/user/notifications/read-selected',route=>{writes++;return route.fulfill({json:{}})});
  await page.goto('notifications');await page.getByRole('button',{name:/校园服务维护时间说明/}).click();
  await expect(page.getByRole('dialog')).toContainText('校园服务维护时间说明');expect(writes).toBe(0);
});

test('工单回复失败保留内容和附件，重试后清空；状态冲突可恢复',async({page})=>{
  await setup(page);let attempts=0,statusAttempts=0,status='accepted',messages:unknown[]=[];
  const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64');
  await page.route('**/api/admin/feedback/tickets/9',route=>route.fulfill({json:{ticket:{id:9,title:'待排查的工单',status,description:'请协助排查'},messages,history:[]}}));
  await page.route('**/api/upload_multiple',route=>route.fulfill({json:{results:[{file_id:99}]}}));
  await page.route('**/api/admin/feedback/tickets/9/messages',route=>{
    const body=route.request().postDataJSON();attempts++;expect(body).toMatchObject({content:'排查中的内部说明',visible_to_user:false,image_ids:[99]});
    if(attempts===1)return route.fulfill({status:503,json:{error:'发送暂不可用'}});
    messages=[{id:1,sender_type:'admin',message_type:'internal_note',content:body.content,visible_to_user:false}];return route.fulfill({json:{}});
  });
  await page.route('**/api/admin/feedback/tickets/9/status',route=>{
    statusAttempts++;if(statusAttempts===1)return route.fulfill({status:409,json:{error:'状态已变化，请核对'}});
    status=route.request().postDataJSON().status;return route.fulfill({json:{}});
  });
  await page.goto('admin/feedback/9');const reply=page.locator('.reply-form');
  await reply.getByLabel('回复方式').selectOption('internal');await reply.getByLabel('回复内容').fill('排查中的内部说明');
  await reply.locator('input[type=file]').setInputFiles({name:'evidence.png',mimeType:'image/png',buffer:png});
  await expect(reply.locator('.media-upload-item')).toHaveCount(1);
  await reply.getByRole('button',{name:'发送',exact:true}).click();await expect(reply.getByRole('alert')).toHaveText('发送暂不可用');
  await expect(reply.getByLabel('回复内容')).toHaveValue('排查中的内部说明');await expect(reply.locator('.media-upload-item')).toHaveCount(1);
  await reply.getByRole('button',{name:'发送',exact:true}).click();await expect(page.locator('.thread')).toContainText('排查中的内部说明');
  await expect(reply.getByLabel('回复内容')).toHaveValue('');await expect(reply.locator('.media-upload-item')).toHaveCount(0);
  const aside=page.locator('.ticket-progress-panel');await aside.getByLabel('处理状态').selectOption('fixing');await aside.getByRole('button',{name:'更新状态',exact:true}).click();
  await expect(aside.getByRole('alert')).toHaveText('状态已变化，请核对');await expect(aside.getByLabel('处理状态')).toHaveValue('fixing');
  await aside.getByRole('button',{name:'更新状态',exact:true}).click();await expect(aside.locator('.ticket-status')).toHaveText('修复中');
});

test('超级管理员恢复营业后重新提供评价入口',async({page})=>{
  await setup(page,'super_admin');let offline=true,writes=0;
  await page.route('**/api/canteens/34',route=>route.fulfill({json:{canteen:{...shop,is_offline:offline}}}));
  await page.route('**/api/canteens/34/online',route=>{writes++;offline=false;return route.fulfill({json:{}})});
  await page.goto('canteen/34');await page.getByRole('button',{name:'管理店铺',exact:true}).click();
  await page.getByRole('button',{name:'恢复营业',exact:true}).click();await page.getByRole('button',{name:'确认恢复营业',exact:true}).click();
  await expect(page.getByRole('button',{name:'发表评价',exact:true})).toBeVisible();expect(writes).toBe(1);
});

test('店铺列表保留加载、失败重试、空态和搜索恢复',async({page})=>{
  await setup(page);let phase='loading',release!:()=>void;
  const pending=new Promise<void>(resolve=>{release=resolve});
  await page.route('**/api/canteens?**',async route=>{
    if(phase==='loading')await pending;
    return route.fulfill(phase==='error'?{status:503,json:{error:'店铺加载暂不可用'}}:{json:phase==='empty'?[]:[shop]});
  });
  await page.goto('canteen?tab=stores');await expect(page.locator('#mainContent').getByText('正在加载…',{exact:true})).toBeVisible();
  phase='error';release();await expect(page.getByText('店铺加载暂不可用',{exact:true})).toBeVisible();
  phase='empty';await page.locator('#mainContent').getByRole('button',{name:'重试',exact:true}).click();await expect(page.locator('#mainContent .empty-state')).toBeVisible();
  phase='items';await page.getByLabel('搜索食堂',{exact:true}).fill('椒香');await page.getByRole('button',{name:'搜索',exact:true}).click();
  await expect(page.locator('.canteen-store-card')).toHaveCount(1);await expect(page.getByLabel('搜索食堂',{exact:true})).toHaveValue('椒香');
});

test('通知全部已读失败可重试，不会误清未读',async({page})=>{
  await setup(page);let read=false,attempts=0;
  await page.route('**/api/user/notifications',route=>route.fulfill({json:{notifications:[{id:9,type:'system',content:'维护通知',is_read:read}]}}));
  await page.route('**/api/user/notifications/read',route=>{attempts++;if(attempts===1)return route.fulfill({status:503,json:{error:'已读同步暂不可用'}});read=true;return route.fulfill({json:{}})});
  await page.goto('notifications');await page.getByRole('button',{name:'全部已读',exact:true}).click();
  await expect(page.getByRole('status')).toContainText('已读同步暂不可用');await expect(page.locator('.notification-unread')).toHaveCount(1);
  await page.getByRole('button',{name:'全部已读',exact:true}).click();await expect(page.locator('.notification-unread')).toHaveCount(0);
  await page.getByRole('tab',{name:'未读',exact:true}).click();await expect(page.getByText('没有新的通知',{exact:true})).toBeVisible();
});

test('工单读取权限拒绝显示错误，恢复后可重试读取',async({page})=>{
  await setup(page);let denied=true;
  await page.route('**/api/admin/feedback/tickets/9',route=>route.fulfill(denied?{status:403,json:{error:'当前账号无权处理此工单'}}:{json:{ticket:{id:9,title:'可恢复的工单',status:'pending'},messages:[],history:[]}}));
  await page.goto('admin/feedback/9');await expect(page.getByText('当前账号无权处理此工单',{exact:true})).toBeVisible();await expect(page.getByRole('button',{name:'发送',exact:true})).toHaveCount(0);
  denied=false;await page.locator('#mainContent').getByRole('button',{name:'重试',exact:true}).click();await expect(page.getByRole('heading',{name:'可恢复的工单',exact:true})).toBeVisible();
});
