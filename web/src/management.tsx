import {useState,type FormEvent} from 'react';
import {useSearchParams} from 'react-router-dom';
import {useAuth} from './auth';
import {query,rows,time,useApi,write,type Entity} from './api';
import {Empty,Form,Head,QueryState,Stats,useUI,type Field} from './ui';
export const managementTabs:[string,string][]=[['notices','公告'],['sections','版块'],['metrics','AI 指标'],['users','用户'],['bots','所属 AI'],['releases','版本'],['logs','操作日志']];
// 每个管理分区的标题与一句说明，管理中心按同一结构渲染分区头。
const sectionMeta:Record<string,[string,string]>={
  notices:['公告管理','编辑公告内容、展示方式和发布状态。'],
  sections:['版块管理','调整校园圈版块的名称、说明和版块公告，修改需填写原因。'],
  metrics:['AI 指标','近 7 天的 AI 请求量、成功率、Token 用量和耗时。'],
  users:['用户管理','调整用户角色和诚信分，角色变化会撤销该用户原有的登录令牌。'],
  bots:['所属 AI','查看用户创建的 AI 及其归属和启用状态。'],
  releases:['版本发布','上传安装包、编辑更新说明，并发布或下架版本。'],
  logs:['操作日志','管理员操作记录，按时间倒序。'],
};
const superOnly=new Set(['bots','users','releases','logs']);
const paths:Record<string,string>={notices:'/api/announcements/admin/list',sections:'/api/water/sections',metrics:'/api/admin/ai/metrics',users:'/api/super/users',bots:'/api/super/users',releases:'/api/super/app-releases',logs:'/api/super/admin_logs'};
export function Management({kind}:{kind:string}){
  const auth=useAuth(),ui=useUI(),[params,setParams]=useSearchParams();
  const allowed=!superOnly.has(kind)||auth.user?.role==='super_admin';
  const q=useApi(allowed?query(paths[kind],{search:params.get('search'),kind:kind==='bots'?'ai':undefined,days:kind==='metrics'?7:undefined,page:1,limit:50}):null);
  if(!allowed)return <Empty title="此操作需要超级管理员权限"/>;
  // 公告和版块在桌面端用右侧抽屉编辑，列表保持可见；其余表单内容短，仍用居中弹窗。
  function edit(item?:Entity){ui.open(kind==='notices'?(item?'编辑公告':'新建公告'):kind==='sections'?'编辑版块':kind==='users'?'用户管理':'版本管理',kind==='notices'?<NoticeForm item={item}/>:kind==='sections'?<SectionForm item={item!}/>:kind==='users'?<UserForm item={item!}/>:<ReleaseForm item={item}/>,['notices','sections'].includes(kind)?'drawer':'modal')}
  const list=rows(q.data,'announcements','sections','users','logs');
  const [title,description]=sectionMeta[kind]||[kind,''];
  return <><Head level={2} title={title} description={description}>
      {kind!=='metrics'&&!q.isPending&&!q.error&&<span className="admin-count">共 {list.length} 条</span>}
      {['notices','releases'].includes(kind)&&<button className="btn primary" onClick={()=>edit()}>新增{kind==='notices'?'公告':'版本草稿'}</button>}
      <button className="btn" disabled={q.isFetching} onClick={()=>void q.refetch()}>刷新</button>
    </Head>
    {['users','bots'].includes(kind)&&<div className="filter-row admin-search"><form onSubmit={e=>{e.preventDefault();setParams({tab:kind,search:String(new FormData(e.currentTarget).get('search')||'')})}}><input name="search" aria-label={kind==='bots'?'搜索 AI 或创建者':'搜索用户'} placeholder={kind==='bots'?'AI 名称或创建者昵称':'昵称、账号或用户 ID'} defaultValue={params.get('search')||''}/><button className="btn">搜索</button></form></div>}
    <QueryState query={q}>{kind==='metrics'?<Metrics data={q.data||{}}/>:<div className="panel admin-list">{list.map(x=><div className="list-row admin-row" key={x.id}><div className="list-main">{kind==='bots'&&<small className="managed-ai-label">用户所属 AI</small>}<b>{x.title||x.nickname||x.version_name||x.action||x.name}</b><p>{kind==='logs'?`${x.admin_name} · ${x.target} · ${x.detail}`:kind==='bots'?`${x.id} · 归属于 ${x.owner_name}（#${x.owner_id}） · ${x.enabled?'已启用':'已暂停'}`:kind==='users'?`#${x.id} · ${x.role} · 诚信分 ${x.credit_score}`:kind==='releases'?`${x.version_code} · ${x.status} · ${x.channel}`:x.description||x.status}</p><small>{time(x.created_at)}</small></div>{!['logs','bots'].includes(kind)&&<button className="btn" onClick={()=>edit(x)}>管理</button>}</div>)}{!list.length&&<Empty title="暂无记录"/>}</div>}</QueryState></>;
}
const noticeModes:[string,string][]=[['center','通知中心'],['banner','横幅'],['modal','弹窗']];
function NoticeForm({item={}}:{item?:Entity}){
  const ui=useUI();
  const [pv,setPv]=useState({title:String(item.title||''),content:String(item.content||''),mode:String(item.display_mode||'center'),priority:String(item.priority||'normal')});
  // 表单本身不受控，预览从表单当前值读取，避免改动共享 Form 组件。
  const sync=(e:FormEvent<HTMLDivElement>)=>{const f=e.currentTarget.querySelector('form');if(!f)return;const d=new FormData(f);setPv({title:String(d.get('title')||''),content:String(d.get('content')||''),mode:String(d.get('display_mode')||'center'),priority:String(d.get('priority')||'normal')})};
  return <div className="notice-editor" onInput={sync} onChange={sync}><Form fields={[{name:'title',label:'公告标题',value:item.title,required:true},{name:'content',label:'正文',type:'textarea',value:item.content,required:true},{name:'status',label:'状态',value:item.status||'draft',options:[['draft','草稿'],['published','发布'],['archived','归档']]},{name:'display_mode',label:'展示方式',value:item.display_mode||'center',options:noticeModes,help:'弹窗会打断用户，只用于紧急事项。'},{name:'priority',label:'优先级',value:item.priority||'normal',options:[['normal','普通'],['important','重要'],['urgent','紧急']]}]} onSubmit={async(values,form)=>{await write(`/api/announcements${item.id?`/${item.id}`:''}`,{...values,is_pinned:form.get('pinned')==='on',include_new_users:form.get('new_users')==='on'},item.id?'PUT':'POST');await ui.act(async()=>{},'公告已保存');ui.close()}}><label className="check-label"><input name="pinned" type="checkbox" defaultChecked={item.is_pinned}/>置顶</label><label className="check-label"><input name="new_users" type="checkbox" defaultChecked={item.include_new_users}/>新注册用户也可查看</label><NoticePreview {...pv}/></Form></div>;
}
// 预览只示意位置与层级，不代表各端的精确样式。
function NoticePreview({title,content,mode,priority}:{title:string;content:string;mode:string;priority:string}){
  const t=title.trim()||'公告标题',c=content.trim()||'公告正文会显示在这里';
  return <div className="notice-preview" aria-label="公告预览"><small>用户看到的样子 · {noticeModes.find(([v])=>v===mode)?.[1]||'通知中心'}</small>
    <div className="notice-preview-screen">
      <i className="notice-preview-bar"/>
      {mode==='banner'&&<div className={`notice-preview-banner is-${priority}`}><b>{t}</b></div>}
      {mode==='center'&&<div className="notice-preview-item"><b>{t}</b><p>{c}</p></div>}
      <div className="notice-preview-lines"><i/><i/><i/></div>
      {mode==='modal'&&<div className="notice-preview-modal"><div><b>{t}</b><p>{c}</p></div></div>}
    </div>
  </div>;
}
function SectionForm({item}:{item:Entity}){const ui=useUI();return <Form fields={[{name:'title',label:'版块名称',value:item.title,required:true},{name:'subtitle',label:'副标题',value:item.subtitle},{name:'description',label:'版块说明',type:'textarea',value:item.description},{name:'notice_text',label:'版块公告',type:'textarea',value:item.notice_text},{name:'reason',label:'修改原因',required:true}]} onSubmit={async values=>{await write(`/api/water/sections/${encodeURIComponent(item.slug)}`,values,'PATCH');await ui.act(async()=>{},'版块已更新');ui.close()}}/>}
function UserForm({item}:{item:Entity}){const ui=useUI();return <><p>{item.nickname} · #{item.id}</p><p>角色变化会按服务端规则撤销该用户原有令牌。</p><Form fields={[{name:'role',label:'角色',value:item.role,options:[['user','普通用户'],['admin','管理员'],['super_admin','超级管理员']]}]} submit="确认修改角色" onSubmit={async values=>{await write(`/api/super/users/${item.id}/role`,values,'PUT');await ui.act(async()=>{},'角色已更新');ui.close()}}/><Form fields={[{name:'credit_score',label:'诚信分',type:'number',min:0,max:100,value:item.credit_score,required:true}]} submit="保存诚信分" onSubmit={async values=>{await write(`/api/super/users/${item.id}/credit`,{credit_score:Number(values.credit_score)},'PUT');await ui.act(async()=>{},'诚信分已更新');ui.close()}}/></>}
function ReleaseForm({item={}}:{item?:Entity}){
  const ui=useUI();const base='/api/super/app-releases';const fields:Field[]=[
    ...(!item.id?[{name:'version_name',label:'版本名称',required:true},{name:'version_code',label:'版本号（正整数）',type:'number',min:1,required:true},{name:'apk',label:'APK 文件',type:'file',required:true}]:[]),
    {name:'title',label:'更新标题',value:item.title,required:true},{name:'changelog',label:'更新说明',type:'textarea',value:item.changelog,required:true},
    {name:'minimum_supported_version_code',label:'最低支持版本号',type:'number',min:1,required:true,value:item.minimum_supported_version_code||1}];
  async function action(name:string,method='POST'){if(await ui.act(()=>write(`${base}/${item.id}${name?`/${name}`:''}`,{},method),'版本状态已更新'))ui.close()}
  return <><p>{item.version_name} {item.status}</p><Form fields={fields} onSubmit={async(values,form)=>{if(item.id)await write(`${base}/${item.id}`,{title:values.title,changelog:values.changelog,minimum_supported_version_code:Number(values.minimum_supported_version_code)},'PATCH');else{form.set('delivery_mode','direct_package');form.set('platform','android');form.set('channel','stable');await write(base,form)}await ui.act(async()=>{},'版本草稿已保存');ui.close()}}/>{item.id&&<div className="form-actions">{item.status==='draft'&&<button className="btn primary" onClick={()=>ui.open('确认发布版本',<><p>发布 {item.version_name} 后，客户端将能检测并下载该版本。</p><button className="btn primary" onClick={()=>void action('publish')}>确认发布</button></>)}>发布版本</button>}{item.status==='published'&&<button className="btn" onClick={()=>ui.open('确认下架版本',<><p>确认下架 {item.version_name}？服务器会检查是否存在可用的回退版本。</p><button className="btn" onClick={()=>void action('withdraw')}>确认下架</button></>)}>下架版本</button>}{item.status==='draft'&&<button className="btn" onClick={()=>ui.open('删除版本草稿',<><p>确认删除草稿及其私有 APK 文件？</p><button className="btn danger" onClick={()=>void action('','DELETE')}>确认删除</button></>)}>删除草稿</button>}</div>}</>;
}
const count=(n:unknown)=>Number(n||0).toLocaleString('zh-CN');
// P95 超过 1 秒时换算成秒，避免 26826 ms 这类长数字难以一眼读出量级。
const latency=(ms:unknown)=>{const n=Number(ms||0);return n>=1000?`${(n/1000).toFixed(1)} 秒`:`${n} 毫秒`};
function Metrics({data}:{data:Entity}){return <div className="admin-metrics"><Stats items={[[count(data.requests),'近 7 天请求'],[`${((data.success_rate||0)*100).toFixed(1)}%`,'成功率'],[count(data.input_output_tokens),'输入输出 Token'],[latency(data.latency_ms?.p95),'P95 耗时']]}/><div className="panel table-scroll"><table className="data-table admin-table"><thead><tr><th>模型</th><th className="num">请求</th><th className="num">Token</th><th className="num">已计价请求</th></tr></thead><tbody>{rows(data,'by_model').map(m=><tr key={m.name}><td>{m.name}</td><td className="num">{count(m.requests)}</td><td className="num">{count(m.tokens)}</td><td className="num">{count(m.priced_requests)}</td></tr>)}</tbody></table>{!rows(data,'by_model').length&&<Empty title="近 7 天没有 AI 请求"/>}</div></div>}
