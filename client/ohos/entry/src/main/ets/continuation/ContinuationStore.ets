import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 应用接续状态存储，只保存可恢复的页面草稿，不保存账号凭据。 */
export default class ContinuationStore {
  private static readonly STORE_NAME: string = 'sylulive_continuation';
  private static readonly STATE_KEY: string = 'state';

  static async save(context: common.Context, stateJson: string): Promise<void> {
    if (stateJson.length === 0 || stateJson.length > 16 * 1024) {
      throw new Error('接续状态大小无效');
    }
    const store = await preferences.getPreferences(context, ContinuationStore.STORE_NAME);
    await store.put(ContinuationStore.STATE_KEY, stateJson);
    await store.flush();
  }

  static async read(context: common.Context): Promise<string | null> {
    const store = await preferences.getPreferences(context, ContinuationStore.STORE_NAME);
    const value = await store.get(ContinuationStore.STATE_KEY, '');
    return typeof value === 'string' && value.length > 0 ? value : null;
  }

  static async clear(context: common.Context): Promise<void> {
    const store = await preferences.getPreferences(context, ContinuationStore.STORE_NAME);
    await store.delete(ContinuationStore.STATE_KEY);
    await store.flush();
  }
}
