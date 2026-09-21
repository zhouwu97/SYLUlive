import { it, expect } from "vitest";
import { ranges, courses, profile, grades, creditRequirements } from "./parsers";
it("解析单双周和连续节次", () => {
  expect(ranges("1-6周(单),8周", 60)).toEqual([1, 3, 5, 8]);
  expect(ranges("2-8周(双)", 60)).toEqual([2, 4, 6, 8]);
  expect(() => ranges("20-80周", 60)).toThrow();
});
it('学分树中的规则节点合并进真实模块且不重复计数',()=>{
  const c={kch:'A',kcmc:'课程 A',xf:'2',yxxf:'2',cj:'通过',xnmc:'2026',xqmc:'1'};
  const result=creditRequirements([{xfyqjdmc:'通识',yqzdxf:'4',kcList:[c],xfyqjdList:[{xfyqjdmc:'至少修4学分',kcList:[c,{...c,kch:'B',kcmc:'课程 B'}]}]}]);
  expect(result.modules).toHaveLength(1);expect(result.modules[0].earned).toBe(4);expect(result.modules[0].courses).toHaveLength(2);expect(result.modules[0].status).toBe('本地计算达标');
  expect(()=>creditRequirements([{unexpected:true}])).toThrow();
});
it("学校改变返回结构时拒绝替换资料", () => {
  expect(() => courses({ error: "登录过期" })).toThrow();
  expect(() => grades({ rows: [] })).toThrow();
});
it("课程排列变化不改变本地覆盖的键", () => {
  const a = { kch_id: "A", kcmc: "课程 A", xqj: 1, jc: "1-2节", zcd: "1-16周" },
    b = { ...a, kch_id: "B" };
  expect(courses({ kbList: [a, b] })[0].id).toBe(
    courses({ kbList: [b, a] })[1].id,
  );
});
it("身份的可见和隐藏字段必须一致", () => {
  expect(() =>
    profile(
      '<div id="col_xh">123</div><input id="xh_id" value="456"><input id="curXh_id" value="123">',
    ),
  ).toThrow();
});
