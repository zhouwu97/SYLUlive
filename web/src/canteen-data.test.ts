import {describe,it,expect} from 'vitest';
import {preservedReviewData} from './canteen-data';
describe('食堂评价编辑的完整替换请求',()=>{
  it('保留编码图片、标签、关联菜品、评分及照片文件编号',()=>{
    expect(preservedReviewData({images:'["/uploads/1.jpg"]',tags:'["午餐"]',updated_at:'2026-09-20T10:00:00Z',
      recommended_dish_details:[{dish_id:8,name:'菜品'}],dish_reviews:[{dish_id:8,taste_score:4,value_score:5,portion_score:3,comment:'原有评价'}],
      dish_photos:[{dish_id:8,file_id:42}]})).toEqual({images:['/uploads/1.jpg'],tags:['午餐'],base_updated_at:'2026-09-20T10:00:00Z',
      dishes:[{dish_id:8,taste_score:4,value_score:5,portion_score:3,comment:'原有评价',photo_file_ids:[42]}]});
  });
});
