import {useState,type FormEvent} from 'react';
import {useSearchParams} from 'react-router-dom';
import {useAuth} from './auth';
import {query,rows,time,useApi,write,type Entity} from './api';
import {Empty,Form,Head,Pagination,QueryState,Stats,useUI,type Field} from './ui';
import {AdminWaterSectionDrawer} from './admin-governance';

export const managementTabs:[string,string][]=[['notices','公告'],['sections','版块'],['metrics','AI 指标'],['users','用户'],['bots','所属 AI'],['releases','版本'],['logs','操作日志']];
const sectionMeta:Record<string,[string,string]>={
  notices:['公告管理','编辑公告内容、展示方式和发布状态。'],
  sections:['水帖版块治理','配置版块资料、子标签、1–8 级称号、协管版主、禁言名单及版块日志。'],
  metrics:['AI 运营指标','查看 AI 请求量、成功率、Token 用量、耗时与各模型/用途明细。'],
  users:['用户管理','调整用户角色和诚信分、重置密码或移除违规账号，角色变化会撤销原有登录令牌。'],
  bots:['所属 AI','查看用户创建的 AI 及其归属、启用状态与活动记录。'],
  releases:['版本发布','管理 Android / HarmonyOS 安装包与外部市场更新发布。'],
  logs:['操作日志','超级管理员审计记录与管理员经验追回。'],
};
const superOnly=new Set(['bots','users','releases','logs']);
const paths:Record<string,string>={notices:'/api/announcements/admin/list',sections:'/api/water/sections',metrics:'/api/admin/ai/metrics',users:'/api/super/users',bots:'/api/super/users',releases:'/api/super/app-releases',logs:'/api/super/admin_logs'};

