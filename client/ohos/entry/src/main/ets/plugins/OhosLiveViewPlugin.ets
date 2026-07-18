import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { bundleManager, common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { liveViewManager } from '@kit.LiveViewKit';

interface LiveViewPayload {
  type: string;
  businessId: string;
  title: string;
  body: string;
  startTime?: string;
  endTime?: string;
  route?: string;
}

interface LiveViewState {
  id: number;
  event: string;
  sequence: number;
}

type LiveViewRegistry = Record<string, string>;

/** Flutter 实况窗桥接，负责 Live View Kit 的生命周期和业务键去重。 */
export default class OhosLiveViewPlugin implements FlutterPlugin, MethodCallHandler {
  private static readonly CHANNEL_NAME: string = 'com.sylulive.harmony/live_view';
  private static readonly STORE_NAME: string = 'sylulive_live_views';
  private static readonly REGISTRY_KEY: string = 'active_payloads';
  private static readonly COURSE_WINDOW_MS: number = 60 * 60 * 1000;
  private channel: MethodChannel | null = null;
  private applicationContext: common.Context | null = null;
  private states: Map<string, LiveViewState> = new Map<string, LiveViewState>();
  private startTimers: Map<string, number> = new Map<string, number>();
  private endTimers: Map<string, number> = new Map<string, number>();

  getUniqueClassName(): string {
    return 'OhosLiveViewPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      OhosLiveViewPlugin.CHANNEL_NAME,
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.applicationContext = null;
    this.clearAllTimers();
    this.states.clear();
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handleCall(call)
      .then((): void => result.success(true))
      .catch((error: Error): void => {
        result.error('live_view_error', error.message, null);
      });
  }

  private async handleCall(call: MethodCall): Promise<void> {
    switch (call.method) {
      case 'startCourseLiveView':
        await this.startOrUpdate(this.requiredPayload(call, true));
        return;
      case 'updateCourseLiveView':
        await this.startOrUpdate(this.requiredPayload(call, true));
        return;
      case 'startExamLiveView':
      case 'startCompetitionDeadlineLiveView':
        await this.startOrUpdate(this.requiredPayload(call, true));
        return;
      case 'endCourseLiveView':
        const payload = this.requiredPayload(call, false);
        if (payload.businessId.length === 0) {
          await this.clearType(payload.type);
        } else {
          await this.end(payload);
        }
        return;
      case 'clearAllLiveViews':
        await this.clearAll();
        return;
      default:
        throw new Error(`不支持的实况窗操作: ${call.method}`);
    }
  }

  private async startOrUpdate(payload: LiveViewPayload): Promise<void> {
    const key = this.keyOf(payload);
    this.clearTimers(key);
    const now = Date.now();
    const startTime = this.parseTime(payload.startTime);
    const endTime = this.parseTime(payload.endTime);
    if (endTime <= now) {
      await this.end(payload);
      return;
    }
    const previous = await this.resolveState(payload);
    const isCourse = payload.type === 'course' || payload.type === 'next_class';
    if (previous === undefined && isCourse &&
      startTime - now > OhosLiveViewPlugin.COURSE_WINDOW_MS) {
      return;
    }
    const sequence = previous === undefined ? 0 : previous.sequence + 1;
    const state: LiveViewState = previous ?? {
      id: this.stableId(key),
      event: `sylulive.${payload.type}`,
      sequence: 0,
    };
    const clickAction = await this.createClickAction(payload);
    const liveView = this.toLiveView(payload, state, sequence, clickAction);
    if (previous === undefined) {
      if (!await liveViewManager.isLiveViewEnabled()) {
        throw new Error('系统未允许本应用创建实况窗，请在系统设置中启用');
      }
      await liveViewManager.startLiveView(liveView);
    } else {
      await liveViewManager.updateLiveView(liveView);
    }
    state.sequence = sequence;
    this.states.set(key, state);
    await this.savePayload(payload);
    this.scheduleTransitions(payload, now);
  }

  private async end(payload: LiveViewPayload): Promise<void> {
    const key = this.keyOf(payload);
    this.clearTimers(key);
    const state = await this.resolveState(payload);
    if (state === undefined) {
      await this.removePayload(key);
      return;
    }
    let storedPayload: LiveViewPayload;
    try {
      storedPayload = await this.requireStoredPayload(payload);
    } catch (_) {
      await this.stopWithActiveLiveView(state);
      this.states.delete(key);
      await this.removePayload(key);
      return;
    }
    const clickAction = await this.createClickAction(storedPayload);
    await liveViewManager.stopLiveView(
      this.toLiveView(storedPayload, state, state.sequence + 1, clickAction),
    );
    this.states.delete(key);
    await this.removePayload(key);
  }

  /** 持久化载荷丢失时，以系统保存的活动对象收口，结束操作保持幂等。 */
  private async stopWithActiveLiveView(state: LiveViewState): Promise<void> {
    try {
      const active = await liveViewManager.getActiveLiveView(state.id);
      active.sequence = (active.sequence ?? state.sequence) + 1;
      await liveViewManager.stopLiveView(active);
    } catch (_) {
      // 活动已不存在、已结束或系统暂不可用时，清理本地状态即可。
    }
  }

  private async clearAll(): Promise<void> {
    this.clearAllTimers();
    const registry = await this.readRegistry();
    const entries = Object.entries(registry);
    let firstError: Error | null = null;
    for (const entry of entries) {
      try {
        const payload = JSON.parse(entry[1]) as LiveViewPayload;
        await this.end(payload);
      } catch (error) {
        if (firstError === null) firstError = error as Error;
      }
    }
    this.states.clear();
    await this.writeRegistry({});
    if (firstError !== null) throw firstError;
  }

  private async clearType(type: string): Promise<void> {
    const registry = await this.readRegistry();
    const entries = Object.entries(registry);
    let firstError: Error | null = null;
    for (const entry of entries) {
      try {
        const payload = JSON.parse(entry[1]) as LiveViewPayload;
        if (payload.type === type || (type === 'course' && payload.type === 'next_class')) {
          await this.end(payload);
        }
      } catch (error) {
        if (firstError === null) firstError = error as Error;
      }
    }
    if (firstError !== null) throw firstError;
  }

  private async resolveState(payload: LiveViewPayload): Promise<LiveViewState | undefined> {
    const key = this.keyOf(payload);
    const memoryState = this.states.get(key);
    if (memoryState !== undefined) return memoryState;
    const id = this.stableId(key);
    try {
      const active = await liveViewManager.getActiveLiveView(id);
      const state: LiveViewState = {
        id: id,
        event: active.event,
        sequence: active.sequence ?? 0,
      };
      this.states.set(key, state);
      return state;
    } catch (_) {
      return undefined;
    }
  }

  private toLiveView(
    payload: LiveViewPayload,
    state: LiveViewState,
    sequence: number,
    clickAction: WantAgent,
  ): liveViewManager.LiveView {
    const startTime = this.parseTime(payload.startTime);
    const endTime = this.parseTime(payload.endTime);
    const now = Date.now();
    const status = now < startTime ? '即将上课' : now < endTime ? '上课中' : '已结束';
    const timerTime = now < startTime ? startTime : endTime;
    return {
      id: state.id,
      event: state.event,
      sequence,
      timer: { time: timerTime, isCountdown: true, isPaused: false },
      liveViewData: {
        primary: {
          title: payload.title,
          content: [{ text: `${status} · ${payload.body}` }],
          keepTime: 300,
          clickAction,
          extensionData: {
            text: '打开应用',
            type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
            clickAction,
            actionType: liveViewManager.ActionType.ACTION_TYPE_OPEN_APP_PAGE,
          },
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
          status: 0,
          content: status,
          time: timerTime,
          isCountdown: true,
        },
      },
    };
  }

  private async createClickAction(payload: LiveViewPayload): Promise<WantAgent> {
    const bundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION,
    );
    const want: Want = {
      bundleName: bundleInfo.name,
      moduleName: 'entry',
      abilityName: 'EntryAbility',
      parameters: { homeCardRoute: payload.route ?? this.defaultRoute(payload.type) },
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: this.stableId(this.keyOf(payload)),
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    return await wantAgent.getWantAgent(info);
  }

  private scheduleTransitions(payload: LiveViewPayload, now: number): void {
    if (payload.type !== 'course' && payload.type !== 'next_class') return;
    const key = this.keyOf(payload);
    const startTime = this.parseTime(payload.startTime);
    const endTime = this.parseTime(payload.endTime);
    if (startTime > now) {
      const timer = setTimeout((): void => {
        this.startOrUpdate(payload).catch((error: Error): void => {
          console.error(`实况窗上课状态更新失败: ${error.message}`);
        });
      }, startTime - now);
      this.startTimers.set(key, timer);
    }
    const timer = setTimeout((): void => {
      this.end(payload).catch((error: Error): void => {
        console.error(`实况窗自动结束失败: ${error.message}`);
      });
    }, endTime - now);
    this.endTimers.set(key, timer);
  }

  private clearTimers(key: string): void {
    const startTimer = this.startTimers.get(key);
    if (startTimer !== undefined) clearTimeout(startTimer);
    this.startTimers.delete(key);
    const endTimer = this.endTimers.get(key);
    if (endTimer !== undefined) clearTimeout(endTimer);
    this.endTimers.delete(key);
  }

  private clearAllTimers(): void {
    const keys = Array.from(this.startTimers.keys());
    for (const key of keys) this.clearTimers(key);
    const remainingKeys = Array.from(this.endTimers.keys());
    for (const key of remainingKeys) this.clearTimers(key);
  }

  private async savePayload(payload: LiveViewPayload): Promise<void> {
    const registry = await this.readRegistry();
    registry[this.keyOf(payload)] = JSON.stringify(payload);
    await this.writeRegistry(registry);
  }

  private async removePayload(key: string): Promise<void> {
    const registry = await this.readRegistry();
    const next: LiveViewRegistry = {};
    const entries = Object.entries(registry);
    for (const entry of entries) {
      if (entry[0] !== key) next[entry[0]] = entry[1];
    }
    await this.writeRegistry(next);
  }

  private async readRegistry(): Promise<LiveViewRegistry> {
    const context = this.applicationContext;
    if (context === null) throw new Error('应用上下文尚未就绪');
    const store = await preferences.getPreferences(context, OhosLiveViewPlugin.STORE_NAME);
    const raw = await store.get(OhosLiveViewPlugin.REGISTRY_KEY, '{}');
    if (typeof raw !== 'string') return {};
    try {
      return JSON.parse(raw) as LiveViewRegistry;
    } catch (_) {
      return {};
    }
  }

  private async writeRegistry(registry: LiveViewRegistry): Promise<void> {
    const context = this.applicationContext;
    if (context === null) throw new Error('应用上下文尚未就绪');
    const store = await preferences.getPreferences(context, OhosLiveViewPlugin.STORE_NAME);
    await store.put(OhosLiveViewPlugin.REGISTRY_KEY, JSON.stringify(registry));
    await store.flush();
  }

  private requiredPayload(call: MethodCall, requiresSchedule: boolean): LiveViewPayload {
    const value = call.argument('dataJson') as string | null;
    if (typeof value !== 'string' || value.length === 0) {
      throw new Error('实况窗参数无效: dataJson');
    }
    const payload = JSON.parse(value) as LiveViewPayload;
    if (typeof payload.type !== 'string' || typeof payload.businessId !== 'string' ||
      typeof payload.title !== 'string' || typeof payload.body !== 'string') {
      throw new Error('实况窗参数缺少 type、businessId、title 或 body');
    }
    if (requiresSchedule && (payload.type.trim().length === 0 ||
      payload.businessId.trim().length === 0 || payload.title.trim().length === 0)) {
      throw new Error('创建实况窗时 type、businessId 和 title 不能为空');
    }
    if (requiresSchedule && !this.hasValidSchedule(payload)) {
      throw new Error('实况窗开始时间必须早于结束时间，且两者格式有效');
    }
    return payload;
  }

  private async requireStoredPayload(payload: LiveViewPayload): Promise<LiveViewPayload> {
    if (this.hasValidSchedule(payload)) return payload;
    const raw = (await this.readRegistry())[this.keyOf(payload)];
    if (typeof raw !== 'string') {
      throw new Error('结束实况窗时未找到有效的已保存时间');
    }
    const storedPayload = JSON.parse(raw) as LiveViewPayload;
    if (!this.hasValidSchedule(storedPayload)) {
      throw new Error('结束实况窗时已保存的时间无效');
    }
    return storedPayload;
  }

  private hasValidSchedule(payload: LiveViewPayload): boolean {
    if (typeof payload.startTime !== 'string' || typeof payload.endTime !== 'string') {
      return false;
    }
    const startTime = Date.parse(payload.startTime);
    const endTime = Date.parse(payload.endTime);
    return Number.isFinite(startTime) && Number.isFinite(endTime) && startTime < endTime;
  }

  private keyOf(payload: LiveViewPayload): string {
    return `${payload.type}:${payload.businessId}`;
  }

  private stableId(key: string): number {
    let hash = 7;
    for (let index = 0; index < key.length; index++) {
      hash = (hash * 31 + key.charCodeAt(index)) % 2147483647;
    }
    return hash === 0 ? 1 : hash;
  }

  private parseTime(value: string | undefined): number {
    if (typeof value !== 'string') {
      throw new Error('实况窗时间缺失');
    }
    const parsed = Date.parse(value);
    if (!Number.isFinite(parsed)) {
      throw new Error('实况窗时间格式无效');
    }
    return parsed;
  }

  private defaultRoute(type: string): string {
    if (type === 'exam') {
      return 'sylulive://exams';
    }
    if (type === 'competition') {
      return 'sylulive://competition/calendar';
    }
    return 'campus://timetable';
  }
}
