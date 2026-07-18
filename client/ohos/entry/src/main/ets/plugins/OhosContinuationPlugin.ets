import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import ContinuationStore from '../continuation/ContinuationStore';

/** Flutter 页面状态与 HarmonyOS 应用接续之间的最小桥接。 */
export default class OhosContinuationPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private static readonly CHANNEL_NAME: string = 'com.sylulive.harmony/continuation';
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;

  getUniqueClassName(): string {
    return 'OhosContinuationPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), OhosContinuationPlugin.CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const context = this.context;
    if (context === null) {
      result.error('continuation_unavailable', '应用接续上下文尚未就绪', null);
      return;
    }
    if (call.method === 'saveState') {
      const state = call.argument('stateJson') as string | null;
      if (typeof state !== 'string') {
        result.error('invalid_state', '接续状态必须是 JSON 字符串', null);
        return;
      }
      ContinuationStore.save(context, state)
        .then((): void => result.success(null))
        .catch((error: Error): void => result.error('continuation_save_failed', error.message, null));
      return;
    }
    if (call.method === 'clearState') {
      ContinuationStore.clear(context)
        .then((): void => result.success(null))
        .catch((error: Error): void => result.error('continuation_clear_failed', error.message, null));
      return;
    }
    result.notImplemented();
  }
}
