import {useState,type ReactNode} from 'react';
import {Link} from 'react-router-dom';
import {useQueryClient} from '@tanstack/react-query';
import {DISH_DIMENSIONS,MAX_REVIEW_DISHES,formatScore,preservedReviewData,readReviewDishes,reviewTime,stringList} from './canteen-data';
import {asset,entity,errorText,request,rows,useApi,write,type Entity} from './api';
import {useAuth} from './auth';
import {Empty,Form,QueryState,useUI,type Field} from './ui';

/** 1–5 分统一用下拉选择，避免数字框误输入；文案与 App 的分值按钮一致。 */
const SCORE_OPTIONS:[string,string][]=[['5','5 · 很满意'],['4','4 · 满意'],['3','3 · 一般'],['2','2 · 较差'],['1','1 · 很差']];
const DISH_SCORE_OPTIONS:[string,string][]=[['','不打分'],...SCORE_OPTIONS];
const VISIT_DIMENSIONS={taste_score:'口味',value_score:'性价比',queue_score:'排队体验',hygiene_score:'卫生',service_score:'服务'};
export const OFFLINE_READONLY_TEXT='该商家已下架，评价和图片仅供查看；如需修改或删除请联系管理员。';

function DishRows(){
  return <fieldset className="canteen-dish-rows">
    <legend>本次吃的菜品（可选，最多 {MAX_REVIEW_DISHES} 道，可分别打分）</legend>
    {Array.from({length:MAX_REVIEW_DISHES},(_,i)=>i+1).map(n=><div className="canteen-dish-row" key={n}>
      <label className="field">菜品 {n}<input name={`dish_name_${n}`} maxLength={40} placeholder={n===1?'例如：麻辣香锅':'可不填'}/></label>
      {DISH_DIMENSIONS.map(([key,label])=><label className="field" key={key}>{label}
        <select name={`dish_${key}_${n}`} defaultValue="">{DISH_SCORE_OPTIONS.map(([v,l])=><option key={v} value={v}>{l}</option>)}</select>
      </label>)}
    </div>)}
    <p className="muted">实拍会关联到第一道菜；不填菜品时作为就餐实拍展示。</p>
  </fieldset>;
}

export function CanteenReviewForm({id,item,onSaved}:{id:string;item?:Entity;onSaved?:()=>void}){
  const ui=useUI();
  const fields:Field[]=[
    ...Object.entries(VISIT_DIMENSIONS).map(([name,label])=>({name,label,options:SCORE_OPTIONS,required:true,value:String(item?.[name]||4)})),
    {name:'comment',label:'就餐体验（不超过 500 字）',type:'textarea',value:item?.comment,required:true},
    ...(!item?[{name:'images',label:'上传就餐或菜品实拍',type:'file',multiple:true,accept:'image/*'}]:[]),
  ];
  return <Form fields={fields} onSubmit={async(values,form)=>{
    const images:string[]=[],photoIds:number[]=[];
    const scores=Object.fromEntries(Object.keys(VISIT_DIMENSIONS).map(key=>[key,Number(values[key])]));
    // 先校验菜品，再上传图片，避免填错后白传图片。
    const dishes=item?[]:readReviewDishes(form,[]);
    if(!item)for(const file of form.getAll('images'))if(file instanceof File&&file.size){
      const body=new FormData();body.set('file',file);
      const result=await write('/api/upload',body);
      if(typeof result.url!=='string'||!Number.isInteger(result.file_id))throw new Error('上传未返回有效图片');
      images.push(result.url);photoIds.push(result.file_id);
    }
    if(dishes.length&&photoIds.length)dishes[0].photo_file_ids=photoIds;
    const data:Entity={...scores,comment:values.comment,...(item?preservedReviewData(item):{images,tags:[]}),...(!item&&dishes.length?{dishes}:{})};
    await write(item?`/api/canteens/reviews/${item.id}`:`/api/canteens/${id}/reviews`,data,item?'PATCH':'POST');
    await ui.act(async()=>{},'评价已保存，状态以服务器回读为准');
    onSaved?.();
    ui.close();
  }}>{!item&&<><DishRows/><p className="muted">新菜品与实拍随本次评价提交，是否展示以当前服务端规则为准。</p></>}</Form>;
}

function CanteenReviewEditor({id,reviewId,onSaved}:{id:string;reviewId:number;onSaved:()=>void}){
  const q=useApi(`/api/canteens/reviews/${reviewId}/edit-context`);
  return <QueryState query={q}>{q.data&&<CanteenReviewForm id={id} item={entity(q.data,'review')} onSaved={onSaved}/>}</QueryState>;
}

