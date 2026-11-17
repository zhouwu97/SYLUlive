import {describe,it,expect} from 'vitest';
import {notificationTarget} from './notification-target';
describe('通知目标遵守类型、编号和角色',()=>{
  it('工单先于关联帖子解析，管理工单只给管理角色入口',()=>{
    expect(notificationTarget({type:'feedback_admin_update',related_id:9,post_id:12},'admin').to).toBe('/admin/feedback/9');
    expect(notificationTarget({type:'feedback_admin_update',related_id:9},'user').to).toBeUndefined();
    expect(notificationTarget({type:'feedback_update',related_id:'9'},'user').to).toBe('/feedback/9');
  });
  it('缺失或恶意编号不产生坏链接',()=>{
    for(const related_id of [undefined,0,-1,'../admin','undefined','9/x',NaN])expect(notificationTarget({type:'feedback_update',related_id},'user').to).toBeUndefined();
  });
  it('专用审核类型不被旧 post_id 覆盖',()=>{
    expect(notificationTarget({type:'course_evaluation_result',post_id:12}).to).toBe('/profile?tab=evaluations');
    expect(notificationTarget({type:'reply',post_id:12}).to).toBe('/post/12');
    expect(notificationTarget({type:'system'}).to).toBeUndefined();
  });
});
