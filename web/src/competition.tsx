import {Link,useSearchParams} from 'react-router-dom';
import {useAuth} from './auth';
import {query,rows,useApi,write,type Entity} from './api';
import {Empty,Form,Head,Pagination,QueryState,Stats,Tabs,useUI} from './ui';
import {Plans,Awards} from './competition-personal';

const goals:Record<string,string>={resume:'丰富履历',ability:'提升能力',exploration:'探索方向',postgraduate:'升学准备',graduation_gap:'补足毕业条件'};
const roles:Record<string,string>={developer:'开发',modeler:'建模',hardware:'硬件',designer:'设计',writer:'写作',presenter:'答辩',organizer:'组织',any:'不限'};
export function Competition(){
  const [params,setParams]=useSearchParams(),auth=useAuth(),ui=useUI();
  const tab=params.get('tab')||'recommend';
  const privateTab=['plans','awards','capability'].includes(tab);
  return <><Head title="竞赛中心" description="赛事推荐、参赛计划与成长记录">
    <button className="btn" onClick={()=>auth.requireUser()&&ui.open('竞赛偏好',<Preferences/>)}>偏好设置</button>
    <button className="btn primary" onClick={()=>setParams({tab:'plans'})}>我的计划</button>
  </Head><Tabs tabs={[["recommend","推荐"],["directory","竞赛目录"],["plans","我的日历"],["awards","我的获奖"],["capability","能力档案"]]} value={tab} onChange={tab=>setParams({tab})}/>
  {privateTab&&!auth.user?<Empty title="登录后查看个人竞赛资料"><button className="btn primary" onClick={auth.login}>登录</button></Empty>:tab==='plans'?<Plans/>:tab==='awards'?<Awards/>:tab==='capability'?<Capability/>:<Events recommended={tab==='recommend'}/>}
  </>;
}
function Events({recommended}:{recommended:boolean}){
  const auth=useAuth(),[params,setParams]=useSearchParams();
  const page=Number(params.get('page'))||1;
  const q=useApi(query(recommended&&auth.user?'/api/user/competitions/fit':'/api/competitions/events',{page,page_size:20,keyword:params.get('q'),category_slug:params.get('category')}));
  const categories=useApi('/api/competitions/categories');
  const dashboard=useApi(recommended&&auth.user?'/api/user/competitions/dashboard':null);
  function update(key:string,value:string){const next=new URLSearchParams(params);next.set(key,value);if(key!=='page')next.set('page','1');setParams(next)}
  return <>
    {recommended&&auth.user&&<QueryState query={dashboard}><Stats items={[[dashboard.data?.award_total??0,'获奖记录'],[dashboard.data?.verified_award_count??0,'已核验'],[dashboard.data?.weekly_hours??0,'每周投入小时'],[dashboard.data?.pending_award_count??0,'待核验']]}/></QueryState>}
    {recommended&&!auth.user&&<p className="source-line">当前展示公开赛事，登录并设置偏好后获取个人推荐。</p>}
    <form className="filter-row" onSubmit={event=>{event.preventDefault();update('q',String(new FormData(event.currentTarget).get('q')||''))}}>
      <input name="q" aria-label="搜索竞赛" placeholder="搜索竞赛名称、组织单位" defaultValue={params.get('q')||''}/>
      <select aria-label="竞赛分类" value={params.get('category')||''} onChange={e=>update('category',e.target.value)}><option value="">全部分类</option>{rows(categories.data,'categories').map(c=><option key={c.id} value={c.slug}>{c.name}</option>)}</select><button className="btn">搜索</button>
    </form><QueryState query={q}><div className="panel">{rows(q.data).map(item=>{const event=item.event||item;return <Link className="comp-row" key={event.id} to={`/competition/${event.id}`}><div className="comp-logo">{event.title?.slice(0,2)}</div><div className="list-main"><b>{event.title}</b><p>{event.organizer} · {event.competition_level||event.primary_category?.name}</p>{Array.isArray(item.reasons)&&<p>{item.reasons.filter((r:unknown)=>typeof r==='string').join(' · ')}</p>}</div><span className="tag">{event.time_status||'查看详情'}</span></Link>})}</div>
      {!rows(q.data).length&&<Empty title="暂无符合条件的赛事"/>}<Pagination page={page} hasMore={q.data?.total!==undefined?page*20<q.data.total:rows(q.data).length===20} onChange={n=>update('page',String(n))}/>
    </QueryState>{recommended&&auth.user&&<div className="section two-col"><Capability compact/><section className="panel panel-pad"><h3>我的参赛计划</h3><Plans/></section></div>}
  </>;
}
function Preferences(){
  const q=useApi('/api/user/competition-preference'),ui=useUI();
  const p=q.data||{};
  return <QueryState query={q}><Form fields={[
    {name:'direction_tags',label:'感兴趣的方向（逗号分隔）',value:(p.direction_tags||[]).join(',')},
    {name:'skill_tags',label:'已有技能（逗号分隔）',value:(p.skill_tags||[]).join(',')},
    {name:'weekly_hours',label:'每周可投入小时',type:'number',min:0,max:168,value:p.weekly_hours||0,required:true},
    {name:'career_direction',label:'未来方向',value:p.career_direction},
    {name:'experience_level',label:'参赛经验',value:p.experience_level||'beginner',options:[['beginner','首次参赛'],['participated','参加过'],['awarded','有获奖经历'],['experienced','经验丰富']]},
  ]} onSubmit={async(values,form)=>{
    const split=(v:unknown)=>String(v||'').split(/[,，]/).map(s=>s.trim()).filter(Boolean);
    await write('/api/user/competition-preference',{goals:form.getAll('goals'),preferred_roles:form.getAll('preferred_roles'),direction_tags:split(values.direction_tags),skill_tags:split(values.skill_tags),weekly_hours:Number(values.weekly_hours),career_direction:values.career_direction,experience_level:values.experience_level,accept_long_term_training:form.get('long_term')==='on'},'PUT');
    await ui.act(async()=>{},'竞赛偏好已保存');ui.close();
  }}><fieldset><legend>参赛目标</legend>{Object.entries(goals).map(([value,label])=><label className="check-label" key={value}><input type="checkbox" name="goals" value={value} defaultChecked={p.goals?.includes(value)}/>{label}</label>)}</fieldset>
  <fieldset><legend>希望担任的角色</legend>{Object.entries(roles).map(([value,label])=><label className="check-label" key={value}><input type="checkbox" name="preferred_roles" value={value} defaultChecked={p.preferred_roles?.includes(value)}/>{label}</label>)}</fieldset>
  <label className="check-label"><input type="checkbox" name="long_term" defaultChecked={p.accept_long_term_training}/>接受长期训练</label></Form></QueryState>;
}
function Capability({compact=false}:{compact?:boolean}){
  const q=useApi('/api/user/competition-capability-profile');const data=q.data||{};
  return <section className="panel panel-pad"><h3>能力档案</h3><QueryState query={q}><p className="muted">按真实获奖记录汇总，区分已核验与自行填报，不推算能力等级。</p>
    {!compact&&<Stats items={[[data.verified_award_count||0,'已核验记录'],[data.self_reported_award_count||0,'自行填报记录']]}/>}
    <p>{(data.direction_tags||[]).join(' · ')||'尚未填写方向'}</p>
    {['skill_summary','role_summary'].map(key=><div key={key}>{rows(data,key).map((item:Entity)=><div className="list-row" key={item.skill||item.role}><b>{item.skill||roles[item.role]||item.role}</b><span>已核验 {item.verified_count} · 自填 {item.self_reported_count}</span></div>)}</div>)}
    {!rows(data,'skill_summary').length&&!rows(data,'role_summary').length&&<Empty title="暂无可汇总的参赛记录"/>}
  </QueryState></section>;
}
