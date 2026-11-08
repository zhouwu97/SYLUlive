import type {CSSProperties} from 'react';
import {Link,useSearchParams} from 'react-router-dom';
import {asset,query,rows,useApi,type Entity} from './api';
import {useAuth} from './auth';
import {useMobile} from './mobile';
import {ServerAvatar} from './server-avatar';
import {Empty,Head,Icon,Pagination,QueryState,Tabs,useUI} from './ui';
import {CanteenContributions,DishDetail} from './canteen';
import {formatScore} from './canteen-data';

const DIMENSIONS=[['taste','口味'],['value','性价比'],['queue','排队'],['hygiene','卫生'],['service','服务']] as const;
const shortTime=(value:unknown)=>typeof value==='string'&&Number.isFinite(Date.parse(value))?new Date(value).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}):'';
const place=(item:Entity)=>[item.location_area,item.location_floor].filter(Boolean).join(' · ');

function Stars({value}:{value:unknown}){
  const n=Math.max(0,Math.min(5,Number(value)||0));
  return <span className="food-stars" style={{'--fill':`${n/5*100}%`} as CSSProperties} aria-hidden="true"/>;
}

export function CanteenPage(){
  const [params,setParams]=useSearchParams(),auth=useAuth(),ui=useUI(),mobile=useMobile();
  const tab=params.get('tab')||'home',page=Number(params.get('page'))||1;
  const path=tab==='home'?'/api/canteens/home':tab==='ranking'?query('/api/canteens/rankings',{sort:params.get('sort')||'composite'}):tab==='stores'?query('/api/canteens',{q:params.get('q'),page,limit:20}):null;
  const q=useApi(path);
  function change(key:string,value:string){const next=new URLSearchParams(params);next.set(key,value);if(key!=='page')next.delete('page');setParams(next)}
  return <div className={mobile?undefined:'food-page'}><Head title="食堂与菜品" description="食堂评分、菜品、排行与贡献"><button className="btn" onClick={()=>auth.requireUser()&&ui.open('我的点评',<MyReviews/>)}>我的点评</button><button className="btn primary" onClick={()=>change('tab','stores')}>＋ 写点评</button></Head>
    <Tabs tabs={[["home","食堂主页"],["stores","店铺菜品"],["ranking","食堂排行"],["mine","我的贡献"]]} value={tab} onChange={v=>change('tab',v)}/>
    {tab==='mine'?(auth.user?<CanteenContributions/>:<Empty icon="lock" title="登录后查看自己的贡献"><button className="btn" onClick={auth.login}>登录</button></Empty>):<>
      {tab==='stores'&&<form className="filter-row" onSubmit={e=>{e.preventDefault();change('q',String(new FormData(e.currentTarget).get('q')||''))}}><input name="q" aria-label="搜索食堂" defaultValue={params.get('q')||''} placeholder="搜索食堂或店铺"/><button className="btn">搜索</button></form>}
      {tab==='ranking'&&<div className="filter-row"><label>排行方式 <select value={params.get('sort')||'composite'} onChange={e=>change('sort',e.target.value)}><option value="composite">综合排行</option><option value="rating">评分</option><option value="review_count">点评数量</option></select></label><span className="muted">按服务端真实统计排序</span></div>}
      <QueryState query={q}>{tab==='home'?(mobile?<MobileHome data={q.data} change={change}/>:<DesktopHome data={q.data} change={change}/>)
      :<>{mobile?<div className="panel">{rows(q.data,'canteens').map((c,i)=><Link className="list-row" to={`/canteen/${c.id}`} key={`canteen:${c.id??''}:${c.name??''}:${i}`}>{tab==='ranking'&&<span className="rail-index">{c.rank||i+1}</span>}{c.image&&<img className="author-avatar" src={asset(c.image)} alt=""/>}<div className="list-main"><b>{c.name}</b><p>{c.location_area} {c.location_floor} · {c.description}</p></div><span className="tag">{c.rating_count?`${formatScore(c.average_star)} 分`:'暂无评分'}</span></Link>)}</div>
        :<StoreList items={rows(q.data,'canteens')} ranking={tab==='ranking'}/>}
        {!rows(q.data,'canteens').length&&<Empty/>}{tab==='stores'&&<Pagination page={page} hasMore={rows(q.data,'canteens').length===20} onChange={n=>change('page',String(n))}/>}</>}
      </QueryState></>}
  </div>;
}

type HomeProps={data:Entity|undefined;change:(key:string,value:string)=>void};

