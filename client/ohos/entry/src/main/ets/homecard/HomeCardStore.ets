import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { preferences } from '@kit.ArkData';

interface HomeCardItemData {
  title: string;
  primary: string;
  secondary: string;
  badge: string;
}

interface HomeCardSourceData {
  schemaVersion: number;
  title: string;
  subtitle: string;
  empty: boolean;
  items: Array<HomeCardItemData>;
  updatedAt: string;
  featuredIndex?: number;
}

export interface HomeCardBindingData {
  title: string;
  subtitle: string;
  emptyText: string;
  lineCount: number;
  line1Title: string;
  line1Primary: string;
  line1Secondary: string;
  line1Badge: string;
  line2Title: string;
  line2Primary: string;
  line2Secondary: string;
  line2Badge: string;
  line3Title: string;
  line3Primary: string;
  line3Secondary: string;
  line3Badge: string;
  line4Title: string;
  line4Primary: string;
  line4Secondary: string;
  line4Badge: string;
  route: string;
}

type FormRegistry = Record<string, string>;

/** 互动卡片的数据校验、持久化与刷新中心。 */
export default class HomeCardStore {
  static readonly STORE_NAME: string = 'sylulive_home_cards';
  private static readonly REGISTRY_KEY: string = 'form_registry';
  private static readonly CARD_KEYS: Array<string> = ['course', 'exam', 'competition'];
  private static readonly MAX_DATA_LENGTH: number = 256 * 1024;

  static async saveCard(
    context: common.Context,
    cardId: string,
    dataJson: string,
  ): Promise<void> {
    if (!HomeCardStore.CARD_KEYS.includes(cardId)) {
      throw new Error(`未知卡片标识: ${cardId}`);
    }
    const store = await HomeCardStore.getStore(context);
    if (dataJson.length === 0) {
      await store.delete(HomeCardStore.cardKey(cardId));
    } else {
      HomeCardStore.parseAndValidate(dataJson);
      await store.put(HomeCardStore.cardKey(cardId), dataJson);
    }
    await store.flush();
    await HomeCardStore.refreshAll(context);
  }

  static async clearCards(context: common.Context): Promise<void> {
    const store = await HomeCardStore.getStore(context);
    for (const cardId of HomeCardStore.CARD_KEYS) {
      await store.delete(HomeCardStore.cardKey(cardId));
    }
    await store.flush();
    await HomeCardStore.refreshAll(context);
  }

  static async registerForm(
    context: common.Context,
    formId: string,
    formName: string,
  ): Promise<void> {
    if (formId.length === 0 || !HomeCardStore.isKnownForm(formName)) {
      return;
    }
    const store = await HomeCardStore.getStore(context);
    const registry = await HomeCardStore.readRegistry(store);
    registry[formId] = formName;
    await store.put(HomeCardStore.REGISTRY_KEY, JSON.stringify(registry));
    await store.flush();
  }

  static async removeForm(context: common.Context, formId: string): Promise<void> {
    const store = await HomeCardStore.getStore(context);
    const registry = await HomeCardStore.readRegistry(store);
    const remaining: FormRegistry = {};
    Object.entries(registry).forEach((entry: [string, string]): void => {
      if (entry[0] !== formId) remaining[entry[0]] = entry[1];
    });
    await store.put(HomeCardStore.REGISTRY_KEY, JSON.stringify(remaining));
    await store.flush();
  }

  static async refreshAll(context: common.Context): Promise<void> {
    const store = await HomeCardStore.getStore(context);
    const registry = await HomeCardStore.readRegistry(store);
    const entries = Object.entries(registry);
    const activeRegistry: FormRegistry = {};
    for (const entry of entries) {
      const formId = entry[0];
      const formName = entry[1];
      try {
        await HomeCardStore.updateForm(context, formId, formName);
        activeRegistry[formId] = formName;
      } catch (_) {
        // 已从桌面移除的卡片会返回无效 ID，重建注册表时自然淘汰。
      }
    }
    await store.put(HomeCardStore.REGISTRY_KEY, JSON.stringify(activeRegistry));
    await store.flush();
  }

  static async updateForm(
    context: common.Context,
    formId: string,
    formName: string,
  ): Promise<void> {
    const data = await HomeCardStore.bindingFor(context, formName);
    await formProvider.updateForm(
      formId,
      formBindingData.createFormBindingData(data),
    );
  }

  static emptyBinding(formName: string): HomeCardBindingData {
    const title = formName === 'next_course'
      ? '下一节课'
      : (formName === 'today_courses' ? '今日课程' : '学业提醒');
    const emptyText = formName === 'academic_reminders'
      ? '暂无考试或竞赛提醒'
      : '今天没有课程';
    return {
      title: title,
      subtitle: '数据将在打开应用后更新',
      emptyText: emptyText,
      lineCount: 0,
      line1Title: '', line1Primary: '', line1Secondary: '', line1Badge: '',
      line2Title: '', line2Primary: '', line2Secondary: '', line2Badge: '',
      line3Title: '', line3Primary: '', line3Secondary: '', line3Badge: '',
      line4Title: '', line4Primary: '', line4Secondary: '', line4Badge: '',
      route: formName === 'academic_reminders'
        ? 'sylulive://exams'
        : 'campus://timetable',
    };
  }