export function Management({kind}:{kind:string}){
  const auth=useAuth(),ui=useUI(),[params,setParams]=useSearchParams();
  const allowed=!superOnly.has(kind)||auth.user?.role==='super_admin';
  const page=Number(params.get('page'))||1;
  const days=Number(params.get('days'))||7;
  const roleFilter=params.get('role')||'';
  const q=useApi(allowed?query(paths[kind],{
    search:params.get('search'),
    role:kind==='users'&&roleFilter?roleFilter:undefined,
    kind:kind==='bots'?'ai':undefined,
    days:kind==='metrics'?days:undefined,
    page,
    limit:kind==='users'||kind==='logs'?30:50,
  }):null);
  if(!allowed)return <Empty title="此操作需要超级管理员权限"/>;

  function edit(item?:Entity){
    if(kind==='sections'&&item){
      ui.open(`版块治理 · ${item.title||item.name}`,<AdminWaterSectionDrawer item={item} onSaved={()=>void q.refetch()}/>,'drawer');
      return;
    }
    ui.open(
      kind==='notices'?(item?'编辑公告':'新建公告'):kind==='users'?'用户管理':'版本管理',
      kind==='notices'?<NoticeForm item={item}/>:kind==='users'?<UserForm item={item!}/>:<ReleaseForm item={item}/>,
      kind==='notices'?'drawer':'modal',
    );
  }

  const list=rows(q.data,'announcements','sections','users','releases','logs','items');
  const [title,description]=sectionMeta[kind]||[kind,''];
  return <>
    <Head level={2} title={title} description={description}>
      {kind!=='metrics'&&!q.isPending&&!q.error&&<span className="admin-count">共 {q.data?.total??list.length} 条</span>}
      {kind==='metrics'&&(
        <div className="admin-seg" role="group" aria-label="统计天数">
          {[1,7,14,30].map(d=><button key={d} type="button" aria-pressed={days===d} onClick={()=>setParams({tab:'metrics',days:String(d)})}>近 {d} 天</button>)}
        </div>
      )}
      {kind==='bots'&&<button type="button" className="btn" onClick={()=>ui.open('AI 活动审计',<ManagedAiActivitiesDrawer/>,'drawer')}>活动审计</button>}
      {kind==='logs'&&<button type="button" className="btn" onClick={()=>ui.open('追回管理员经验',<Form fields={[{name:'admin_id',label:'管理员 UID',type:'number',min:1,required:true},{name:'amount',label:'追回经验值',type:'number',min:1,required:true},{name:'reason',label:'追回原因（必填）',type:'textarea',required:true}]} submit="确认追回" onSubmit={async v=>{await write('/api/super/admin_logs/revoke_exp',{admin_id:Number(v.admin_id),amount:Number(v.amount),reason:v.reason});await q.refetch();ui.notify('管理员经验已扣减');ui.close();}}/>)}>追回经验</button>}
      {['notices','releases'].includes(kind)&&<button className="btn primary" onClick={()=>edit()}>新增{kind==='notices'?'公告':'版本草稿'}</button>}
      <button className="btn" disabled={q.isFetching} onClick={()=>void q.refetch()}>刷新</button>
    </Head>
    {['users','bots'].includes(kind)&&(
      <div className="filter-row admin-toolbar">
        <form className="admin-search" onSubmit={e=>{e.preventDefault();setParams({tab:kind,search:String(new FormData(e.currentTarget).get('search')||''),...(roleFilter?{role:roleFilter}:{})});}}>
          <input name="search" aria-label={kind==='bots'?'搜索 AI 或创建者':'搜索用户'} placeholder={kind==='bots'?'AI 名称或创建者昵称':'昵称、账号或用户 ID'} defaultValue={params.get('search')||''}/>
          <button className="btn">搜索</button>
        </form>
        {kind==='users'&&(
          <select aria-label="角色筛选" value={roleFilter} onChange={e=>setParams({tab:'users',...(params.get('search')?{search:params.get('search')!}:{}),...(e.target.value?{role:e.target.value}:{})})}>
            <option value="">全部角色</option>
            <option value="user">普通用户</option>
            <option value="admin">管理员</option>
            <option value="super_admin">超级管理员</option>
          </select>
        )}
      </div>
    )}
    <QueryState query={q}>
      {kind==='metrics'?<Metrics data={q.data||{}}/>:<>
        <div className="panel admin-list">
          {list.map(x=><div className="list-row admin-row" key={x.id}>
            <div className="list-main">
              {kind==='bots'&&<small className="managed-ai-label">用户所属 AI</small>}
              <div className="admin-row-head">
                <b>{x.title||x.nickname||x.version_name||x.action||x.name}</b>
                {kind==='notices'&&x.status&&<span className={`tag ${x.status==='published'?'is-resolved':x.status==='draft'?'warn':''}`}>{({draft:'草稿',published:'已发布',archived:'已归档'} as Record<string,string>)[x.status]||x.status}</span>}
                {kind==='users'&&<span>教务配置：{x.academic_configured ? '已登记' : '未登记'}</span>}
                {kind==='users'&&x.role&&<span className={`tag ${x.role==='super_admin'?'violet':x.role==='admin'?'brand':''}`}>{x.role}</span>}
                {kind==='releases'&&x.platform&&<span className="tag">{x.platform}</span>}
              </div>
              <p>{kind==='logs'?`${x.admin_name||`#${x.admin_id}`} · ${x.target||''} · ${x.detail||''}${x.admin_exp!=null?`（经验 ${x.admin_exp}）`:''}`:kind==='bots'?`${x.id} · 归属于 ${x.owner_name}（#${x.owner_id}） · ${x.enabled?'已启用':'已暂停'}`:kind==='users'?`#${x.id} · ${x.role} · 诚信分 ${x.credit_score}`:kind==='releases'?`v${x.version_code} · ${x.status} · ${x.delivery_mode||x.channel||'direct_package'}`:x.description||x.subtitle||x.status}</p>
              <small>{time(x.created_at)}</small>
            </div>
            {!['logs','bots'].includes(kind)&&<button className="btn" onClick={()=>edit(x)}>管理</button>}
          </div>)}
          {!list.length&&<Empty title="暂无记录"/>}
        </div>
        {['users','logs'].includes(kind)&&(page>1||list.length>=30)&&(
          <Pagination page={page} hasMore={list.length>=30} onChange={next=>setParams({tab:kind,...(params.get('search')?{search:params.get('search')!}:{}),...(roleFilter?{role:roleFilter}:{}),page:String(next)})}/>
        )}
      </>}
    </QueryState>
  </>;
}

const noticeModes:[string,string][]=[['center','通知中心'],['banner','横幅'],['modal','弹窗']];
function NoticeForm({item={}}:{item?:Entity}){
  const ui=useUI();
  const [pv,setPv]=useState({title:String(item.title||''),content:String(item.content||''),mode:String(item.display_mode||'center'),priority:String(item.priority||'normal')});
  const sync=(e:FormEvent<HTMLDivElement>)=>{const f=e.currentTarget.querySelector('form');if(!f)return;const d=new FormData(f);setPv({title:String(d.get('title')||''),content:String(d.get('content')||''),mode:String(d.get('display_mode')||'center'),priority:String(d.get('priority')||'normal')});};
  return <div className="notice-editor" onInput={sync} onChange={sync}>
    <Form fields={[
      {name:'title',label:'公告标题',value:item.title,required:true},
      {name:'content',label:'正文',type:'textarea',value:item.content,required:true},
      {name:'status',label:'状态',value:item.status||'draft',options:[['draft','草稿'],['published','发布'],['archived','归档']]},
      {name:'display_mode',label:'展示方式',value:item.display_mode||'center',options:noticeModes,help:'弹窗会打断用户，正式发布弹窗需将优先级设为“紧急”。'},
      {name:'priority',label:'优先级',value:item.priority||'normal',options:[['normal','普通'],['important','重要'],['urgent','紧急']]},
    ]} onSubmit={async(values,form)=>{
      await write(`/api/announcements${item.id?`/${item.id}`:''}`,{...values,is_pinned:form.get('pinned')==='on',include_new_users:form.get('new_users')==='on'},item.id?'PUT':'POST');
      await ui.act(async()=>{},'公告已保存');ui.close();
    }}>
      <label className="check-label"><input name="pinned" type="checkbox" defaultChecked={item.is_pinned}/>置顶</label>
      <label className="check-label"><input name="new_users" type="checkbox" defaultChecked={item.include_new_users}/>新注册用户也可查看</label>
      <NoticePreview {...pv}/>
    </Form>
    {item.id&&<div className="form-actions"><button type="button" className="btn danger" onClick={()=>void ui.act(async()=>{await write(`/api/announcements/${item.id}`,{},'DELETE');ui.close();},'公告已删除')}>删除公告</button></div>}
  </div>;
}

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

function UserForm({item}:{item:Entity}){
  const ui=useUI();
  const isSuperTarget=item.role==='super_admin';
  return <div className="admin-drawer-stack">
    <p><b>{item.nickname||'未命名用户'}</b> · UID #{item.id} · 当前角色 {item.role} · 教务配置：{item.academic_configured ? "已登记" : "未登记"}</p>
    {isSuperTarget?<p className="muted">超级管理员角色受系统保护，不可在线降权或删除。</p>:(
      <Form fields={[{name:'role',label:'角色（变更后立即吊销旧登录态）',value:item.role==='admin'?'admin':'user',options:[['user','普通用户'],['admin','管理员']]}]} submit="确认修改角色" onSubmit={async values=>{await write(`/api/super/users/${item.id}/role`,values,'PUT');await ui.act(async()=>{},'角色已更新');ui.close();}}/>
    )}
    <Form fields={[{name:'credit_score',label:'诚信分 (0–100)',type:'number',min:0,max:100,value:item.credit_score,required:true},{name:'reason',label:'调整原因',value:'管理端核定调整',required:true}]} submit="保存诚信分" onSubmit={async values=>{await write(`/api/super/users/${item.id}/credit`,{credit_score:Number(values.credit_score),reason:values.reason},'PUT');await ui.act(async()=>{},'诚信分已更新');ui.close();}}/>
    <Form fields={[{name:'new_password',label:'重置登录密码（8–32 位）',type:'password',required:true,autoComplete:'new-password'}]} submit="重置该用户密码" onSubmit={async values=>{await write(`/api/super/users/${item.id}/reset_password`,{new_password:values.new_password});await ui.act(async()=>{},'密码已重置');ui.close();}}/>
    {!isSuperTarget&&(
      <div className="form-actions">
        <button type="button" className="btn danger" onClick={()=>ui.open('确认删除账号',<><p>删除 UID #{item.id}（{item.nickname}）将永久移除账号访问权限，确定继续？</p><button type="button" className="btn danger" onClick={async()=>{if(await ui.act(()=>write(`/api/super/users/${item.id}`,{},'DELETE'),'用户已删除'))ui.close();}}>确认删除用户</button></>)}>删除用户账号</button>
      </div>
    )}
  </div>;
}

function ReleaseForm({item={}}:{item?:Entity}){
  const ui=useUI();const base='/api/super/app-releases';
  const [mode,setMode]=useState(String(item.delivery_mode||'direct_package'));
  const fields:Field[]=[
    ...(!item.id?([
      {name:'platform',label:'目标平台',value:'android',options:[['android','Android'],['ohos','HarmonyOS NEXT']]},
      {name:'delivery_mode',label:'分发方式',value:mode,options:[['direct_package','直传安装包'],['external_market','外部应用市场链接']]},
      {name:'version_name',label:'版本名称',required:true},
      {name:'version_code',label:'版本号（正整数）',type:'number',min:1,required:true},
      ...(mode==='external_market'?[{name:'action_url',label:'应用市场地址',required:true}]:[{name:'apk',label:'安装包文件',type:'file',required:true}]),
    ] as Field[]):[]),
    {name:'title',label:'更新标题',value:item.title,required:true},
    {name:'changelog',label:'更新说明',type:'textarea',value:item.changelog||item.release_notes,required:true},
    {name:'minimum_supported_version_code',label:'最低支持版本号',type:'number',min:1,required:true,value:item.minimum_supported_version_code||item.min_supported_version_code||1},
  ];
  async function action(name:string,method='POST'){if(await ui.act(()=>write(`${base}/${item.id}${name?`/${name}`:''}`,{},method),'版本状态已更新'))ui.close();}
  return <div onChange={e=>{if(e.target instanceof HTMLSelectElement&&e.target.name==='delivery_mode')setMode(e.target.value);}}>
    {item.id&&<p><b>{item.version_name}</b> · {item.status}</p>}
    <Form fields={fields} onSubmit={async(values,form)=>{
      if(item.id){
        await write(`${base}/${item.id}`,{title:values.title,changelog:values.changelog,release_notes:values.changelog,minimum_supported_version_code:Number(values.minimum_supported_version_code),min_supported_version_code:Number(values.minimum_supported_version_code)},'PATCH');
      }else{
        form.set('channel','stable');
        form.set('release_notes',String(values.changelog||''));
        form.set('min_supported_version_code',String(values.minimum_supported_version_code||1));
        const file=form.get('apk');
        if(file instanceof File&&file.size>0&&!form.get('package'))form.set('package',file);
        await write(base,form);
      }
      await ui.act(async()=>{},'版本草稿已保存');ui.close();
    }}/>
    {item.id&&<div className="form-actions">
      {item.status==='draft'&&<button className="btn primary" onClick={()=>ui.open('确认发布版本',<><p>发布 {item.version_name} 后，客户端将能检测并下载该版本。</p><button className="btn primary" onClick={()=>void action('publish')}>确认发布</button></>)}>发布版本</button>}
      {item.status==='published'&&<button className="btn" onClick={()=>ui.open('确认下架版本',<><p>确认下架 {item.version_name}？服务器会检查是否存在可用的回退版本。</p><button className="btn" onClick={()=>void action('withdraw')}>确认下架</button></>)}>下架版本</button>}
      {item.status==='draft'&&<button className="btn danger" onClick={()=>ui.open('删除版本草稿',<><p>确认删除草稿及其安装包文件？</p><button className="btn danger" onClick={()=>void action('','DELETE')}>确认删除</button></>)}>删除草稿</button>}
    </div>}
  </div>;
}

function ManagedAiActivitiesDrawer(){
  const q=useApi('/api/super/managed-ai/activities?page=1&limit=40');
  const list=rows(q.data,'items','activities');
  return <QueryState query={q}>
    <div className="panel admin-list">
      {list.map((a,i)=><div className="list-row admin-row" key={a.id||i}>
        <div className="list-main">
          <b>{a.action_type||a.action||'AI 活动'} · {a.result||'ok'}</b>
          <p>Bot UID #{a.actor_user_id||a.bot_id||'—'} · 归属 #{a.owner_user_id||'—'}{a.summary?` · ${a.summary}`:''}</p>
          <small>{time(a.created_at)}</small>
        </div>
      </div>)}
      {!list.length&&<Empty title="暂无 AI 活动审计记录"/>}
    </div>
  </QueryState>;
}

const count=(n:unknown)=>Number(n||0).toLocaleString('zh-CN');
const latency=(ms:unknown)=>{const n=Number(ms||0);return n>=1000?`${(n/1000).toFixed(1)} 秒`:`${n} 毫秒`;};
function Metrics({data}:{data:Entity}){
  const models=rows(data,'by_model','by_provider');
  const purposes=rows(data,'by_purpose');
  const yuan=typeof data.cost_micro_yuan==='number'?`¥${(data.cost_micro_yuan/1_000_000).toFixed(2)}`:null;
  return <div className="admin-metrics">
    <Stats items={[
      [count(data.requests),`近 ${data.window_days||7} 天请求`],
      [`${((data.success_rate||0)*100).toFixed(1)}%`,'成功率'],
      [count(data.input_output_tokens??data.tokens?.total??data.tokens),'总 Token'],
      [yuan||latency(data.latency_ms?.p95),yuan?`预估成本（P95 ${latency(data.latency_ms?.p95)}）`:'P95 耗时'],
    ]}/>
    <div className="panel table-scroll">
      <table className="data-table admin-table">
        <thead><tr><th>模型 / 提供方</th><th className="num">请求</th><th className="num">Token</th><th className="num">已计价请求</th></tr></thead>
        <tbody>{models.map((m,i)=><tr key={m.name||m.provider||i}><td>{m.name||m.provider}</td><td className="num">{count(m.requests)}</td><td className="num">{count(m.tokens)}</td><td className="num">{count(m.priced_requests)}</td></tr>)}</tbody>
      </table>
      {!models.length&&<Empty title="当前时间窗内没有 AI 请求"/>}
    </div>
    {purposes.length>0&&(
      <div className="panel table-scroll">
        <table className="data-table admin-table">
          <thead><tr><th>业务场景</th><th className="num">请求量</th><th className="num">Token</th></tr></thead>
          <tbody>{purposes.map((p,i)=><tr key={p.purpose||p.name||i}><td>{p.purpose||p.name}</td><td className="num">{count(p.requests)}</td><td className="num">{count(p.tokens)}</td></tr>)}</tbody>
        </table>
      </div>
    )}
  </div>;
}
