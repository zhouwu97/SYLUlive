import { mergeCourses, type AcademicBackup } from '@sylulive/academic-contracts';

export const periodStarts = ['08:00','08:55','10:00','10:55','13:00','13:55','14:50','15:45','16:40','17:35','19:30','20:25'];
export type ScheduleData = Pick<AcademicBackup, 'termStart' | 'courses' | 'overrides' | 'exams'>;
export interface ScheduleEntry { id: string; title: string; room: string; at: number; kind: 'course' | 'exam' }
export function entries(data: ScheduleData): ScheduleEntry[] {
  const start = Date.parse(`${data.termStart}T00:00:00+08:00`);
  const result: ScheduleEntry[] = [];
  for (const course of mergeCourses(data.courses, data.overrides)) {
    const time = periodStarts[Math.min(...course.periods) - 1];
    if (!time || !Number.isFinite(start)) continue;
    const [hour, minute] = time.split(':').map(Number);
    for (const week of new Set(course.weeks)) result.push({
      id: `${course.id}:${week}`, title: course.name, room: course.room, kind: 'course',
      at: start + ((week - 1) * 7 + course.day - 1) * 86400000 + (hour * 60 + minute) * 60000,
    });
  }
  for (const exam of data.exams) result.push({id: `exam:${exam.id}`, title: exam.name, room: exam.room, kind: 'exam', at: Date.parse(exam.startTime)});
  return result.sort((a,b) => a.at - b.at);
}
export function nextReminder(data: ScheduleData, minutes: number, now = Date.now()) {
  return entries(data).find(e => e.at - minutes * 60000 > now);
}
