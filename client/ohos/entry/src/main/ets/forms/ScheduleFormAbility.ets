import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { common, Want } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { preferences } from '@kit.ArkData';

interface Course {
  name: string; weekday: number; weeks: number[]; start_section: number; end_section: number; location: string;
}
interface CourseData { semester_start?: string; courses: Course[] }
interface Exam { name: string; date: string; time: string; location: string }
interface ExamData { exams: Exam[] }
interface CardRow { title: string; detail: string }
interface Colors { background: string; primaryText: string; secondaryText: string }
interface ThemeVariants { light: Colors; dark: Colors }
interface CardData {
  kind: string; title: string; subtitle: string; rows: CardRow[]; empty: string;
  background: string; primary: string; secondary: string; textSize: number;
}
const starts = ['08:00','08:55','10:00','10:55','13:00','13:55','14:50','15:45','16:40','17:35','19:30','20:25'];
const ends = ['08:45','09:40','10:45','11:40','13:45','14:40','15:35','16:30','17:25','18:20','20:15','21:10'];

export function scheduleCard(context: common.Context, kind: string, dimension: number): formBindingData.FormBindingData {
  // Flutter 将偏好写到应用级目录，UIAbility 和卡片扩展必须读取同一个目录。
  const prefs = preferences.getPreferencesSync(context.getApplicationContext(), { name: 'FlutterSharedPreferences' });
  const course = kind === 'course';
  const defaultTitle = course ? '沈理校园' : '考试日程';
  const savedTitle = prefs.getSync('widget_' + kind + '_title', defaultTitle) as string;
  // 桌面卡片能先于升级后的主应用启动。
  const title = ['沈理院课表', '沈理院', 'shenliyuan'].includes(savedTitle) ? defaultTitle : savedTitle;
  const size = prefs.getSync('widget_' + kind + '_font_size', 'standard') as string;
  const theme = prefs.getSync('widget_' + kind + '_theme', 'system') as string;
  const dark = context.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
  let palette: Colors = { background: '#F2FFFFFF', primaryText: '#111827', secondaryText: '#4B5563' };
  if (theme === 'campusBlue') {
    palette = { background: '#F2EFF6FF', primaryText: '#1E3A8A', secondaryText: '#475569' };
  } else if (theme === 'dark' || (theme !== 'light' && dark)) {
    palette = { background: '#F21F2937', primaryText: '#F9FAFB', secondaryText: '#D1D5DB' };
  }
  if (theme === 'appTheme') {
    const raw = prefs.getSync('widget_app_palette_v1', '') as string;
    if (raw) {
      const variants = JSON.parse(raw) as ThemeVariants;
      palette = dark ? variants.dark : variants.light;
    }
  }
  const frosted = prefs.getSync('widget_' + kind + '_frosted_glass', false) === true;
  const wide = dimension === formInfo.FormDimension.Dimension_2_4;
  const now = new Date();
  const day = now.getDay() || 7;
  const data: CardData = {
    kind, title, subtitle: (now.getMonth() + 1) + '月' + now.getDate() + '日 周' + '一二三四五六日'.charAt(day - 1),
    rows: [], empty: course ? '今日无课' : '暂无待考科目',
    background: frosted ? '#D1' + palette.background.slice(-6) : palette.background,
    primary: palette.primaryText, secondary: palette.secondaryText,
    textSize: size === 'extraLarge' ? (wide ? 18 : 16) : (wide ? 12 : 11) +
      (size === 'small' ? -1 : size === 'large' ? 1 : 0)
  };
  const raw = prefs.getSync('widget_' + kind + '_data', '') as string;
  if (raw) {
    if (course) {
      const schedule = JSON.parse(raw) as CourseData;
      const start = schedule.semester_start ? Date.parse(schedule.semester_start + 'T00:00:00') : NaN;
      const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
      const week = Math.floor(Math.round((today - start) / 86400000) / 7) + 1;
      const courses = schedule.courses.filter((c: Course) => c.weekday === day &&
        (!Number.isFinite(week) || c.weeks.length === 0 || c.weeks.includes(week)));
      courses.sort((a: Course, b: Course) => a.start_section - b.start_section);
      data.rows = courses.map((c: Course): CardRow => ({
        title: c.name, detail: starts[c.start_section - 1] + '–' + ends[c.end_section - 1] + '  ' + c.location
      }));
    } else {
      const exams = (JSON.parse(raw) as ExamData).exams;
      data.rows = exams.filter((e: Exam) => Date.parse(e.date + 'T' + e.time.split('-')[1] + ':00') > now.getTime())
        .map((e: Exam): CardRow => ({ title: e.name, detail: e.date.slice(5) + ' ' + e.time + '  ' + e.location }));
    }
  }
  return formBindingData.createFormBindingData(data);
}

export default class ScheduleFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const name = want.parameters?.[formInfo.FormParam.NAME_KEY] as string;
    return scheduleCard(this.context, name, Number(want.parameters?.[formInfo.FormParam.DIMENSION_KEY]));
  }

  async onUpdateForm(id: string): Promise<void> {
    const form = await formProvider.getPublishedRunningFormInfoById(id);
    await formProvider.updateForm(id, scheduleCard(this.context, form.formName, form.dimension));
  }
}
