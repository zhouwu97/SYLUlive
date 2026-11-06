import {Link,useSearchParams} from 'react-router-dom';
import {query,rows,useApi,time,entity,asset} from './api';
import {Empty,Head,Icon,Pagination,QueryState,useUI} from './ui';
import {CampusMap} from './campus-map';
import { mobileTermLabel, useMobile } from './mobile';
import { useAcademic } from './academic';

export function Campus(){
  const mobile = useMobile();
  const [params] = useSearchParams();
  return mobile && params.get('view') !== 'articles' ? <MobileCampus /> : <DesktopCampus />;
}
function DesktopCampus(){
  const [params,setParams]=useSearchParams(),ui=useUI();
  const page=Number(params.get('page'))||1;
  const q=useApi(query('/api/campus/articles',{page,page_size:20,q:params.get('q')}));
  const map=`${import.meta.env.BASE_URL}assets/campus-map.png`;
  function search(value:string){setParams(value?{q:value}:{})}
  return <><Head title="校园服务" description="公告、校历、地图与公共信息"><button className="btn" onClick={()=>document.getElementById('campus-search')?.focus()}>搜索校园信息</button></Head>
    <div className="quick-grid">
      {[['file','校园公告',()=>search('')],['schedule','校历',()=>ui.open('学校校历',<SchoolCalendar/>)],['campus','校园地图',()=>ui.open('校园地图',<CampusMap/>)],['canteen','食堂',null]].map(([icon,label,action])=>action?<button className="quick" key={String(label)} onClick={action as ()=>void}><i><Icon name={String(icon)}/></i><span>{String(label)}</span></button>:<Link className="quick" to="/canteen" key={String(label)}><i><Icon name={String(icon)}/></i><span>{String(label)}</span></Link>)}
    </div>
    <form className="filter-row section campus-search" onSubmit={e=>{e.preventDefault();search(String(new FormData(e.currentTarget).get('q')||''))}}><input key={params.get('q')||''} id="campus-search" name="q" aria-label="搜索校园信息" defaultValue={params.get('q')||''} placeholder="搜索学校公告和公开服务信息"/><button className="btn">搜索</button></form>
    {params.get('q')&&<p className="source-line">在已同步的学校公开文章中搜索“{params.get('q')}”，联系方式和办理要求以原文为准。</p>}
    <div className="section two-col"><section className="panel campus-notices"><div className="rail-title"><b>校园公告</b><span className="muted">学校公开来源</span></div><div className="rail-body"><QueryState query={q}>{rows(q.data).map(a=><Link className="notice-line" key={a.id} to={`/campus/${a.id}`}><b>{a.title}</b><p>{a.author_department} · {a.publish_date}</p></Link>)}{!rows(q.data).length&&<Empty title="没有找到相关公开信息"/>}<Pagination page={page} hasMore={q.data?.has_more||false} onChange={page=>{const next=new URLSearchParams(params);next.set('page',String(page));setParams(next)}}/></QueryState></div></section>
    <section className="panel panel-pad"><div className="section-head"><h2>校园地图</h2><button className="link-btn" onClick={()=>ui.open('校园地图',<CampusMap/>)}>放大查看</button></div><button className="campus-map-preview" aria-label="打开校园地图" onClick={()=>ui.open('校园地图',<CampusMap/>)}><img src={map} alt="沈阳理工大学校园地图"/></button></section></div>
  </>;
}
function MobileCampus() {
  const ui = useUI(), store = useAcademic();
  const q = useApi('/api/campus/articles?page=1&page_size=20');
  const articles = rows(q.data);
  const date = new Date();
  const openMap = () => ui.open('校园地图', <CampusMap />);
  const openCalendar = () => ui.open('学校校历', <SchoolCalendar />);
  return <div className="mobile-campus">
    <header className="mobile-campus-hero"><div><h1>校园</h1><p>{mobileTermLabel(store.data.term)}</p></div><button onClick={openCalendar}><b>校历</b><span>{date.toLocaleDateString('zh-CN', { month: '2-digit', day: '2-digit' })}</span></button></header>
    <QueryState query={q}>
      {articles[0] && <Link className="mobile-campus-notice featured" to={`/campus/${articles[0].id}`}><div><span>教务通知</span><time>{articles[0].publish_date?.slice(5, 10)}</time></div><h2>{articles[0].title}</h2><p>{articles[0].author_department || '学校公开信息'}<span aria-hidden="true">↗</span></p></Link>}
    </QueryState>
    <Link className="mobile-service-row mobile-agent-entry" to="/ai"><i><Icon name="ai" size={25} /></i><span><b>校园 Agent</b><small>帮你查信息、看安排、做计划</small></span><span aria-hidden="true">›</span></Link>
    <div className="mobile-section-title"><div><h2>校园服务</h2><p>常用校园功能</p></div></div>
    <nav className="mobile-campus-services" aria-label="校园服务">
      <Link to="/grades"><i><Icon name="grades" size={26} /></i><b>教务中心</b></Link>
      <Link to="/canteen"><i><Icon name="canteen" size={26} /></i><b>食堂</b></Link>
      <Link to="/ratings"><i><Icon name="ratings" size={26} /></i><b>校园榜单</b></Link>
      <Link to="/polls?tab=team"><i><Icon name="community" size={26} /></i><b>组队</b></Link>
      <button onClick={openMap}><i><Icon name="campus" size={26} /></i><b>校园地图</b></button>
      <button onClick={openCalendar}><i><Icon name="schedule" size={26} /></i><b>校历</b></button>
    </nav>
    <div className="mobile-section-title"><div><h2>校园资讯</h2><p>校园通知与赛事信息</p></div><Link className="btn" to="/competition">竞赛 <span aria-hidden="true">›</span></Link></div>
    <QueryState query={q}>
      {articles.slice(1).map(article => <Link className="mobile-campus-notice" key={article.id} to={`/campus/${article.id}`}><div><span>教务通知</span><time>{article.publish_date?.slice(5, 10)}</time></div><h2>{article.title}</h2><p>{article.author_department || '学校公开信息'}</p></Link>)}
      {!articles.length && <Empty title="暂时没有校园资讯" description="校园服务入口仍可使用。" />}
      {articles.length > 0 && <Link className="btn mobile-all-articles" to="/campus?view=articles">查看全部资讯与搜索</Link>}
    </QueryState>
  </div>;
}
function SchoolCalendar(){const q=useApi('/api/campus-calendars/current'),d=entity(q.data,'calendar','data');return <QueryState query={q}><h3>{d.academic_year||'当前校历'}</h3><p>{d.description}</p>{(d.image_url||d.url)&&<a href={asset(d.image_url||d.url)} target="_blank" rel="noreferrer"><img className="full-width" src={asset(d.image_url||d.url)} alt="学校校历"/></a>}<p>{time(d.updated_at)}</p></QueryState>}
