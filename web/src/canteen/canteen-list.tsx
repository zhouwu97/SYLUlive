import {useState} from 'react';
import {Link} from 'react-router-dom';
import {asset,type Entity} from '../api';
import {formatScore} from './canteen-data';
import {Icon} from '../ui';
import './canteen-list.css';

const ranked=(c:Entity)=>typeof c.ranked==='boolean'?c.ranked:Number(c.rating_count)>0;
const place=(c:Entity)=>[c.location_area,c.location_floor].filter(Boolean).join(' · ');
function Cover({item}:{item:Entity}){
  const url=asset(item.image),[failed,setFailed]=useState('');
  return <span className="canteen-list-cover">{url&&failed!==url?<img src={url} alt={`${item.name}店铺实景`} loading="lazy" onError={()=>setFailed(url)}/>:<span className="canteen-list-fallback"><Icon name="canteen" size={30}/><small>{url?'实拍暂不可用':'暂无店铺实拍'}</small></span>}</span>;
}
function Score({item}:{item:Entity}){
  const count=Number(item.rating_count)||0;
  return <span className="canteen-list-score">{count>0?<><span><i>★</i><b>{formatScore(item.average_star)}</b><small>/ 5</small></span><small>{count} 人评分</small></>:<small>等待第一份评价</small>}</span>;
}
function Tags({item}:{item:Entity}){
  const tags=Array.isArray(item.summary_tags)?item.summary_tags.map((t:Entity)=>t?.name).filter(Boolean).slice(0,2):[];
  return <span className="canteen-list-tags">{tags.map((tag:string)=><span key={tag}>{tag}</span>)}{Number(item.dish_count)>0&&<span className="plain">{item.dish_count} 道菜品</span>}</span>;
}
export function CanteenList({items,ranking=false,sort='composite',showHeading=true,archived=false}:{items:Entity[];ranking?:boolean;sort?:string;showHeading?:boolean;archived?:boolean}){
  if(!items.length)return null;
  const podium=ranking&&sort!=='rating'?items.filter((c,i)=>ranked(c)&&(Number(c.rank)||i+1)<=3):[];
  const remaining=items.filter(c=>!podium.includes(c));
  return <section className={`canteen-discovery${ranking?' is-ranking':''}`} aria-label={ranking?'食堂榜单':'店铺列表'}>
    {showHeading&&<div className="canteen-list-heading"><h2>{ranking?(sort==='rating'?'低分关注榜':sort==='review_count'?'点评人气榜':'食堂口碑榜'):archived?'已下架存档':'全部营业店铺'}</h2><span className="canteen-list-total">本页 <b>{items.length}</b> 家</span></div>}
    {podium.length>0&&<div className="canteen-podium">{podium.map((c,i)=>{
      const rank=Number(c.rank)||i+1;
      return <Link className={`canteen-podium-card podium-${rank}`} key={c.id} to={`/canteen/${c.id}`}>
        <span className="canteen-podium-media"><Cover item={c}/><span className="canteen-podium-rank"><span aria-label={`第${rank}名`}>{rank}</span><small>{sort==='review_count'?'点评人气':'综合排名'}</small></span></span>
        <span className="canteen-podium-body"><b>{c.name}</b><small><Icon name="campus" size={13}/>{place(c)||'校园食堂'}</small><Tags item={c}/><span className="canteen-podium-bottom"><Score item={c}/><span className="canteen-list-go" aria-hidden="true"><Icon name="arrow" size={18}/></span></span></span>
      </Link>;
    })}</div>}
    {remaining.length>0&&<div className={ranking?'canteen-ranked-list':'canteen-store-grid'}>{remaining.map((c,i)=>{
      const rank=Number(c.rank)||items.indexOf(c)+1,isRanked=ranked(c),offline=c.is_offline===true||c.operating_status==='offline';
      return <Link className={ranking?'canteen-ranked-row':'canteen-store-card'} key={`${c.id}:${i}`} to={`/canteen/${c.id}`}>
        {ranking&&<span className="canteen-list-rank" aria-label={isRanked?`第${rank}名`:'暂无评价，不参与排名'}>{isRanked?String(rank).padStart(2,'0'):'—'}</span>}
        <Cover item={c}/>
        <span className="canteen-list-body"><span className="canteen-list-name"><b>{c.name}</b>{offline&&<span className="tag">已下架</span>}</span><small className="canteen-list-place"><Icon name="campus" size={14}/>{place(c)||'校园食堂'}</small>{c.description&&<span className="canteen-list-description">{c.description}</span>}<Tags item={c}/></span>
        <span className="canteen-list-bottom"><Score item={c}/><span className="canteen-list-go" aria-hidden="true"><Icon name="arrow" size={18}/></span></span>
      </Link>;
    })}</div>}
    {ranking&&<p className="canteen-ranking-note"><Icon name="info" size={15}/>仅营业店铺参与排行；没有评价的店铺不占名次。{sort==='composite'?'综合排行不等同于平均分排序。':''}</p>}
  </section>;
}
