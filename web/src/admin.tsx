import {useEffect,useRef,useState,type FormEvent,type RefObject} from 'react';
import './admin.css';
import {Link,useSearchParams} from 'react-router-dom';
import {useAuth} from './auth';
import {rows,useApi,write,time,entity,errorText,type Entity} from './api';
import {Empty,Form,Head,Icon,QueryState,Tabs,useUI,type Field} from './ui';
import {Feedback} from './feedback';
import {paperFields} from './papers';
import {Management,managementTabs} from './management';
import {IntegrationManagement} from './integration-management';
import {AdminTickets} from './admin-tickets';
import {AdminOverview,useAdminCounts} from './admin-overview';
import {useMobile} from './mobile';
import {ServerAvatar} from './server-avatar';
import {waitLevel,waitText} from './admin-time';
import {canteenGovernanceReasons,governanceReasonPresets,reportHandlePayload,reportNote,reportPreview,reportReasonLabel,reportSnapshot,reportStatuses,reportTargetHref,reportTargetLabel} from './report-labels';
// 审核队列：[标签名, 列表接口, 分区说明]
const queues:Record<string,[string,string,string]>={
  reports:['举报处理','/api/reports','核对被举报内容的快照后忽略或确认违规，每条举报只能处理一次。'],
  papers:['试卷审核','/api/admin/exam-papers','核对试卷信息和预览后通过或驳回。'],
  awards:['获奖核验','/api/admin/competition-awards/verifications','核对获奖材料后通过或驳回。'],
  canteens:['食堂审核','/api/canteens/pending','审核用户提交的食堂信息。'],
  teachers:['教师审核','/api/teachers/pending','审核用户提交的教师信息。'],
};
const reportFilters:[string,string][]=[['pending','待处理'],['handled','已处理'],['ignored','已忽略'],['all','全部']];
const superOnly=new Set(['awards','bots','users','releases','logs']);
// 桌面端分组导航：[分组名, [模块 id, 名称, 图标]]；超级管理员专属模块对普通管理员不显示。
const groups:[string,[string,string,string][]][]=[
  ['',[['overview','工作台','dashboard']]],
  ['待处理',[['feedback','工单','feedback'],['reports','举报','info']]],
  ['内容审核',[['papers','试卷审核','file'],['canteens','食堂审核','canteen'],['teachers','教师审核','profile'],['awards','获奖核验','competition']]],
  ['站点运营',[['notices','公告','bell'],['sections','版块','community'],['metrics','AI 指标','trending']]],
  ['集成',[['integrations','助手授权','monitor']]],
  ['超级管理员',[['users','用户','admin'],['bots','所属 AI','ai'],['releases','版本发布','phone'],['logs','操作日志','clock']]],
];
const allModules=groups.flatMap(([,items])=>items);
export function Admin(){
  const auth=useAuth(),mobile=useMobile();const [params,setParams]=useSearchParams();
  // 桌面默认进入工作台；手机端对照 App，默认仍是工单列表。
  const tab=params.get('tab')||(mobile?'feedback':'overview');
  const navigation=useRef<HTMLDivElement>(null);
  useEffect(()=>{
    const showCurrent=()=>{
      // 跨断点时等新导航挂载；旧桌面导航不能先把整个手机页面滚走。
      if(window.matchMedia('(max-width: 600px)').matches!==mobile)return;
      const selected=navigation.current?.querySelector<HTMLElement>('[aria-selected="true"],[aria-current="page"]');
      if(!selected)return;
      if(mobile){
        // 只滚动标签容器，避免 scrollIntoView 把标签滚到固定页头下面。
        const tabs=selected.parentElement;
        if(tabs){
          const item=selected.getBoundingClientRect(),bounds=tabs.getBoundingClientRect();
          tabs.scrollLeft+=item.left-bounds.left-(tabs.clientWidth-item.width)/2;
        }
      }else selected.scrollIntoView({block:'nearest',inline:'nearest'});
    };
    showCurrent();
    window.addEventListener('resize',showCurrent);
    return ()=>window.removeEventListener('resize',showCurrent);
  },[tab,auth.user?.id,mobile]);
  if(!auth.user)return <Empty icon="lock" title="登录后访问管理中心"><button className="btn primary" onClick={auth.login}>登录</button></Empty>;
  if(!['admin','super_admin'].includes(auth.user.role))return <Empty title="当前账号没有管理权限"/>;
  const isSuper=auth.user.role==='super_admin';
  const visible=(id:string)=>!superOnly.has(id)||isSuper;
  const open=(next:string,extra:Record<string,string>={})=>setParams({tab:next,...extra});
  const content=tab==='overview'?<AdminOverview open={open}/>
    :tab==='integrations'?<IntegrationManagement key={auth.user.id}/>
    :tab==='feedback'?(mobile?<Feedback admin/>:<AdminTickets/>)
    :!visible(tab)?<Empty icon="lock" title="此模块需要超级管理员权限"/>
    :queues[tab]?<Queue kind={tab}/>
    :managementTabs.some(([id])=>id===tab)?<Management kind={tab}/>
    :<Empty title="管理模块不存在"/>;
  const tabs:[string,string][]=[["integrations","助手授权"],["feedback","工单"],...Object.entries(queues).filter(([id])=>visible(id)).map(([id,[name]])=>[id,name] as [string,string]),...managementTabs.filter(([id])=>visible(id))];
  const name=allModules.find(([id])=>id===tab)?.[1];
  // 内容保留同一父节点，窗口跨断点时不卸载正在编辑的表单。
  return <div className={mobile?'admin-page':'admin-console'}>
    {mobile?<div>
      <Head title="管理中心" description="处理工单、举报和各类审核，结果以服务器保存为准"/>
      <nav className="admin-tabs" aria-label="管理模块" ref={navigation}><Tabs value={tab} tabs={tabs} onChange={tab=>setParams({tab})}/></nav>
    </div>:<AdminNav tab={tab} isSuper={isSuper} visible={visible} navRef={navigation}/>}
    <div className="admin-main" key="admin-content">
      {!mobile&&<h1 className="sr-only">管理中心{name?` · ${name}`:''}</h1>}
      <section className="admin-section" key={tab}>{content}</section>
    </div>
  </div>;
}
function AdminNav({tab,isSuper,visible,navRef}:{tab:string;isSuper:boolean;visible:(id:string)=>boolean;navRef:RefObject<HTMLDivElement|null>}){
  const auth=useAuth(),counts=useAdminCounts() as Record<string,number|boolean|undefined>;
  return <aside className="admin-nav" aria-label="管理模块" ref={navRef}>
    <Link className="admin-back" to="/"><Icon name="chevron" size={14}/>返回校园</Link>
    <div className="admin-who">
      <ServerAvatar key={auth.user?.id} src={auth.user?.avatar} name={auth.user?.nickname||'管理员'}/>
      <span><b>{auth.user?.nickname||'管理员'}</b><small>{isSuper?'超级管理员':'管理员'}</small></span>
    </div>
    {groups.map(([label,items])=>{
      const shown=items.filter(([id])=>visible(id));
      if(!shown.length)return null;
      return <div className="nav-section" key={label||'home'}>
        {label&&<div className="nav-label">{label}</div>}
        {shown.map(([id,text,icon])=>{
          const n=counts[id];
          return <Link key={id} to={`/admin?tab=${id}`} className={`nav-item ${tab===id?'active':''}`} aria-current={tab===id?'page':undefined}>
            <span className="nav-icon"><Icon name={icon}/></span>
            <span className="nav-text">{text}</span>
            {typeof n==='number'&&<span className={`admin-badge ${n>0&&(id==='feedback'||id==='reports')?'is-hot':''}`} aria-label={`${n} 项待处理`}>{n}</span>}
            {id==='integrations'&&counts.integrationsDown&&<span className="admin-dot" title="接口未部署" aria-label="接口异常"/>}
          </Link>;
        })}
      </div>;
    })}
  </aside>;
}
function Queue({kind}:{kind:string}){
  const meta=queues[kind],ui=useUI(),[params,setParams]=useSearchParams();
  // 举报默认只看待处理：已处理的举报再次提交会被服务端拒绝。
  const filter=kind==='reports'?(params.get('status')||'pending'):'';
  const q=useApi(kind==='reports'&&filter!=='all'?`${meta[1]}?status=${encodeURIComponent(filter)}`:meta[1]);
  const list=rows(q.data,'reports','verifications','canteens','teachers','papers');
  // 同一目标的待处理举报：处理其中一条后服务端会把其余几条一并结案，这里提前提示。
  const sameTarget=(x:Entity)=>list.filter(r=>r.status==='pending'&&r.target_type===x.target_type&&r.target_id===x.target_id).length;
  const open=(x:Entity)=>ui.open(meta[0],<Review kind={kind} item={x}/>);
  return <>
    <Head level={2} title={meta[0]} description={meta[2]}>
      {!q.isPending&&!q.error&&<span className="admin-count">共 {list.length} 条</span>}
      <button className="btn" disabled={q.isFetching} onClick={()=>void q.refetch()}>刷新</button>
    </Head>
    {kind==='reports'&&<div className="admin-filter"><Tabs value={filter} tabs={reportFilters} onChange={status=>setParams({tab:kind,status})}/></div>}
    <QueryState query={q}><div className={kind==='reports'?'admin-reports':'panel admin-list'} aria-busy={q.isFetching}>
      {list.map(x=>kind==='reports'?<ReportRow key={x.id} item={x} same={sameTarget(x)}/>:<div className="list-row admin-row" key={x.id}>
        <div className="list-main"><b>{x.title||x.name||x.award_name||`#${x.id}`}</b>{(x.reason||x.description||x.comment||x.status)&&<p>{x.reason||x.description||x.comment||x.status}</p>}<small>{time(x.created_at)}</small></div>
        <button className="btn" onClick={()=>open(x)}>处理</button>
      </div>)}
      {!list.length&&<div className={kind==='reports'?'panel':''}><Empty title={kind==='reports'&&filter==='pending'?'没有待处理的举报':'当前队列为空'}/></div>}
    </div></QueryState>
  </>;
}
// 举报在卡片内处理，不再弹窗：确认违规必须填写治理原因（写入 delete_reason），食堂内容还要选确认原因；
// 忽略不可撤回，需要二次确认。规则与 App 管理端一致，确认后由服务端按目标类型下架或隐藏内容。
function ReportRow({item:x,same}:{item:Entity;same:number}){
  const ui=useUI();
  const snapshot=reportSnapshot(x.target_snapshot),preview=reportPreview(x.target_type,snapshot);
  const note=reportNote(x.reason_code,x.reason),href=reportTargetHref(x.target_type,x.target_id,snapshot);
  const pending=(x.status||'pending')==='pending',level=pending?waitLevel(x.created_at):'';
  const canteen=canteenGovernanceReasons(x.target_type);
  const [mode,setMode]=useState<''|'ignore'|'handle'>('');
  const [reason,setReason]=useState(''),[code,setCode]=useState(canteen.some(([c])=>c===x.reason_code)?String(x.reason_code):''),[result,setResult]=useState('');
  const [busy,setBusy]=useState(false),[error,setError]=useState('');
  const reasonBox=useRef<HTMLTextAreaElement>(null);
  async function submit(status:'ignored'|'handled',e?:FormEvent){
    e?.preventDefault();if(busy)return;
    setBusy(true);setError('');
    try{
      const body=reportHandlePayload(x.target_type,{status,result,governanceReason:reason,confirmedReasonCode:code});
      await write(`/api/reports/${x.id}/handle`,body,'PUT');
      await ui.act(async()=>{},status==='handled'?`举报 #${x.id} 已确认违规并完成治理`:`已忽略举报 #${x.id}`);
    }catch(err){setError(errorText(err))}finally{setBusy(false)}
  }
  return <article className="panel admin-report">
    <div className="admin-report-title">
      <span className="tag danger">{reportReasonLabel(x.reason_code,x.reason)}</span>
      <b>{reportTargetLabel(x.target_type)} #{x.target_id}</b>
      <span className="admin-report-id">举报 #{x.id}</span>
      {same>1&&<span className={`tag ${same>=5?'danger':'warn'}`}>{same} 条待处理举报</span>}
      <span className="admin-report-status">
        {level&&<em className={`admin-wait ${level}`}>等待 {waitText(x.created_at)}</em>}
        <span className={`tag ${pending?'warn':x.status==='handled'?'brand':''}`}>{reportStatuses[x.status]||x.status||'待处理'}</span>
      </span>
    </div>
    <div className="admin-report-snapshot"><small>被举报内容快照</small>{preview?<p>{preview}</p>:<p className="is-empty">未保存被举报内容快照</p>}</div>
    {note&&<p className="admin-report-note">举报说明：{note}</p>}
    {(x.result||x.delete_reason)&&!pending&&<p className="admin-report-note">处理结果：{x.delete_reason||x.result}</p>}
    {mode==='handle'?<form className="admin-decide" onSubmit={e=>void submit('handled',e)}>
      <label className="field">治理原因（必填）<textarea ref={reasonBox} rows={3} required maxLength={500} disabled={busy} value={reason} onChange={e=>{setReason(e.target.value);setError('')}} placeholder="会作为处理依据告知内容发布者"/></label>
      <div className="admin-chips" aria-label="常用治理原因">{governanceReasonPresets(x.reason_code,x.reason).map(p=><button type="button" className="admin-chip" key={p} onClick={()=>{setReason(p);reasonBox.current?.focus()}}>{p}</button>)}</div>
      {canteen.length>0&&<label className="field">确认治理原因（食堂内容必选）<select required disabled={busy} value={code} onChange={e=>{setCode(e.target.value);setError('')}}><option value="" disabled>请选择</option>{canteen.map(([c,l])=><option key={c} value={c}>{l}</option>)}</select><small className="muted">处罚依据以管理员确认的原因为准，默认带入举报人选择。</small></label>}
      <label className="field">处理备注（可选）<input maxLength={500} disabled={busy} value={result} onChange={e=>setResult(e.target.value)} placeholder="仅记录在举报处理结果中"/></label>
      {same>1&&<small className="muted">同一内容的其余 {same-1} 条待处理举报会一并结案。</small>}
      {error&&<p className="field-error" role="alert">{error}</p>}
      <div className="admin-decide-foot"><button type="button" className="btn" disabled={busy} onClick={()=>{setMode('');setError('')}}>取消</button><button className="btn danger" disabled={busy}>{busy?'正在提交…':`确认违规并${x.target_type==='post'?'隐藏帖子':'下架内容'}`}</button></div>
    </form>
    :mode==='ignore'?<div className="admin-confirm" role="alert">
      <span>忽略后这条举报不能再处理，内容保持原样。确定忽略？</span>
      {error&&<p className="field-error">{error}</p>}
      <span className="admin-confirm-actions"><button className="btn" disabled={busy} onClick={()=>{setMode('');setError('')}}>取消</button><button className="btn primary" disabled={busy} onClick={()=>void submit('ignored')}>{busy?'正在提交…':'确定忽略'}</button></span>
    </div>
    :<div className="admin-report-foot">
      <small className="admin-report-meta">{x.reporter?.nickname?`${x.reporter.nickname} 举报 · `:''}<time dateTime={x.created_at}>{time(x.created_at)}</time></small>
      <span className="admin-report-actions">
        {href&&<Link className="btn" to={href} target="_blank" rel="noreferrer">查看原内容</Link>}
        {pending&&<><button className="btn" onClick={()=>setMode('ignore')}>忽略</button><button className="btn danger" onClick={()=>{setMode('handle');requestAnimationFrame(()=>reasonBox.current?.focus())}}>确认违规…</button></>}
      </span>
    </div>}
  </article>;
}
function Review({kind,item}:{kind:string;item:Entity}){
  const path=kind==='papers'?`/api/admin/exam-papers/${item.id}`:kind==='awards'?`/api/admin/competition-awards/verifications/${item.id}`:null;
  const q=useApi(path);
  if(path)return <QueryState query={q}><ReviewForm kind={kind} item={entity(q.data,'award','paper','data')}/></QueryState>;
  return <ReviewForm kind={kind} item={item}/>;
}
function ReviewForm({kind,item}:{kind:string;item:Entity}){
  const ui=useUI();
  const fields:Field[]=[...(kind==='papers'?paperFields(item):[]),
    {name:'decision',label:'处理决定',options:[['approve','通过'],['reject','驳回']]},
    {name:'reason',label:'处理说明',type:'textarea',required:true}];
  const summary=[item.title||item.name||item.competition_title,item.reason||item.description||item.award_name].filter(Boolean).join(' · ');
  return <><p className="details-text">{summary}</p>
    {kind==='papers'&&<a className="btn" href={`/api/exam-papers/${item.id}/preview`} target="_blank" rel="noreferrer">授权预览试卷</a>}
    {kind==='awards'&&(item.evidence_file_ids||[]).map((fileId:number)=><a className="btn" key={fileId} href={`/api/admin/competition-awards/verifications/${item.id}/evidence/${fileId}`} target="_blank" rel="noreferrer">核验材料 #{fileId}</a>)}
    <Form fields={fields} onSubmit={async data=>{
      let path='',body:Entity={reason:data.reason},method='POST';
      if(kind==='papers'){path=`/api/admin/exam-papers/${item.id}/${data.decision}`;body={reason:data.reason,course_name:data.course_name,academic_year:data.academic_year,semester:data.semester,exam_type:data.exam_type};}
      else if(kind==='awards')path=`/api/admin/competition-awards/verifications/${item.id}/${data.decision}`;
      else if(kind==='canteens'){path=`/api/canteens/${item.id}/${data.decision==='approve'?'approve':'pending'}`;method=data.decision==='approve'?'POST':'DELETE';}
      else if(kind==='teachers'){path=`/api/teachers/${item.id}/${data.decision==='approve'?'verify':'reject'}`;method=data.decision==='approve'?'PUT':'DELETE';}
      await write(path,body,method);await ui.act(async()=>{},'处理结果已保存');ui.close();
    }}/>
  </>;
}
