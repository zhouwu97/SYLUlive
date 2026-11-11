import {mergeCourses, type AcademicBackup} from '@sylulive/academic-contracts';

export function calculateWeightedGpa(text: string): number {
  let credits = 0, weighted = 0;
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    if (!line.trim()) continue;
    const fields = line.split(/[,，]/).map(field => field.trim());
    if (fields.length !== 2 || fields.some(field => !field))
      throw new Error(`第 ${index + 1} 行请完整填写学分和绩点`);
    const [credit, gpa] = fields.map(Number);
    if (!Number.isFinite(credit) || credit <= 0 || !Number.isFinite(gpa) || gpa < 0 || gpa > 5)
      throw new Error(`第 ${index + 1} 行请输入有效学分和 0–5 的绩点`);
    credits += credit;
    weighted += credit * gpa;
    if (!Number.isFinite(credits) || !Number.isFinite(weighted))
      throw new Error(`第 ${index + 1} 行数据过大，请核对学分和绩点`);
  }
  if (!credits) throw new Error('请输入至少一门课程');
  return weighted / credits;
}

type Availability =
  | {ready: false; title: string; description: string}
  | {ready: true; week: number; days: number[][]};

export function weeklyAvailability(data: Pick<AcademicBackup, 'courses' | 'overrides' | 'termStart'>, now = new Date()): Availability {
  const courses = mergeCourses(data.courses, data.overrides);
  if (!courses.length)
    return {ready: false, title: '还没有课表', description: '请先读取或导入课表，再计算本周空闲时间。没有课表数据不能判断是否有课。'};
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(data.termStart);
  const start = match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : null;
  if (!start || start.getFullYear() !== Number(match![1]) || start.getMonth() + 1 !== Number(match![2]) || start.getDate() !== Number(match![3]) || start.getDay() !== 1)
    return {ready: false, title: '请核对开学第一周', description: '请在课表设置中填写本学期第一周的周一日期，再计算当前教学周。'};
  // 按日历日计算，避免夏令时导致整周边界少算或多算一小时。
  const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
  const firstDay = Date.UTC(start.getFullYear(), start.getMonth(), start.getDate());
  const week = Math.floor((today - firstDay) / (7 * 86400000)) + 1;
  if (week < 1)
    return {ready: false, title: '尚未到开学第一周', description: '当前日期早于课表设置的开学日期，请核对学期后再计算。'};
  const knownWeeks = courses.flatMap(course => course.weeks).filter(value => Number.isInteger(value) && value > 0);
  const lastKnownWeek = knownWeeks.reduce((last, value) => Math.max(last, value), 0);
  if (!knownWeeks.length || week > lastKnownWeek)
    return {ready: false, title: '当前周超出课表已知范围', description: '现有课表不能确认本周是否有课，请更新课表或核对开学日期后重试。'};
  const current = courses.filter(course => course.weeks.includes(week));
  return {ready: true, week, days: Array.from({length: 7}, (_, day) => Array.from({length: 12}, (_, period) => period + 1)
    .filter(period => !current.some(course => course.day === day + 1 && course.periods.includes(period))))};
}
