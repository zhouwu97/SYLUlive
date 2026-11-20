import {describe, expect, it} from 'vitest';
import {type Course} from '@sylulive/academic-contracts';
import {calculateWeightedGpa, weeklyAvailability} from './toolbox-calculations';

describe('GPA input', () => {
  it.each(['3,', '3,   ', ',4', '3,4,2', '0,4', '-1,4', '3,6', '1e308,5', '1e308,0\n1e308,0', 'NaN,2', ' \n '])('rejects incomplete or invalid rows: %s', input => {
    expect(() => calculateWeightedGpa(input)).toThrow();
  });
  it('keeps explicit zero and accepts decimal credits, Chinese separators and blank lines', () => {
    expect(calculateWeightedGpa('3,0')).toBe(0);
    expect(calculateWeightedGpa('3，4\n\n1,0')).toBe(3);
    expect(calculateWeightedGpa('2.5,3.5\r\n1.5,4')).toBeCloseTo(3.6875);
  });
  it('identifies the original row even when blank lines are present', () => {
    expect(() => calculateWeightedGpa('\n3,4\n2,')).toThrow('第 3 行');
  });
});

const course: Course = {id: '1', name: '课程', teacher: '', room: '', day: 1, periods: [1, 2], weeks: [1, 2, 3]};
const monday = new Date(2026, 8, 7, 12);
describe('weekly availability', () => {
  it('does not infer free time without a schedule or after deleting every known course', () => {
    expect(weeklyAvailability({courses: [], overrides: {}, termStart: ''}, monday).ready).toBe(false);
    expect(weeklyAvailability({courses: [course], overrides: {'1': null}, termStart: '2026-09-07'}, monday).ready).toBe(false);
  });
  it.each(['', '2026-02-31', '2026-09-08'])('requires a real first-week Monday: %s', start => {
    expect(weeklyAvailability({courses: [course], overrides: {}, termStart: start}, monday).ready).toBe(false);
  });
  it('does not claim availability before the term or beyond known schedule weeks', () => {
    for (const date of [new Date(2026, 8, 6, 12), new Date(2026, 9, 1, 12)])
      expect(weeklyAvailability({courses: [course], overrides: {}, termStart: '2026-09-07'}, date).ready).toBe(false);
  });
  it('applies local changes and preserves a genuinely class-free known week', () => {
    const result = weeklyAvailability({courses: [course], overrides: {'1': {...course, day: 2, periods: [3]}}, termStart: '2026-09-07'}, monday);
    expect(result.ready && result.days[1]).not.toContain(3);
    expect(result.ready && result.days[0]).toHaveLength(12);
    const gap = weeklyAvailability({courses: [{...course, weeks: [1, 3]}], overrides: {}, termStart: '2026-09-07'}, new Date(2026, 8, 14, 12));
    expect(gap.ready && gap.week).toBe(2);
    expect(gap.ready && gap.days.every(day => day.length === 12)).toBe(true);
  });
});
