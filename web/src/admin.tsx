import {useSearchParams} from 'react-router-dom';
import {useAuth} from './auth';
import {rows,useApi,write,time,entity,type Entity} from './api';
import {Empty,Form,Head,QueryState,Tabs,useUI,type Field} from './ui';
import {Feedback} from './feedback';
import {paperFields} from './papers';
import {Management,managementTabs} from './management';
const queues:Record<string,[string,string]>={
  reports:['举报处理','/api/reports'],papers:['试卷审核','/api/admin/exam-papers'],
  awards:['获奖核验','/api/admin/competition-awards/verifications'],
  canteens:['食堂审核','/api/canteens/pending'],teachers:['教师审核','/api/teachers/pending'],
};
export function Admin(){
  const auth=useAuth(); const [params,setParams]=useSearchParams();const tab=params.get('tab')||'feedback';
  if(!auth.user)return <Empty title="登录后访问管理中心"><button className="btn primary" onClick={auth.login}>登录</button></Empty>;
  if(!['admin','super_admin'].includes(auth.user.role))return <Empty title="当前账号没有管理权限"/>;
  const tabs:[string,string][]=[["feedback","工单"],...Object.entries(queues).filter(([id])=>id!=='awards'||auth.user?.role==='super_admin').map(([id,[name]])=>[id,name] as [string,string]),...managementTabs.filter(([id])=>!['users','releases','logs'].includes(id)||auth.user?.role==='super_admin')];
  return <><Head title="管理中心" description="审核结果和权限以服务器响应为准"/><Tabs value={tab} tabs={tabs} onChange={tab=>setParams({tab})}/>{tab==='feedback'?<Feedback admin/>:queues[tab]?<Queue kind={tab}/>:managementTabs.some(([id])=>id===tab)?<Management kind={tab}/>:<Empty title="管理模块不存在"/>}</>;
}
function Queue({kind}:{kind:string}){
  const meta=queues[kind],ui=useUI();const q=useApi(meta[1]); const list=rows(q.data,'reports','verifications','canteens','teachers');
  return <QueryState query={q}><div className="panel">{list.map(x=><div className="list-row" key={x.id}><div className="list-main"><b>{x.title||x.name||x.award_name||`#${x.id}`}</b><p>{x.reason||x.description||x.comment||x.status}</p><small>{time(x.created_at)}</small></div><button className="btn" onClick={()=>ui.open(meta[0],<Review kind={kind} item={x}/>)}>处理</button></div>)}{!list.length&&<Empty title="当前队列为空"/>}</div></QueryState>;
}
function Review({kind,item}:{kind:string;item:Entity}){
  const ui=useUI();
  const path=kind==='papers'?`/api/admin/exam-papers/${item.id}`:kind==='awards'?`/api/admin/competition-awards/verifications/${item.id}`:null;
  const q=useApi(path);
  if(path)return <QueryState query={q}><ReviewForm kind={kind} item={entity(q.data,'award','paper','data')}/></QueryState>;
  return <ReviewForm kind={kind} item={item}/>;
}
function ReviewForm({kind,item}:{kind:string;item:Entity}){
  const ui=useUI();
  const fields:Field[]=[...(kind==='papers'?paperFields(item):[]),
    {name:'decision',label:'处理决定',options:kind==='reports'?[['ignored','忽略举报'],['handled','确认违规并警告']]:[['approve','通过'],['reject','驳回']]},
    {name:'reason',label:'处理说明',type:'textarea',required:true}];
  return <><p className="details-text">{item.title||item.name||item.competition_title} · {item.reason||item.description||item.award_name}</p>
    {kind==='papers'&&<a className="btn" href={`/api/exam-papers/${item.id}/preview`} target="_blank" rel="noreferrer">授权预览试卷</a>}
    {kind==='awards'&&(item.evidence_file_ids||[]).map((fileId:number)=><a className="btn" key={fileId} href={`/api/admin/competition-awards/verifications/${item.id}/evidence/${fileId}`} target="_blank" rel="noreferrer">核验材料 #{fileId}</a>)}
    <Form fields={fields} onSubmit={async data=>{
      let path='',body:Entity={reason:data.reason},method='POST';
      if(kind==='reports'){path=`/api/reports/${item.id}/handle`;method='PUT';body={status:data.decision,action:data.decision==='handled'?'warn':'',result:data.reason};}
      else if(kind==='papers'){path=`/api/admin/exam-papers/${item.id}/${data.decision}`;body={reason:data.reason,course_name:data.course_name,academic_year:data.academic_year,semester:data.semester,exam_type:data.exam_type};}
      else if(kind==='awards')path=`/api/admin/competition-awards/verifications/${item.id}/${data.decision}`;
      else if(kind==='canteens'){path=`/api/canteens/${item.id}/${data.decision==='approve'?'approve':'pending'}`;method=data.decision==='approve'?'POST':'DELETE';}
      else if(kind==='teachers'){path=`/api/teachers/${item.id}/${data.decision==='approve'?'verify':'reject'}`;method=data.decision==='approve'?'PUT':'DELETE';}
      await write(path,body,method);await ui.act(async()=>{},'处理结果已保存');ui.close();
    }}/>
  </>;
}