function ReviewScores({review}:{review:Entity}){
  const parts=Object.entries(VISIT_DIMENSIONS).filter(([key])=>Number(review[key])>0).map(([key,label])=>`${label} ${review[key]}`);
  return parts.length?<small className="muted canteen-review-dims">{parts.join(' · ')}</small>:null;
}

/** 店铺评价：按服务端游标分页；商家下架后只读，不再显示编辑和删除。 */
export function CanteenReviews({id,offline=false}:{id:string;offline?:boolean}){
  const first=useApi(`/api/canteens/${id}/reviews`),ui=useUI(),auth=useAuth(),qc=useQueryClient();
  const [more,setMore]=useState<Entity[]>([]),[cursor,setCursor]=useState<string|undefined>(),[loading,setLoading]=useState(false),[error,setError]=useState('');
  const nextCursor=cursor??(typeof first.data?.next_cursor==='string'?first.data.next_cursor:undefined);
  const items=[...rows(first.data,'reviews'),...more];
  async function refresh(){setMore([]);setCursor(undefined);await qc.invalidateQueries({queryKey:['api',`/api/canteens/${id}/reviews`]});}
  async function loadMore(){
    if(!nextCursor||loading)return;
    setLoading(true);setError('');
    try{
      const page=await request<Entity>(`/api/canteens/${id}/reviews?cursor=${encodeURIComponent(nextCursor)}`);
      setMore(prev=>[...prev,...rows(page,'reviews')]);
      setCursor(typeof page.next_cursor==='string'?page.next_cursor:'');
    }catch(err){setError(errorText(err))}finally{setLoading(false)}
  }
  return <QueryState query={first}>
    {offline&&<p className="notice">{OFFLINE_READONLY_TEXT}</p>}
    {items.map(r=><article className="comment-row" key={r.id||r.review_id}>
      <b>{r.user_name||r.user?.nickname||'同学'} · {formatScore(r.overall_score||r.star)} 分</b>
      <ReviewScores review={r}/>
      <p>{r.comment}</p>
      {stringList(r.recommended_dishes).length>0&&<p className="muted">吃了：{stringList(r.recommended_dishes).join('、')}</p>}
      <div className="post-images">{stringList(r.images).map((url:string)=><a key={url} href={asset(url)} target="_blank" rel="noreferrer"><img src={asset(url)} alt={`${r.user_name||'同学'}的就餐实拍`}/></a>)}</div>
      <small>{reviewTime(r)}</small>
      {!offline&&r.user_id===auth.user?.id&&<div className="form-actions">
        <button className="btn" onClick={()=>ui.open('编辑我的评价',<CanteenReviewEditor id={id} reviewId={r.id} onSaved={()=>void refresh()}/>)}>编辑</button>
        <button className="btn" onClick={()=>ui.open('删除评价',<><p>删除后这条评价、菜品打分和实拍都会撤下。</p><button className="btn" onClick={async()=>{if(await ui.act(()=>write(`/api/canteens/reviews/${r.id}`,{},'DELETE'),'评价已删除')){ui.close();await refresh();}}}>确认删除</button></>)}>删除</button>
      </div>}
    </article>)}
    {!items.length&&<Empty title="还没有就餐评价"/>}
    {error&&<p className="error" role="alert">{error}</p>}
    {nextCursor?<button className="btn" disabled={loading} aria-busy={loading} onClick={()=>void loadMore()}>{loading?'正在加载…':error?'重试加载更多':'加载更多评价'}</button>:null}
  </QueryState>;
}

/** 收藏与分享：未登录点收藏先登录；分享复制 Web 详情链接，复制失败时展示链接。 */
export function CanteenDetailActions({id,name,favorite}:{id:string;name:string;favorite:boolean}){
  const ui=useUI(),auth=useAuth(),qc=useQueryClient();
  const [state,setState]=useState<boolean|undefined>(),[busy,setBusy]=useState(false);
  const on=state??favorite;
  async function toggle(){
    if(!auth.requireUser()||busy)return;
    setBusy(true);
    try{
      await write(`/api/user/canteen-favorites/${id}`,{},on?'DELETE':'PUT');
      setState(!on);
      ui.notify(on?'已取消收藏':'已收藏，可在食堂主页“我常去”找到');
      void qc.invalidateQueries({queryKey:['api','/api/user/canteen-favorites']});
    }catch(err){ui.notify(errorText(err))}finally{setBusy(false)}
  }
  async function share(){
    const url=`${window.location.origin}/web/canteen/${id}`;
    try{await navigator.clipboard.writeText(`「${name}」来沈理校园看同学的真实评价：${url}`);ui.notify('商家链接已复制');}
    catch{ui.open('分享商家',<p className="details-text">{url}</p>);}
  }
  return <>
    <button className="btn" aria-pressed={on} disabled={busy} onClick={()=>void toggle()}>{on?'已收藏':'收藏'}</button>
    <button className="btn" onClick={()=>void share()}>分享</button>
  </>;
}

