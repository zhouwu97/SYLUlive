import type {Entity} from './api';

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
