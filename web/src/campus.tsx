import {Link,useSearchParams} from 'react-router-dom';
import {query,rows,useApi,time,entity,asset} from './api';
import {Empty,Head,Icon,Pagination,QueryState,useUI} from './ui';
import {CampusMap} from './campus-map';

export function Campus(){
  const [params,setParams]=useSearchParams(),ui=useUI();
  const page=Number(params.get('page'))||1;
  const q=useApi(query('/api/campus/articles',{page,page_size:20,q:params.get('q')}));
  const map=`${import.meta.env.BASE_URL}assets/campus-map.png`;
  function search(value:string){setParams(value?{q:value}:{})}
  return <><Head title="校园服务" description="公告、校历、地图与公共信息"><button className="btn" onClick={()=>document.getElementById('campus-search')?.focus()}>搜索校园信息</button></Head>
    <div className="quick-grid">
      {[['file','校园公告',()=>search('')],['schedule','校历',()=>ui.open('学校校历',<SchoolCalendar/>)],['campus','校园地图',()=>ui.open('校园地图',<CampusMap/>)],['canteen','食堂',null]].map(([icon,label,action])=>action?<button className="quick" key={String(label)} onClick={action as ()=>void}><i><Icon name={String(icon)}/></i><span>{String(label)}</span></button>:<Link className="quick" to="/canteen" key={String(label)}><i><Icon name={String(icon)}/></i><span>{String(label)}</span></Link>)}
    </div>
    <form className="filter-row section" onSubmit={e=>{e.preventDefault();search(String(new FormData(e.currentTarget).get('q')||''))}}><input key={params.get('q')||''} id="campus-search" name="q" aria-label="搜索校园信息" defaultValue={params.get('q')||''} placeholder="搜索学校公告和公开服务信息"/><button className="btn">搜索</button></form>
    {params.get('q')&&<p className="source-line">在已同步的学校公开文章中搜索“{params.get('q')}”，联系方式和办理要求以原文为准。</p>}
    <div className="section two-col"><section className="panel"><div className="rail-title"><b>校园公告</b><span className="muted">学校公开来源</span></div><div className="rail-body"><QueryState query={q}>{rows(q.data).map(a=><Link className="notice-line" key={a.id} to={`/campus/${a.id}`}><b>{a.title}</b><p>{a.author_department} · {a.publish_date}</p></Link>)}{!rows(q.data).length&&<Empty title="没有找到相关公开信息"/>}<Pagination page={page} hasMore={q.data?.has_more||false} onChange={page=>{const next=new URLSearchParams(params);next.set('page',String(page));setParams(next)}}/></QueryState></div></section>
    <section className="panel panel-pad"><div className="section-head"><h2>校园地图</h2><button className="link-btn" onClick={()=>ui.open('校园地图',<CampusMap/>)}>放大查看</button></div><button className="campus-map-preview" aria-label="打开校园地图" onClick={()=>ui.open('校园地图',<CampusMap/>)}><img src={map} alt="沈阳理工大学校园地图"/></button></section></div>
  </>;
}
function SchoolCalendar(){const q=useApi('/api/campus-calendars/current'),d=entity(q.data,'calendar','data');return <QueryState query={q}><h3>{d.academic_year||'当前校历'}</h3><p>{d.description}</p>{(d.image_url||d.url)&&<a href={asset(d.image_url||d.url)} target="_blank" rel="noreferrer"><img className="full-width" src={asset(d.image_url||d.url)} alt="学校校历"/></a>}<p>{time(d.updated_at)}</p></QueryState>}
