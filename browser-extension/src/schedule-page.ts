import { entries } from './schedule';
import { reminderKey, rebuildReminder, type ReminderConfig } from './reminders';
const params = new URLSearchParams(location.search);
const key = `schedule:${params.get('id')}`;
const root = document.querySelector<HTMLElement>('#app')!;
const panel = document.createElement('main'); panel.className = 'panel'; root.append(panel);
const heading = document.createElement('h1'); panel.append(heading);
async function render() {
  const config = (await chrome.storage.session.get(key))[key] as ReminderConfig | undefined;
  panel.replaceChildren(heading);
  if (!config) {heading.textContent = '课程连接已关闭'; return;}
  if (params.get('mode') === 'reminders') {
    heading.textContent = '启用课程提醒';
    const text = document.createElement('p'); text.textContent = `确认后将本次课表和考试保存在此电脑的扩展中，提前 ${config.minutes} 分钟提醒。依赖浏览器运行；课表修改后请重新同步提醒。`;
    const button = document.createElement('button'); button.textContent = '授予通知权限并启用';
    const status = document.createElement('p'); status.setAttribute('role','status');
    button.onclick = async () => {
      try {
        if (!await chrome.permissions.request({permissions: ['notifications']})) throw new Error('通知权限未授予，提醒未启用');
        // 权限弹窗期间退出账号时，不再保存旧课表。
        if (!(await chrome.storage.session.get(key))[key]) throw new Error('连接已关闭，请重新同步');
        const name = reminderKey(config.origin, config.appUserId);
        await chrome.storage.local.set({[name]: config}); await rebuildReminder(name, config);
        if (!(await chrome.storage.session.get(key))[key]) {
          await chrome.storage.local.remove(name); await chrome.alarms.clear(name);
          throw new Error('连接已关闭，提醒已清除');
        }
        status.textContent = '提醒已启用。关闭浏览器期间不会提醒，已过期提醒不会补发。'; button.disabled = true;
      } catch (error) {status.textContent = error instanceof Error ? error.message : '启用失败';}
    };
    panel.append(text,button,status); return;
  }
  heading.textContent = '今日课程与考试';
  const today = new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai'}).format(new Date());
  const list = entries(config.data).filter(e => new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai'}).format(e.at) === today);
  const label = document.createElement('p'); label.textContent = `${today} · 北京时间`; panel.append(label);
  if (!list.length) { const empty = document.createElement('p'); empty.textContent = '今天没有课程或考试'; panel.append(empty); }
  for (const entry of list) {
    const row = document.createElement('section'); const title = document.createElement('h2');
    title.textContent = entry.title; const detail = document.createElement('p');
    detail.textContent = `${new Intl.DateTimeFormat('zh-CN',{timeZone:'Asia/Shanghai',hour:'2-digit',minute:'2-digit'}).format(entry.at)} · ${entry.kind === 'exam' ? '考试' : '课程'} · ${entry.room || '地点未填写'}`;
    row.append(title,detail); panel.append(row);
  }
}
void render();
chrome.storage.onChanged.addListener((_changes,area) => {if(area === 'session') void render();});
if(params.get('mode') !== 'reminders') setInterval(() => void render(),60000);
