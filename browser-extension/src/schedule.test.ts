import { describe, expect, it } from 'vitest';
import { entries, nextReminder, type ScheduleData } from './schedule';
const data: ScheduleData = {termStart:'2026-09-07',courses:[{id:'a',name:'课程',room:'A',teacher:'',day:1,periods:[1,2],weeks:[1,3]}],overrides:{},exams:[]};
describe('课程提醒时间', () => {
  it('按北京时间处理单双周并将连续节次合并为一次提醒', () => {
    expect(entries(data).map(e=>new Date(e.at).toISOString())).toEqual(['2026-09-07T00:00:00.000Z','2026-09-21T00:00:00.000Z']);
  });
  it('同日分段课程分别展示并依次提醒，重复或乱序节次不增加提醒', () => {
    const split = {...data, courses: [{...data.courses[0], periods: [5, 2, 1, 6, 5], weeks: [1]}]};
    const slots = entries(split);
    expect(slots.map(slot => new Date(slot.at).toISOString())).toEqual([
      '2026-09-07T00:00:00.000Z', '2026-09-07T05:00:00.000Z',
    ]);
    expect(new Set(slots.map(slot => slot.id)).size).toBe(2);
    expect(nextReminder(split, 10, slots[0].at - 600001)).toEqual(slots[0]);
    expect(nextReminder(split, 10, slots[0].at - 600000)).toEqual(slots[1]);
  });
  it('重启时不安排过期提醒，使用手动课程调整', () => {
    expect(nextReminder(data,10,Date.parse('2026-09-07T00:01:00Z'))?.at).toBe(Date.parse('2026-09-21T00:00:00Z'));
    expect(entries({...data,overrides:{a:null}})).toEqual([]);
  });
});