  private static async bindingFor(
    context: common.Context,
    formName: string,
  ): Promise<HomeCardBindingData> {
    if (formName === 'academic_reminders') {
      return HomeCardStore.academicBinding(context);
    }
    const course = await HomeCardStore.readCard(context, 'course');
    if (course === null) return HomeCardStore.emptyBinding(formName);
    if (formName === 'next_course') {
      const index = Math.max(0, Math.min(
        course.featuredIndex ?? 0,
        Math.max(course.items.length - 1, 0),
      ));
      const selected = course.items.length === 0 ? [] : [course.items[index]];
      return HomeCardStore.compose(
        '下一节课',
        course.subtitle,
        '今天没有课程',
        selected,
        'campus://timetable',
      );
    }
    return HomeCardStore.compose(
      course.title,
      course.subtitle,
      '今天没有课程',
      course.items,
      'campus://timetable',
    );
  }

  private static async academicBinding(context: common.Context): Promise<HomeCardBindingData> {
    const exam = await HomeCardStore.readCard(context, 'exam');
    const competition = await HomeCardStore.readCard(context, 'competition');
    const items: Array<HomeCardItemData> = [];
    if (exam !== null) items.push(...exam.items);
    if (competition !== null) items.push(...competition.items);
    const subtitleParts: Array<string> = [];
    if (exam !== null && exam.items.length > 0) subtitleParts.push(`考试 ${exam.items.length}`);
    if (competition !== null && competition.items.length > 0) {
      subtitleParts.push(`竞赛 ${competition.items.length}`);
    }
    return HomeCardStore.compose(
      '学业提醒',
      subtitleParts.length === 0 ? '暂无待办' : subtitleParts.join(' · '),
      '暂无考试或竞赛提醒',
      items,
      exam !== null && exam.items.length > 0
        ? 'sylulive://exams'
        : 'sylulive://competition/calendar',
    );
  }

  private static compose(
    title: string,
    subtitle: string,
    emptyText: string,
    source: Array<HomeCardItemData>,
    route: string,
  ): HomeCardBindingData {
    const items = source.slice(0, 4);
    const read = (index: number): HomeCardItemData => items[index] ?? {
      title: '', primary: '', secondary: '', badge: '',
    };
    const first = read(0);
    const second = read(1);
    const third = read(2);
    const fourth = read(3);
    return {
      title: title,
      subtitle: subtitle,
      emptyText: emptyText,
      lineCount: items.length,
      line1Title: first.title,
      line1Primary: first.primary,
      line1Secondary: first.secondary,
      line1Badge: first.badge,
      line2Title: second.title,
      line2Primary: second.primary,
      line2Secondary: second.secondary,
      line2Badge: second.badge,
      line3Title: third.title,
      line3Primary: third.primary,
      line3Secondary: third.secondary,
      line3Badge: third.badge,
      line4Title: fourth.title,
      line4Primary: fourth.primary,
      line4Secondary: fourth.secondary,
      line4Badge: fourth.badge,
      route: route,
    };
  }

  private static async readCard(
    context: common.Context,
    cardId: string,
  ): Promise<HomeCardSourceData | null> {
    const store = await HomeCardStore.getStore(context);
    const raw = await store.get(HomeCardStore.cardKey(cardId), '');
    if (typeof raw !== 'string' || raw.length === 0) return null;
    try {
      return HomeCardStore.parseAndValidate(raw);
    } catch (_) {
      return null;
    }
  }

  private static parseAndValidate(dataJson: string): HomeCardSourceData {
    if (dataJson.length > HomeCardStore.MAX_DATA_LENGTH) {
      throw new Error('卡片数据超过 256 KB 限制');
    }
    const parsed = JSON.parse(dataJson) as HomeCardSourceData;
    if (parsed === null || typeof parsed !== 'object' || parsed.schemaVersion !== 1 ||
      typeof parsed.title !== 'string' || typeof parsed.subtitle !== 'string' ||
      !Array.isArray(parsed.items)) {
      throw new Error('卡片 JSON 结构无效');
    }
    for (const item of parsed.items) {
      if (typeof item.title !== 'string' || typeof item.primary !== 'string' ||
        typeof item.secondary !== 'string' || typeof item.badge !== 'string') {
        throw new Error('卡片条目结构无效');
      }
    }
    return parsed;
  }

  private static async readRegistry(
    store: preferences.Preferences,
  ): Promise<FormRegistry> {
    const raw = await store.get(HomeCardStore.REGISTRY_KEY, '{}');
    if (typeof raw !== 'string') return {};
    try {
      return JSON.parse(raw) as FormRegistry;
    } catch (_) {
      return {};
    }
  }

  private static getStore(context: common.Context): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, HomeCardStore.STORE_NAME);
  }

  private static cardKey(cardId: string): string {
    return `card_${cardId}`;
  }

  private static isKnownForm(formName: string): boolean {
    return ['next_course', 'today_courses', 'academic_reminders'].includes(formName);
  }
}