/** 手机端对照 App，保持原有结构。 */
function MobileHome({data,change}:HomeProps){
  const ui=useUI();
  return <>
    <div className="two-col"><section className="panel panel-pad"><span className="tag brand">综合推荐</span>{data?.hero?<><h2>{data.hero.canteen_name}</h2><p>{data.hero.location_area} · {data.hero.location_floor}</p><div className="metric">{formatScore(data.hero.average_star)} <small>分</small></div><p>{data.hero.reason}</p><Link className="btn" to={`/canteen/${data.hero.canteen_id}`}>查看店铺与点评</Link></>:<Empty title="暂无足够的评价数据"/>}</section>
    <section className="panel panel-pad"><h3>今日热门</h3>{rows(data,'hot_dishes').map((d,i)=><button className="list-row" key={`hot:${d.id??''}:${d.canteen_id??''}:${d.name??''}:${i}`} onClick={()=>ui.open(d.name,<DishDetail canteenId={String(d.canteen_id)} id={d.id}/>)}><b>{d.name}</b><span>{d.canteen_name}</span></button>)}</section></div>
    <section className="section"><div className="section-head"><h2>今天吃什么</h2><button className="link-btn" onClick={()=>change('tab','stores')}>查看全部店铺</button></div><div className="dish-list">{rows(data,'feed').map((f,i)=><Link className="dish" key={`feed:${f.id??''}:${f.canteen_id??''}:${f.dish_name??''}:${i}`} to={`/canteen/${f.canteen_id}`}>{f.image&&<img src={asset(f.image)} alt=""/>}<div><h4>{f.dish_name||f.canteen_name}</h4><p>{f.reason||f.title}</p></div></Link>)}</div></section>
    <section className="section"><h2>最新点评</h2><div className="panel">{rows(data,'recent_reviews').map((r,i)=><Link className="list-row" key={`review:${r.id??''}:${r.canteen_id??''}:${r.created_at??''}:${i}`} to={`/canteen/${r.canteen_id}`}><div><b>{r.user_name||r.canteen_name}</b><p>{r.comment}</p></div><span>{formatScore(r.overall_score)} 分</span></Link>)}</div></section>
  </>;
}

/** 桌面食堂主页：推荐店铺大卡 + 今日热门榜，下方实拍卡片流与点评卡片。 */
function DesktopHome({data,change}:HomeProps){
  const ui=useUI();
  const hero=data?.hero as Entity|undefined;
  const hot=rows(data,'hot_dishes'),feed=rows(data,'feed'),reviews=rows(data,'recent_reviews');
  const total=Number(data?.ranking_entry?.total)||0;
  const dims=hero?.dimension_scores as Record<string,number>|undefined;
  // 推荐理由与评分行重复时（「真实评分 4.7 · 9 人评价」）不再单列
  const reason=typeof hero?.reason==='string'&&!hero.reason.startsWith('真实评分')?hero.reason:'';
  return <div className="food-home">
    <div className="food-top">
      <section className="panel food-hero" aria-label="综合推荐">
        {hero?<>
          <Link className="food-hero-media" to={`/canteen/${hero.canteen_id}`} tabIndex={-1} aria-hidden="true">
            {hero.image?<img src={asset(hero.image)} alt="" loading="lazy"/>:<span className="food-media-empty"><Icon name="canteen" size={40}/></span>}
          </Link>
          <div className="food-hero-body">
            <span className="food-badge"><Icon name="trending" size={14}/>综合推荐{total>0?` · 排行第 1 / ${total}`:''}</span>
            <h2>{hero.canteen_name}</h2>
            {place(hero)&&<p className="food-place"><Icon name="campus" size={15}/>{place(hero)}</p>}
            <div className="food-hero-score">
              <b>{formatScore(hero.average_star)}</b>
              <div><Stars value={hero.average_star}/><small>{hero.rating_count||0} 人评分{hero.visit_review_count?` · ${hero.visit_review_count} 条就餐点评`:''}</small></div>
            </div>
            {reason&&<p className="food-reason">{reason}</p>}
            {dims&&<dl className="food-dims">{DIMENSIONS.filter(([key])=>dims[key]!=null).map(([key,label])=><div key={key}>
              <dt>{label}</dt><dd><span style={{'--v':`${Math.min(5,Number(dims[key])||0)/5*100}%`} as CSSProperties}/></dd><b>{formatScore(dims[key])}</b>
            </div>)}</dl>}
            <div className="food-hero-actions">
              <Link className="btn primary" to={`/canteen/${hero.canteen_id}`}>查看店铺与点评</Link>
              {total>0&&<button className="btn" onClick={()=>change('tab','ranking')}>查看全部 {total} 家排行</button>}
            </div>
          </div>
        </>:<Empty title="暂无足够的评价数据"/>}
      </section>
      <section className="panel food-hot" aria-labelledby="food-hot-title">
        <div className="food-card-head"><h3 id="food-hot-title">今日热门</h3><small>来自同学的实拍与评价</small></div>
        {hot.length?<ol>{hot.map((d,i)=><li key={`hot:${d.id??''}:${d.canteen_id??''}:${d.name??''}:${i}`}>
          <button type="button" className="food-hot-item" onClick={()=>ui.open(d.name,<DishDetail canteenId={String(d.canteen_id)} id={d.id}/>)}>
            <span className={`food-rank${i<3?` top-${i+1}`:''}`}>{i+1}</span>
            <span className="food-thumb">{d.cover_image?<img src={asset(d.cover_image)} alt="" loading="lazy"/>:<Icon name="canteen" size={20}/>}</span>
            <span className="food-hot-copy"><b>{d.name}</b>{d.canteen_name&&d.canteen_name!==d.name&&<small>{d.canteen_name}</small>}</span>
            <span className="food-chip">{Number(d.average_score)>0?<><i aria-hidden="true">★</i>{formatScore(d.average_score)}</>:`${d.photo_count||0} 张实拍`}</span>
          </button>
        </li>)}</ol>:<p className="food-muted">今天还没有热门菜品</p>}
      </section>
    </div>

    <section className="section food-section">
      <div className="section-head"><h2>今天吃什么</h2><button className="link-btn" onClick={()=>change('tab','stores')}>查看全部店铺<Icon name="chevron" size={14}/></button></div>
      {feed.length?<div className="food-feed">{feed.map((f,i)=>{
        const image=f.image||(Array.isArray(f.images)?f.images[0]:undefined);
        const tags=Array.isArray(f.tags)?f.tags.filter((tag:unknown):tag is string=>typeof tag==='string').slice(0,3):[];
        return <Link className="food-card" key={`feed:${f.id??''}:${f.canteen_id??''}:${f.dish_name??''}:${i}`} to={`/canteen/${f.canteen_id}`}>
          <span className="food-card-media">{image?<img src={asset(image)} alt="" loading="lazy"/>:<span className="food-media-empty"><Icon name="canteen" size={32}/></span>}{f.title&&<span className="food-card-kind">{f.title}</span>}</span>
          <span className="food-card-body">
            <b>{f.dish_name||f.canteen_name}</b>
            {f.dish_name&&f.canteen_name?<small>{f.canteen_name}</small>:place(f)&&<small>{place(f)}</small>}
            {f.type==='recommended_store'&&Number(f.average_star)>0?<span className="food-card-score"><Stars value={f.average_star}/>{formatScore(f.average_star)}<small>· {f.rating_count||0} 人</small></span>:f.reason&&<span className="food-card-reason">{f.reason}</span>}
            {tags.length>0&&<span className="food-tags">{tags.map((tag:string)=><span key={tag}>{tag}</span>)}</span>}
          </span>
        </Link>;
      })}</div>:<Empty title="暂时没有推荐"/>}
    </section>

    <section className="section food-section">
      <div className="section-head"><h2>最新点评</h2>{Number(data?.recent_effective_review_count)>0&&<small className="food-muted">近期 {data!.recent_effective_review_count} 条有效点评</small>}</div>
      {reviews.length?<div className="food-reviews">{reviews.map((r,i)=><Link className="food-review" key={`review:${r.review_id??r.id??''}:${r.canteen_id??''}:${r.created_at??''}:${i}`} to={`/canteen/${r.canteen_id}`}>
        <span className="food-review-head">
          <span className="food-review-avatar"><ServerAvatar src={r.user_avatar} name={r.user_name||'同学'}/></span>
          <span className="food-review-who"><b>{r.user_name||'同学'}</b><small>{shortTime(r.created_at)}</small></span>
          <span className="food-review-score"><i aria-hidden="true">★</i>{formatScore(r.overall_score)}</span>
        </span>
        <span className="food-review-store"><Icon name="canteen" size={14}/>{r.canteen_name}</span>
        <span className="food-review-text">{r.comment}</span>
      </Link>)}</div>:<Empty title="暂无点评"/>}
    </section>
  </div>;
}

