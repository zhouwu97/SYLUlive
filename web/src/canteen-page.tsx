import {Link,useSearchParams} from 'react-router-dom';
import {asset,query,rows,useApi} from './api';
import {useAuth} from './auth';
import {Empty,Head,Pagination,QueryState,Tabs,useUI} from './ui';
import {CanteenContributions,DishDetail} from './canteen';

export function CanteenPage(){
  const [params,setParams]=useSearchParams(),auth=useAuth(),ui=useUI();
  const tab=params.get('tab')||'home',page=Number(params.get('page'))||1;
  const path=tab==='home'?'/api/canteens/home':tab==='ranking'?query('/api/canteens/rankings',{sort:params.get('sort')||'composite'}):tab==='stores'?query('/api/canteens',{q:params.get('q'),page,limit:20}):null;
  const q=useApi(path);
  function change(key:string,value:string){const next=new URLSearchParams(params);next.set(key,value);if(key!=='page')next.delete('page');setParams(next)}
  return <><Head title="食堂与菜品" description="食堂评分、菜品、排行与贡献"><button className="btn" onClick={()=>auth.requireUser()&&ui.open('我的点评',<MyReviews/>)}>我的点评</button><button className="btn primary" onClick={()=>change('tab','stores')}>＋ 写点评</button></Head>
    <Tabs tabs={[["home","食堂主页"],["stores","店铺菜品"],["ranking","食堂排行"],["mine","我的贡献"]]} value={tab} onChange={v=>change('tab',v)}/>
    {tab==='mine'?(auth.user?<CanteenContributions/>:<Empty title="登录后查看自己的贡献"><button className="btn" onClick={auth.login}>登录</button></Empty>):<>
      {tab==='stores'&&<form className="filter-row" onSubmit={e=>{e.preventDefault();change('q',String(new FormData(e.currentTarget).get('q')||''))}}><input name="q" aria-label="搜索食堂" defaultValue={params.get('q')||''} placeholder="搜索食堂或店铺"/><button className="btn">搜索</button></form>}
      {tab==='ranking'&&<div className="filter-row"><label>排行方式 <select value={params.get('sort')||'composite'} onChange={e=>change('sort',e.target.value)}><option value="composite">综合排行</option><option value="rating">评分</option><option value="review_count">点评数量</option></select></label><span className="muted">按服务端真实统计排序</span></div>}
      <QueryState query={q}>{tab==='home'?<>
        <div className="two-col"><section className="panel panel-pad"><span className="tag brand">综合推荐</span>{q.data?.hero?<><h2>{q.data.hero.canteen_name}</h2><p>{q.data.hero.location_area} · {q.data.hero.location_floor}</p><div className="metric">{Number(q.data.hero.average_star).toFixed(1)} <small>分</small></div><p>{q.data.hero.reason}</p><Link className="btn" to={`/canteen/${q.data.hero.canteen_id}`}>查看店铺与点评</Link></>:<Empty title="暂无足够的评价数据"/>}</section>
        <section className="panel panel-pad"><h3>今日热门</h3>{rows(q.data,'hot_dishes').map((d,i)=><button className="list-row" key={`hot:${d.id??''}:${d.canteen_id??''}:${d.name??''}:${i}`} onClick={()=>ui.open(d.name,<DishDetail canteenId={String(d.canteen_id)} id={d.id}/>)}><b>{d.name}</b><span>{d.canteen_name}</span></button>)}</section></div>
        <section className="section"><div className="section-head"><h2>今天吃什么</h2><button className="link-btn" onClick={()=>change('tab','stores')}>查看全部店铺</button></div><div className="dish-list">{rows(q.data,'feed').map((f,i)=><Link className="dish" key={`feed:${f.id??''}:${f.canteen_id??''}:${f.dish_name??''}:${i}`} to={`/canteen/${f.canteen_id}`}>{f.image&&<img src={asset(f.image)} alt=""/>}<div><h4>{f.dish_name||f.canteen_name}</h4><p>{f.reason||f.title}</p></div></Link>)}</div></section>
        <section className="section"><h2>最新点评</h2><div className="panel">{rows(q.data,'recent_reviews').map((r,i)=><Link className="list-row" key={`review:${r.id??''}:${r.canteen_id??''}:${r.created_at??''}:${i}`} to={`/canteen/${r.canteen_id}`}><div><b>{r.user_name||r.canteen_name}</b><p>{r.comment}</p></div><span>{r.overall_score} 分</span></Link>)}</div></section>
      </>:<><div className="panel">{rows(q.data,'canteens').map((c,i)=><Link className="list-row" to={`/canteen/${c.id}`} key={`canteen:${c.id??''}:${c.name??''}:${i}`}>{tab==='ranking'&&<span className="rail-index">{c.rank||i+1}</span>}{c.image&&<img className="author-avatar" src={asset(c.image)} alt=""/>}<div className="list-main"><b>{c.name}</b><p>{c.location_area} {c.location_floor} · {c.description}</p></div><span className="tag">{c.rating_count?`${Number(c.average_star).toFixed(1)} 分`:'暂无评分'}</span></Link>)}</div>{!rows(q.data,'canteens').length&&<Empty/>}{tab==='stores'&&<Pagination page={page} hasMore={rows(q.data,'canteens').length===20} onChange={n=>change('page',String(n))}/>}</>}
      </QueryState></>}
  </>;
}
function MyReviews(){const q=useApi('/api/user/canteen-reviews');return <QueryState query={q}>{rows(q.data).map(r=><Link className="list-row" key={`${r.source}:${r.id}`} to={`/canteen/${r.canteen_id}`}><div><b>{r.canteen_name||'食堂评价'}</b><p>{r.comment}</p></div><span>{r.overall_score} 分</span></Link>)}{!rows(q.data).length&&<Empty title="暂无点评"/>}</QueryState>}
