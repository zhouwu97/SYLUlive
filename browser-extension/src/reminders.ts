import { nextReminder, type ScheduleData } from './schedule';
export interface ReminderConfig { origin: string; appUserId: number; data: ScheduleData; minutes: number }
const prefix = 'reminder:';
export const reminderKey = (origin: string, appUserId: number) => `${prefix}${origin}:${appUserId}`;
export async function rebuildReminder(key: string, config: ReminderConfig) {
  await chrome.alarms.clear(key);
  const next = nextReminder(config.data, config.minutes);
  if (next) await chrome.alarms.create(key, {when: next.at - config.minutes * 60000});
}
export async function removeSchedule(origin: string, appUserId: number) {
  const key = reminderKey(origin, appUserId);
  await chrome.alarms.clear(key);
  await chrome.storage.local.remove(key);
  const values = await chrome.storage.session.get(null);
  const keys = Object.entries(values).filter(([k,value]) => {const v = value as ReminderConfig; return k.startsWith('schedule:') && v.origin === origin && v.appUserId === appUserId;}).map(([k]) => k);
  if (keys.length) await chrome.storage.session.remove(keys);
}
export async function removeOriginSchedules(origin: string) {
  const values = {...await chrome.storage.local.get(null), ...await chrome.storage.session.get(null)};
  const ids = new Set<number>();
  for (const [key,value] of Object.entries(values)) {
    const config = value as ReminderConfig;
    if ((key.startsWith(prefix) || key.startsWith('schedule:')) && config.origin === origin) ids.add(config.appUserId);
  }
  for (const id of ids) await removeSchedule(origin,id);
}
export function installReminders() {
  chrome.alarms.onAlarm.addListener(async alarm => {
    if (!alarm.name.startsWith(prefix)) return;
    const config = (await chrome.storage.local.get(alarm.name))[alarm.name] as ReminderConfig | undefined;
    if (!config) return;
    // 恢复休眠后只接受一分钟内的提醒，过期课程不补发。
    if (Date.now() - alarm.scheduledTime < 60000 && await chrome.permissions.contains({permissions: ['notifications']})) {
      const entry = nextReminder(config.data, config.minutes, alarm.scheduledTime - 1);
      if (entry) await chrome.notifications.create({type: 'basic', iconUrl: 'icon.png', title: entry.title, message: `${config.minutes} 分钟后${entry.kind === 'exam' ? '考试' : '上课'} · ${entry.room || '地点未填写'}`});
    }
    await rebuildReminder(alarm.name, config);
  });
  chrome.runtime.onStartup.addListener(async () => {
    const values = await chrome.storage.local.get(null);
    for (const [key, config] of Object.entries(values)) if (key.startsWith(prefix)) await rebuildReminder(key, config as ReminderConfig);
  });
}
