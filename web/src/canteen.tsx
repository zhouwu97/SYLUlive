import {Link} from 'react-router-dom';
import {preservedReviewData,stringList} from './canteen-data';
import {asset,entity,rows,time,upload,useApi,write,type Entity} from './api';
import {useAuth} from './auth';
import {Empty,Form,QueryState,useUI,type Field} from './ui';
export function CanteenReviewForm({id,item}:{id:string;item?:Entity}){
  const ui=useUI();const fields:Field[]=[...Object.entries({taste_score:'口味',value_score:'性价比',queue_score:'排队体验',hygiene_score:'卫生',service_score:'服务'}).map(([name,label])=>({name,label:`${label}（1–5）`,type:'number',min:1,max:5,required:true,value:item?.[name]||3})),{name:'comment',label:'就餐体验（不超过 500 字）',type:'textarea',value:item?.comment,required:true},...(!item?[{name:'dish_name',label:'本次评价的菜品（可选，只填一道）'},{name:'images',label:'上传就餐或菜品实拍',type:'file',multiple:true}]:[])];
  return <Form fields={fields} onSubmit={async(values,form)=>{
    const images:string[]=[],photoIds:number[]=[];
    for(const file of form.getAll('images'))if(file instanceof File&&file.size){const body=new FormData();body.set('file',file);const result=await write('/api/upload',body);if(typeof result.url!=='string'||!Number.isInteger(result.file_id))throw new Error('上传未返回有效图片');images.push(result.url);photoIds.push(result.file_id);}
    const scores=Object.fromEntries(['taste_score','value_score','queue_score','hygiene_score','service_score'].map(key=>[key,Number(values[key])]));
    const data:Entity={...scores,comment:values.comment,...(item?preservedReviewData(item):{images,tags:[]})};
    if(!item&&String(values.dish_name||'').trim())data.dishes=[{dish_name:String(values.dish_name).trim(),taste_score:scores.taste_score,value_score:scores.value_score,portion_score:3,comment:values.comment,photo_file_ids:photoIds}];
    await write(item?`/api/canteens/reviews/${item.id}`:`/api/canteens/${id}/reviews`,data,item?'PATCH':'POST');await ui.act(async()=>{},'评价已保存，状态以服务器回读为准');ui.close();
  }}>{!item&&<p className="muted">新菜品与实拍随本次评价提交，是否展示以当前服务端规则为准。</p>}</Form>;
}
function CanteenReviewEditor({id,reviewId}:{id:string;reviewId:number}){
  const q=useApi(`/api/canteens/reviews/${reviewId}/edit-context`);
  return <QueryState query={q}>{q.data&&<CanteenReviewForm id={id} item={entity(q.data,'review')}/>}</QueryState>;
}
export function CanteenReviews({id}:{id:string}){
  const q=useApi(`/api/canteens/${id}/reviews`),ui=useUI(),auth=useAuth();
  return <QueryState query={q}>{rows(q.data,'reviews').map(r=><article className="comment-row" key={r.id||r.review_id}><b>{r.user_name||r.user?.nickname||'同学'} · {r.overall_score||r.star} 分</b><p>{r.comment}</p><div className="post-images">{stringList(r.images).map((url:string)=><a key={url} href={asset(url)} target="_blank" rel="noreferrer"><img src={asset(url)} alt="就餐实拍"/></a>)}</div><small>{time(r.created_at)}</small>{r.user_id===auth.user?.id&&<div className="form-actions"><button className="btn" onClick={()=>ui.open('编辑我的评价',<CanteenReviewEditor id={id} reviewId={r.id}/>)}>编辑</button><button className="btn" onClick={()=>ui.open('删除评价',<><p>确认删除自己的这次评价？</p><button className="btn" onClick={async()=>{if(await ui.act(()=>write(`/api/canteens/reviews/${r.id}`,{},'DELETE')))ui.close()}}>确认删除</button></>)}>删除</button></div>}</article>)}{!rows(q.data,'reviews').length&&<Empty title="暂无就餐评价"/>}</QueryState>;
}
export function CanteenContributions(){
  const q=useApi('/api/user/canteen-contributions');
  const items=rows(q.data,'items');
  const labels:Record<string,string>={dish:'菜品',dish_photo:'实拍',dish_review:'菜品评价',pending:'待审核',active:'已展示',approved:'已通过',rejected:'未通过',merged:'已合并'};
  return <QueryState query={q}>{items.map(x=><article className="list-row" key={`${x.type}:${x.dish_id}:${x.photo_id||''}`}>
    <div className="list-main"><b>{x.dish_name}</b><p>{x.canteen_name} · {labels[x.type]||x.type} · {labels[x.status]||x.status}</p>
      {x.reject_reason&&<p>{x.reject_reason}</p>}{x.merged_into_dish_name&&<p>已合并至：{x.merged_into_dish_name}</p>}
      {x.image&&<div className="post-images"><a href={asset(x.image)} target="_blank" rel="noreferrer"><img src={asset(x.image)} alt={`${x.dish_name}实拍`}/></a></div>}
      <small>{time(x.submitted_at)}</small>{x.canteen_id&&<Link to={`/canteen/${x.canteen_id}`}>查看食堂</Link>}
    </div></article>)}{!items.length&&<Empty title="暂无食堂贡献"/>}</QueryState>;
}
export function DishDetail({canteenId,id}:{canteenId:string;id:number}){const q=useApi(`/api/canteens/${canteenId}/dishes/${id}`),reviews=useApi(`/api/canteens/dishes/${id}/reviews`),d=entity(q.data,'dish');return <QueryState query={q}><h3>{d.name}</h3><p>{d.description}</p><div className="post-images">{rows(q.data,'photos').map(p=><img key={p.id} src={asset(p.image)} alt={d.name}/>)}</div><QueryState query={reviews}>{rows(reviews.data,'reviews').map(r=><div className="comment-row" key={r.id}><b>{r.user_name||r.user?.nickname}</b><p>{r.comment}</p></div>)}</QueryState></QueryState>}