/** 首页“我常去”：只在登录后读取本人收藏，失败不影响主页其他内容。 */
export function CanteenFavorites({render}:{render:(items:Entity[])=>ReactNode}){
  const auth=useAuth();
  const q=useApi(auth.user?'/api/user/canteen-favorites':null);
  const items=rows(q.data);
  return auth.user&&items.length?<>{render(items)}</>:null;
}

const CONTRIBUTION_LABELS:Record<string,string>={canteen:'商家',dish:'菜品',dish_photo:'实拍',dish_review:'菜品评价',pending:'待审核',active:'已展示',approved:'已通过',rejected:'未通过',merged:'已合并',offline:'已下架'};

export function CanteenContributions(){
  const q=useApi('/api/user/canteen-contributions');
  const items=rows(q.data,'items');
  return <QueryState query={q}>{items.map((x,i)=><article className="list-row" key={`${x.type}:${x.canteen_id??''}:${x.dish_id??''}:${x.photo_id??''}:${i}`}>
    <div className="list-main"><b>{x.type==='canteen'?x.canteen_name:x.dish_name}</b><p>{x.type==='canteen'?'':`${x.canteen_name} · `}{CONTRIBUTION_LABELS[x.type]||x.type} · {CONTRIBUTION_LABELS[x.status]||x.status}</p>
      {x.reject_reason&&<p>{x.reject_reason}</p>}{x.merged_into_dish_name&&<p>已合并至：{x.merged_into_dish_name}</p>}
      {x.image&&<div className="post-images"><a href={asset(x.image)} target="_blank" rel="noreferrer"><img src={asset(x.image)} alt={`${x.dish_name||x.canteen_name}实拍`}/></a></div>}
      <small>{reviewTime({created_at:x.submitted_at})}</small>{x.canteen_id&&<Link to={`/canteen/${x.canteen_id}`}>查看食堂</Link>}
    </div></article>)}{!items.length&&<Empty title="暂无食堂贡献"/>}</QueryState>;
}

/** 菜品详情：实拍、三维评分与同学评价（含每条评价的菜品打分）。 */
export function DishDetail({canteenId,id}:{canteenId:string;id:number}){
  const q=useApi(`/api/canteens/${canteenId}/dishes/${id}`),reviews=useApi(`/api/canteens/dishes/${id}/reviews`);
  const d=entity(q.data,'dish'),scores=(q.data?.scores||{}) as Entity,rated=Number(q.data?.rated_count)||0;
  return <QueryState query={q}>
    <h3>{d.name}</h3>{d.canteen_name&&<p className="muted">{d.canteen_name}</p>}
    <p>{rated>0?<>综合 <b>{formatScore(scores.average)}</b> 分 · {DISH_DIMENSIONS.map(([key,label])=>`${label} ${formatScore(scores[key])}`).join(' · ')}（{rated} 人打分）</>:'还没有同学给这道菜打分'}</p>
    <div className="post-images">{rows(q.data,'photos').map(p=><img key={p.id} src={asset(p.image)} alt={`${d.name}实拍`}/>)}</div>
    <QueryState query={reviews}>{rows(reviews.data,'reviews').map(r=><div className="comment-row" key={`${r.review_source||''}:${r.id}`}>
      <b>{r.user_name||r.user?.nickname||'同学'}</b>
      {Number(r.portion_score)>0&&<small className="muted canteen-review-dims">{DISH_DIMENSIONS.map(([key,label])=>`${label} ${r[`${key}_score`]}`).join(' · ')}</small>}
      <p>{r.comment}</p><small>{reviewTime(r)}</small>
    </div>)}{!rows(reviews.data,'reviews').length&&<Empty title="还没有评价"/>}</QueryState>
  </QueryState>;
}
