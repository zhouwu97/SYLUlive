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

import {readReviewDishes,reviewTime} from './canteen-data';
describe('评价表单里的菜品',()=>{
  const form=(values:Record<string,string>)=>{const fd=new FormData();for(const [k,v] of Object.entries(values))fd.set(k,v);return fd};
  it('最多读取 3 道菜，同名去重，实拍只挂到第一道',()=>{
    expect(readReviewDishes(form({dish_name_1:' 麻辣香锅 ',dish_taste_1:'5',dish_value_1:'4',dish_portion_1:'3',dish_name_2:'麻辣香锅',dish_name_3:'米饭'}),[7,8])).toEqual([
      {dish_name:'麻辣香锅',taste_score:5,value_score:4,portion_score:3,photo_file_ids:[7,8]},
      {dish_name:'米饭',taste_score:0,value_score:0,portion_score:0},
    ]);
  });
  it('一道菜只打了部分分数时报出菜名',()=>{
    expect(()=>readReviewDishes(form({dish_name_1:'米饭',dish_taste_1:'4'}),[])).toThrow('「米饭」的味道、性价比、分量要么都打分，要么都不打分');
  });
  it('没填菜名时返回空列表',()=>{
    expect(readReviewDishes(form({dish_taste_1:'4'}),[])).toEqual([]);
  });
});
describe('评价时间只显示一个',()=>{
  it('编辑过显示更新时间，否则显示发布时间',()=>{
    expect(reviewTime({created_at:'2026-11-01T02:00:00Z',updated_at:'2026-11-01T02:00:00.500Z'})).not.toContain('更新');
    expect(reviewTime({created_at:'2026-11-01T02:00:00Z',updated_at:'2026-11-03T02:00:00Z'})).toContain('更新');
  });
});
