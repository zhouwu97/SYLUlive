import {time,type Entity} from './api';

/** 评分统一保留一位小数；服务端的加权平均会带浮点尾数（如 4.000000000000001）。 */
export function formatScore(value:unknown):string{
  const n=Number(value);
  return Number.isFinite(n)&&n>0?n.toFixed(1):'—';
}

export function stringList(value:unknown):string[]{
  const list=typeof value==='string'?JSON.parse(value||'[]'):value;
  return Array.isArray(list)?list.filter((item):item is string=>typeof item==='string'):[];
}

// 编辑接口使用完整替换语义，因此必须从权威上下文保留菜品关系和图片绑定。
export function preservedReviewData(review:Entity):Entity{
  const dishes=new Map<number,Entity>();
  for(const item of review.recommended_dish_details||[])dishes.set(item.dish_id,{dish_id:item.dish_id});
  for(const item of review.dish_reviews||[])dishes.set(item.dish_id,{
    dish_id:item.dish_id,taste_score:item.taste_score,value_score:item.value_score,
    portion_score:item.portion_score,comment:item.comment,
  });
  for(const photo of review.dish_photos||[]){
    const dish=dishes.get(photo.dish_id)||{dish_id:photo.dish_id};
    dish.photo_file_ids=[...(dish.photo_file_ids||[]),photo.file_id];
    dishes.set(photo.dish_id,dish);
  }
  return {images:stringList(review.images),tags:stringList(review.tags),base_updated_at:review.updated_at,dishes:[...dishes.values()]};
}

/** 评价只显示一个时间：编辑过（更新时间晚于发布 1 秒以上）显示“… 更新”，否则显示发布时间，与 App 一致。 */
export function reviewTime(review:Entity):string{
  const created=Date.parse(review.created_at),updated=Date.parse(review.updated_at);
  if(Number.isFinite(created)&&Number.isFinite(updated)&&updated-created>1000)return `${time(review.updated_at)} 更新`;
  return time(review.created_at);
}

export const DISH_DIMENSIONS=[['taste','味道'],['value','性价比'],['portion','分量']] as const;
/** 与服务端 maxReviewDishes 一致：一条到店评价最多关联 3 道菜。 */
export const MAX_REVIEW_DISHES=3;

/** 从表单读出最多 3 道菜：同名去重，三项分数要么都不填，要么都填。 */
export function readReviewDishes(form:FormData,photoIds:number[]):Entity[]{
  const dishes:Entity[]=[],seen=new Set<string>();
  for(let n=1;n<=MAX_REVIEW_DISHES;n++){
    const name=String(form.get(`dish_name_${n}`)||'').trim();
    if(!name||seen.has(name))continue;
    seen.add(name);
    const scores=DISH_DIMENSIONS.map(([key])=>Number(form.get(`dish_${key}_${n}`)||0));
    if(scores.some(Boolean)&&!scores.every(Boolean))throw new Error(`「${name}」的味道、性价比、分量要么都打分，要么都不打分`);
    const [taste_score,value_score,portion_score]=scores;
    dishes.push({dish_name:name,taste_score,value_score,portion_score,...(dishes.length===0&&photoIds.length?{photo_file_ids:photoIds}:{})});
  }
  return dishes;
}
