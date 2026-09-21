import { describe, expect, it } from 'vitest';
import { entries, nextReminder, type ScheduleData } from './schedule';
const data: ScheduleData = {termStart:'2026-09-07',courses:[{id:'a',name:'课程',room:'A',teacher:'',day:1,periods:[1,2],weeks:[1,3]}],overrides:{},exams:[]};
describe('课程提醒时间', () => {
  it('按北京时间处理单双周并将连续节次合并为一次提醒', () => {
    expect(entries(data).map(e=>new Date(e.at).toISOString())).toEqual(['2026-09-07T00:00:00.000Z','2026-09-21T00:00:00.000Z']);
  });
  it('重启时不安排过期提醒，使用手动课程调整', () => {
    expect(nextReminder(data,10,Date.parse('2026-09-07T00:01:00Z'))?.at).toBe(Date.parse('2026-09-21T00:00:00Z'));
    expect(entries({...data,overrides:{a:null}})).toEqual([]);
  });
});
