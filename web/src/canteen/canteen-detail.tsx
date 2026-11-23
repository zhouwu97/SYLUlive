import {useState, type CSSProperties} from 'react';
import {Link, useParams} from 'react-router-dom';
import {asset, entity, rows, useApi, type Entity} from '../api';
import {useAuth} from '../auth';
import {CanteenArchiveManagement, CanteenDetailActions, CanteenReviewForm, CanteenReviews, DishDetail, OFFLINE_READONLY_TEXT} from './canteen';
import {formatScore} from './canteen-data';
import {MediaGallery} from '../media';
import {Empty, Icon, QueryState, useUI} from '../ui';
import './canteen-detail.css';
import {CanteenManagement} from './canteen-management';

const dimensions = [['taste', '口味'], ['value', '性价比'], ['queue', '排队体验'], ['hygiene', '卫生'], ['service', '服务']] as const;

function DishImage({src, name}:{src:unknown; name:string}) {
  const url = asset(src), [failed, setFailed] = useState('');
  return <span className="canteen-dish-cover">{url && failed !== url
    ? <img key={url} src={url} alt={`${name}实拍`} loading="lazy" onError={()=>setFailed(url)}/>
    : <span className="canteen-image-fallback"><Icon name="canteen" size={28}/><small>{url?'实拍暂不可用':'暂无实拍'}</small></span>}
  </span>;
}

export function CanteenDetailPage() {
  const {id = ''} = useParams(), auth = useAuth(), ui = useUI();
  const detail = useApi(`/api/canteens/${encodeURIComponent(id)}`);
  const dishes = useApi(`/api/canteens/${encodeURIComponent(id)}/dishes`);
  const shop = entity(detail.data, 'canteen'), data = detail.data || {};
  const offline = shop.is_offline === true || shop.operating_status === 'offline';
  const count = Number(data.reviewer_count ?? data.rating_count ?? shop.rating_count) || 0;
  const visits = Number(data.visit_review_count) || 0;
  const average = data.average_star ?? shop.average_star;
  const scores = (data.dimension_scores || shop.dimension_scores || {}) as Entity;
  const dishItems = rows(dishes.data, 'dishes');
  const location = [shop.location_area, shop.location_floor].filter(Boolean).join(' · ');
  const hasDimensions = dimensions.some(([key])=>Number(scores[key])>0);
  function compose() {
    if(auth.requireUser())ui.open('发表评价', <CanteenReviewForm id={id} onSaved={()=>void detail.refetch()}/>);
  }
  return <div className="canteen-detail-page">
    <nav className="canteen-detail-back" aria-label="食堂导航"><Link to={offline?'/canteen?tab=nostalgia':'/canteen'}><Icon name="arrow" size={17}/>返回列表</Link><span>/</span><span>{offline?'怀旧食堂':'店铺详情'}</span></nav>
    <QueryState query={detail}>
      {detail.data && <>
        <section className={`canteen-detail-hero${offline?' is-offline':''}`} aria-label="店铺概览">
          <div className="canteen-detail-cover">{shop.image
            ? <MediaGallery items={[{url:shop.image}]} title={`${shop.name}店铺封面`} maxVisible={1} variant="detail"/>
            : <div className="canteen-image-fallback"><Icon name="canteen" size={48}/><span>暂无店铺封面</span></div>}
            <span className="canteen-cover-caption"><Icon name="image" size={14}/>店铺实景</span>
          </div>
          <div className="canteen-detail-overview">
            {offline&&<span className="canteen-detail-badge"><Icon name="clock" size={14}/>怀旧存档 · 已下架</span>}
            <h1>{shop.name || '食堂详情'}</h1>
            <p className="canteen-detail-location"><Icon name="campus" size={16}/>{location || '位置暂未设置'}</p>
            <div className="canteen-detail-rating">
              <strong>{count>0?formatScore(average):'—'}</strong>
              <div><span className="canteen-detail-stars" aria-hidden="true" style={{'--fill':`${Math.max(0,Math.min(5,Number(average)||0))*20}%`} as CSSProperties}/><span>{count>0?`${count} 人评分`:'暂时还没有评分'}{visits>0?` · ${visits} 条就餐评价`:''}</span></div>
            </div>
            {hasDimensions?<dl className="canteen-detail-dimensions" aria-label="分项评分">{dimensions.map(([key,label])=><div key={key}><dt>{label}</dt><dd><span style={{width:`${Math.max(0,Math.min(5,Number(scores[key])||0))*20}%`}}/></dd><b>{formatScore(scores[key])}</b></div>)}</dl>:<p className="canteen-detail-muted">分项评分会在有足够评价后展示</p>}
            {shop.description&&<p className="canteen-detail-description">{shop.description}</p>}
            <div className="canteen-detail-actions">
              {!offline&&<button className="btn primary" onClick={compose}><Icon name="edit" size={16}/>发表评价</button>}
              <CanteenDetailActions key={`${id}:${auth.user?.id??'guest'}`} id={id} name={String(shop.name||'食堂')} favorite={data.is_favorite===true}/>
              {offline&&<CanteenArchiveManagement id={id} item={shop} onSaved={()=>void detail.refetch()}/>}
              <CanteenManagement id={id} item={shop} onSaved={()=>void detail.refetch()}/>
            </div>
          </div>
        </section>
        {offline&&<div className="canteen-detail-notice"><Icon name="clock" size={18}/><div><b>已下架只读存档</b><p>{OFFLINE_READONLY_TEXT}{shop.offline_reason?`下架原因：${shop.offline_reason}`:''}</p></div></div>}
        <div className="canteen-detail-columns">
          <section className="canteen-detail-reviews" aria-labelledby="canteen-reviews-title">
            <div className="canteen-detail-section-head"><h2 id="canteen-reviews-title">就餐评价</h2>{!offline&&<button className="link-btn" onClick={compose}>写评价<Icon name="edit" size={14}/></button>}</div>
            <CanteenReviews key={`${id}:${auth.user?.id??'guest'}`} id={id} offline={offline}/>
          </section>
          <section className={`canteen-detail-dishes${dishItems.length?'':' is-empty'}`} aria-labelledby="canteen-dishes-title">
            <div className="canteen-detail-section-head"><h2 id="canteen-dishes-title">店铺菜品</h2>{!dishes.isPending&&!dishes.error&&<span className="canteen-dish-count">{dishItems.length} 道</span>}</div>
            <QueryState query={dishes}>
              {dishItems.length?<div className="canteen-detail-dish-list">{dishItems.map(dish=><button type="button" className="canteen-detail-dish" key={dish.id} onClick={()=>ui.open(dish.name,<DishDetail key={`${id}:${dish.id}`} canteenId={id} id={dish.id}/>)} aria-label={`查看菜品 ${dish.name}`}>
                <DishImage src={dish.cover_image||dish.image} name={dish.name}/>
                <span className="canteen-dish-copy"><b>{dish.name}</b><span>{Number(dish.average_score||dish.average_star)>0?<><i>★</i> {formatScore(dish.average_score||dish.average_star)} 分</>:'暂无评分'}{Number(dish.photo_count)>0?` · ${dish.photo_count} 张实拍`:''}</span></span><Icon name="chevron" size={16}/>
              </button>)}</div>:<Empty icon="canteen" title="还没有菜品实拍" description={offline?'历史菜品会保留在这里。':'同学在评价里分享的菜品实拍会出现在这里。'}/>}
            </QueryState>
          </section>
        </div>
      </>}
    </QueryState>
  </div>;
}