function StoreList({items,ranking}:{items:Entity[];ranking:boolean}){
  if(!items.length)return null;
  return <div className="panel food-stores">{items.map((c,i)=>{
    const rank=Number(c.rank)||i+1;
    const tags=Array.isArray(c.summary_tags)?c.summary_tags.map((tag:Entity)=>tag?.name).filter(Boolean).slice(0,3):[];
    return <Link className="food-store" to={`/canteen/${c.id}`} key={`canteen:${c.id??''}:${c.name??''}:${i}`}>
      {ranking&&<span className={`food-rank${rank<=3?` top-${rank}`:''}`}>{rank}</span>}
      <span className="food-thumb large">{c.image?<img src={asset(c.image)} alt="" loading="lazy"/>:<Icon name="canteen" size={24}/>}</span>
      <span className="food-store-main">
        <b>{c.name}</b>
        <small>{[place(c),c.description].filter(Boolean).join(' · ')||'校园食堂'}</small>
        {(tags.length>0||Number(c.dish_count)>0)&&<span className="food-tags">{tags.map((tag:string)=><span key={tag}>{tag}</span>)}{Number(c.dish_count)>0&&<span className="plain">{c.dish_count} 道菜品</span>}</span>}
      </span>
      <span className="food-store-score">{c.rating_count?<><b>{formatScore(c.average_star)}</b><Stars value={c.average_star}/><small>{c.rating_count} 人评分</small></>:<small>暂无评分</small>}</span>
    </Link>;
  })}</div>;
}

function MyReviews(){const q=useApi('/api/user/canteen-reviews');return <QueryState query={q}>{rows(q.data).map(r=><Link className="list-row" key={`${r.source}:${r.id}`} to={`/canteen/${r.canteen_id}`}><div><b>{r.canteen_name||'食堂评价'}</b><p>{r.comment}</p></div><span>{formatScore(r.overall_score)} 分</span></Link>)}{!rows(q.data).length&&<Empty title="暂无点评"/>}</QueryState>}
