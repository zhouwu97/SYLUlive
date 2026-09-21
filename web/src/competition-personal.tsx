import {useState} from 'react';
import {rows,useApi,write,type Entity} from './api';
import {Empty,Form,QueryState,Tabs,useUI,type Field} from './ui';
const plansPath='/api/user/competition-calendar';
const awardsPath='/api/user/competition-awards';
export function CompetitionPersonal(){
  const [tab,setTab]=useState('plans');
  return <><Tabs tabs={[["plans","个人计划"],["awards","获奖记录"]]} value={tab} onChange={setTab}/>{tab==='plans'?<Plans/>:<Awards/>}</>;
}
export function Plans(){
  const q=useApi(plansPath),ui=useUI();
  return <QueryState query={q}><button className="btn primary" onClick={()=>ui.open('新增竞赛计划',<PlanForm/>)}>新增计划</button>{rows(q.data).map(x=><div className="list-row" key={x.id}><div className="list-main"><b>{x.title}</b><p>{x.plan_status} · {x.user_deadline?.slice(0,10)||x.event_start?.slice(0,10)||'日期未确定'}</p><p>{x.note}</p></div><button className="btn" onClick={()=>ui.open('编辑竞赛计划',<PlanForm item={x}/>)}>编辑</button><button className="btn" onClick={()=>ui.open('删除计划',<><p>确认从个人日历删除“{x.title}”？</p><button className="btn" onClick={async()=>{if(await ui.act(()=>write(`${plansPath}/items/${x.id}`,{},'DELETE')))ui.close()}}>确认删除</button></>)}>删除</button></div>)}{!rows(q.data).length&&<Empty title="暂无个人计划"/>}</QueryState>;
}
function PlanForm({item={}}:{item?:Entity}){
  const categories=useApi('/api/competitions/categories'),ui=useUI();
  return <QueryState query={categories}><Form fields={[
    {name:'title',label:'比赛名称',required:true,value:item.title},
    {name:'primary_category_id',label:'主分类',required:true,value:item.primary_category_id,options:rows(categories.data,'categories').map(c=>[String(c.id),c.name])},
    {name:'plan_status',label:'计划状态',value:item.plan_status,options:[['watching','关注中'],['preparing','准备中'],['registered','已报名'],['submitted','已提交'],['finished','已完成'],['archived','已归档']]},
    {name:'user_deadline',label:'个人截止日期',type:'date',value:item.user_deadline?.slice(0,10)},
    {name:'event_start',label:'比赛开始',type:'date',value:item.event_start?.slice(0,10)},
    {name:'event_end',label:'比赛结束',type:'date',value:item.event_end?.slice(0,10)},
    {name:'note',label:'计划备注',type:'textarea',value:item.note},
  ]} onSubmit={async values=>{
    const base:Entity={...item,...values,primary_category_id:Number(values.primary_category_id)};
    for(const key of ['registration_start','registration_end','event_start','event_end','user_deadline'])base[key]=String(base[key]||'').slice(0,10);
    await write(`${plansPath}/items${item.id?`/${item.id}`:''}`,base,item.id?'PUT':'POST');
    await ui.act(async()=>{},'计划已保存');ui.close();
  }}/></QueryState>;
}
export function Awards(){const q=useApi(awardsPath),ui=useUI();return <QueryState query={q}><button className="btn primary" onClick={()=>ui.open('添加获奖记录',<AwardForm/>)}>添加记录与材料</button>{rows(q.data).map(x=><div className="list-row" key={x.id}><div className="list-main"><b>{x.competition_title} · {x.award_name}</b><p>{x.competition_year} · {x.verification_status}</p><p>{x.verification_note}</p><div className="form-actions">{(x.evidence_file_ids||[]).map((id:number)=><a key={id} className="link-btn" target="_blank" rel="noreferrer" href={`${awardsPath}/${x.id}/evidence/${id}`}>材料 #{id}</a>)}</div></div><button className="btn" onClick={()=>ui.open('编辑获奖记录',<AwardForm item={x}/>)}>编辑</button>{x.verification_status!=='verified'&&<button className="btn" onClick={()=>void ui.act(()=>write(`${awardsPath}/${x.id}/${x.verification_status==='pending'?'cancel':'submit'}-verification`),'核验状态已更新')}>{x.verification_status==='pending'?'撤回核验':'提交核验'}</button>}<button className="btn" onClick={()=>ui.open('删除获奖记录',<><p>确认删除此记录及其材料关联？</p><button className="btn" onClick={async()=>{if(await ui.act(()=>write(`${awardsPath}/${x.id}`,{},'DELETE')))ui.close()}}>确认删除</button></>)}>删除</button></div>)}{!rows(q.data).length&&<Empty title="暂无获奖记录"/>}</QueryState>}
function AwardForm({item={}}:{item?:Entity}){
  const ui=useUI();const locked=['pending','verified'].includes(item.verification_status);
  const visibility:Field={name:'visibility',label:'可见范围',value:item.visibility||'private',options:[['private','仅自己'],['profile','展示在主页'],['team_matching','用于组队匹配']]};
  const fields:Field[]=locked?[visibility]:[
    {name:'competition_title',label:'竞赛名称',required:true,value:item.competition_title},
    {name:'competition_year',label:'参赛年份',type:'number',required:true,value:item.competition_year||new Date().getFullYear()},
    {name:'award_name',label:'奖项名称',required:true,value:item.award_name},
    {name:'award_level',label:'奖项等级',value:item.award_level},
    {name:'competition_stage',label:'竞赛阶段',value:item.competition_stage,options:[['school','校级'],['provincial','省级'],['regional','区域'],['national','国家级'],['international','国际'],['other','其他']]},
    {name:'role',label:'担任角色',value:item.role,options:[['member','队员'],['leader','队长'],['developer','开发'],['modeler','建模'],['hardware','硬件'],['designer','设计'],['writer','写作'],['presenter','答辩'],['organizer','组织'],['other','其他']]},
    {name:'contribution_summary',label:'个人贡献',type:'textarea',value:item.contribution_summary},
    {name:'skill_tags',label:'技能（逗号分隔）',value:(item.skill_tags||[]).join(',')},
    {name:'files',label:'添加证明材料（每份不超过 10 MB）',type:'file',multiple:true},visibility,
  ];
  return <Form fields={fields} onSubmit={async(values,form)=>{
    const ids=[...(item.evidence_file_ids||[])];
    for(const file of form.getAll('files'))if(file instanceof File&&file.size){if(file.size>10*1024*1024)throw new Error('证明材料不能超过 10 MB');const body=new FormData();body.set('file',file);const result=await write(`${awardsPath}/evidence`,body);if(!Number.isInteger(result.evidence_file_id))throw new Error('材料上传未返回有效编号');ids.push(result.evidence_file_id);}
    const source={...item,...values};
    const body={competition_event_id:item.competition_event_id||null,competition_title:source.competition_title,track_name:item.track_name||'',competition_year:Number(source.competition_year),award_name:source.award_name,award_level:source.award_level||'',competition_stage:source.competition_stage,role:source.role,contribution_summary:source.contribution_summary||'',skill_tags:locked?(item.skill_tags||[]):String(values.skill_tags||'').split(/[,，]/).map(s=>s.trim()).filter(Boolean),evidence_file_ids:ids,visibility:values.visibility};
    await write(`${awardsPath}${item.id?`/${item.id}`:''}`,body,item.id?'PUT':'POST');await ui.act(async()=>{},'获奖记录已保存');ui.close();
  }}>{locked&&<p>核验中或已核验记录只能修改可见范围。</p>}</Form>;
}
