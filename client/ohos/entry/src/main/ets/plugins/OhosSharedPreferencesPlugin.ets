import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

type PreferenceMap = Record<string, preferences.ValueType>;

/**
 * 为 shared_preferences 的旧版 MethodChannel 接口提供鸿蒙持久化实现。
 *
 * Flutter 传入的键已经带有 flutter. 前缀，原样保存和返回，确保 Dart 侧的
 * 前缀过滤、缓存恢复逻辑与 Android/iOS 保持一致。
 */
export default class OhosSharedPreferencesPlugin implements FlutterPlugin, MethodCallHandler {
  private static readonly CHANNEL_NAME: string = 'plugins.flutter.io/shared_preferences';
  private static readonly STORE_NAME: string = 'flutter_shared_preferences';
  private channel: MethodChannel | null = null;
  private applicationContext: common.Context | null = null;

  getUniqueClassName(): string {
    return 'OhosSharedPreferencesPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      OhosSharedPreferencesPlugin.CHANNEL_NAME,
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.applicationContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handleCall(call)
      .then((value: Object | boolean): void => result.success(value))
      .catch((error: Error): void => {
        result.error('shared_preferences_error', error.message, null);
      });
  }

  private async handleCall(call: MethodCall): Promise<Object | boolean> {
    const store = await this.getStore();
    switch (call.method) {
      case 'getAll':
        return store.getAll();
      case 'getAllWithParameters':
        return this.filterValues(await store.getAll(), call);
      case 'setBool':
      case 'setInt':
      case 'setDouble':
      case 'setString':
      case 'setStringList':
        await store.put(this.requiredKey(call), this.requiredValue(call));
        await store.flush();
        return true;
      case 'remove':
        await store.delete(this.requiredKey(call));
        await store.flush();
        return true;
      case 'clear':
        await store.clear();
        await store.flush();
        return true;
      case 'clearWithParameters':
        await this.clearFiltered(store, call);
        await store.flush();
        return true;
      default:
        throw new Error(`不支持的偏好设置操作: ${call.method}`);
    }
  }

  private async getStore(): Promise<preferences.Preferences> {
    const context = this.applicationContext;
    if (context === null) {
      throw new Error('应用上下文尚未就绪');
    }
    return preferences.getPreferences(context, OhosSharedPreferencesPlugin.STORE_NAME);
  }

  private requiredKey(call: MethodCall): string {
    const key = call.argument('key') as string | null;
    if (typeof key !== 'string' || key.length === 0) {
      throw new Error('偏好设置参数无效: key');
    }
    return key;
  }

  private requiredValue(call: MethodCall): preferences.ValueType {
    const value = call.argument('value') as preferences.ValueType | null;
    if (value === null || value === undefined) {
      throw new Error('偏好设置参数无效: value');
    }
    return value;
  }

  private filterValues(source: Object, call: MethodCall): Object {
    const values = source as PreferenceMap;
    const output: PreferenceMap = {};
    const prefix = this.prefixFrom(call);
    const allowList = this.allowListFrom(call);
    Object.keys(values).forEach((key: string): void => {
      if (key.startsWith(prefix) && (allowList === null || allowList.includes(key))) {
        output[key] = values[key];
      }
    });
    return output;
  }

  private async clearFiltered(store: preferences.Preferences, call: MethodCall): Promise<void> {
    const values = await store.getAll() as PreferenceMap;
    const prefix = this.prefixFrom(call);
    const allowList = this.allowListFrom(call);
    const keys = Object.keys(values);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      if (key.startsWith(prefix) && (allowList === null || allowList.includes(key))) {
        await store.delete(key);
      }
    }
  }

  private prefixFrom(call: MethodCall): string {
    const prefix = call.argument('prefix') as string | null;
    return typeof prefix === 'string' ? prefix : '';
  }

  private allowListFrom(call: MethodCall): Array<string> | null {
    const allowList = call.argument('allowList') as Array<string> | null;
    return Array.isArray(allowList) ? allowList : null;
  }
}
