import type {Entity} from './api';

const positiveID=(value:unknown)=>typeof value==='number'&&Number.isSafeInteger(value)&&value>0?value:typeof value==='string'&&/^[1-9]\d*$/.test(value)&&Number.isSafeInteger(Number(value))?Number(value):0;
export function notificationTarget(n:Entity,role?:string):{to?:string;label:string;kind:string;icon:string}{
  const type=String(n.type||''),related=positiveID(n.related_id),post=positiveID(n.post_id);
  if(type.startsWith('feedback')){
    const admin=type==='feedback_admin_update';
    return {to:related&&(!admin||role==='admin'||role==='super_admin')?`${admin?'/admin':''}/feedback/${related}`:undefined,label:'查看工单',kind:admin?'工单待处理':'工单进展',icon:'feedback'};
  }
  if(type==='course_evaluation_result')return {to:'/profile?tab=evaluations',label:'查看审核结果',kind:'评价审核',icon:'ratings'};
  if(type==='canteen_pending'||type==='canteen_review_result')return {to:'/canteen?tab=mine',label:'查看我的贡献',kind:'食堂审核',icon:'canteen'};
  if(type==='competition_award_verification')return {to:'/competition?tab=awards',label:'查看认证结果',kind:'获奖认证',icon:'competition'};
  if(type==='lottery_won')return {to:'/toolbox',label:'查看抽奖结果',kind:'中奖通知',icon:'competition'};
  if(post)return {to:`/post/${post}`,label:'查看帖子',kind:type==='reply'?'评论回复':'社区动态',icon:'community'};
  return {label:'查看详情',kind:'系统通知',icon:'bell'};
}
