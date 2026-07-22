import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

export default class OhosPreferencesPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private preferences: dataPreferences.Preferences | null = null;

  getUniqueClassName(): string {
    return 'OhosPreferencesPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/preferences');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.context = null;
    this.preferences = null;
  }

  private async getPreferences(): Promise<dataPreferences.Preferences> {
    if (!this.preferences && this.context) {
      this.preferences = await dataPreferences.getPreferences(this.context, 'FlutterSharedPreferences');
    }
    if (!this.preferences) {
      throw new Error('Preferences could not be initialized');
    }
    return this.preferences;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const prefs = await this.getPreferences();
      const args = call.args as Record<string, Object>;
      const key = args ? args['key'] as string : '';

      switch (call.method) {
        case 'getString':
          result.success(await prefs.get(key, null));
          break;
        case 'setString':
          await prefs.put(key, args['value'] as string);
          await prefs.flush();
          result.success(null);
          break;
        case 'getBool':
          result.success(await prefs.get(key, null));
          break;
        case 'setBool':
          await prefs.put(key, args['value'] as boolean);
          await prefs.flush();
          result.success(null);
          break;
        case 'getInt':
          result.success(await prefs.get(key, null));
          break;
        case 'setInt':
          await prefs.put(key, args['value'] as number);
          await prefs.flush();
          result.success(null);
          break;
        case 'setDouble':
          await prefs.put(key, args['value'] as number);
          await prefs.flush();
          result.success(null);
          break;
        case 'getStringList':
          result.success(await prefs.get(key, null));
          break;
        case 'setStringList':
          await prefs.put(key, args['value'] as Array<string>);
          await prefs.flush();
          result.success(null);
          break;
        case 'remove':
          await prefs.delete(key);
          await prefs.flush();
          result.success(null);
          break;
        case 'clear':
          await prefs.clear();
          await prefs.flush();
          result.success(null);
          break;
        case 'hasKey':
          result.success(await prefs.has(key));
          break;
        case 'getAll':
          result.success(await prefs.getAll());
          break;
        default:
          result.notImplemented();
          break;
      }
    } catch (e) {
      result.error('PREF_ERROR', `Error in ${call.method}`, e instanceof Error ? e.message : String(e));
    }
  }
}
