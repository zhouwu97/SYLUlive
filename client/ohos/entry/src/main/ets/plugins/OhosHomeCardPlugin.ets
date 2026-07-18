import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import HomeCardStore from '../homecard/HomeCardStore';

/** Flutter 与鸿蒙互动卡片之间的唯一原生通道。 */
export default class OhosHomeCardPlugin implements FlutterPlugin, MethodCallHandler {
  private static readonly CHANNEL_NAME: string = 'com.sylulive.harmony/home_card';
  private channel: MethodChannel | null = null;
  private applicationContext: common.Context | null = null;

  getUniqueClassName(): string {
    return 'OhosHomeCardPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      OhosHomeCardPlugin.CHANNEL_NAME,
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
      .then((): void => result.success(true))
      .catch((error: Error): void => {
        result.error('home_card_error', error.message, null);
      });
  }

  private async handleCall(call: MethodCall): Promise<void> {
    const context = this.applicationContext;
    if (context === null) throw new Error('应用上下文尚未就绪');
    switch (call.method) {
      case 'syncCourseCard':
        await HomeCardStore.saveCard(context, 'course', this.requiredDataJson(call));
        return;
      case 'syncExamCard':
        await HomeCardStore.saveCard(context, 'exam', this.requiredDataJson(call));
        return;
      case 'syncCompetitionCard':
        await HomeCardStore.saveCard(context, 'competition', this.requiredDataJson(call));
        return;
      case 'refreshCards':
      case 'openCardSettings':
        await HomeCardStore.refreshAll(context);
        return;
      case 'clearAllCards':
        await HomeCardStore.clearCards(context);
        return;
      default:
        throw new Error(`不支持的互动卡片操作: ${call.method}`);
    }
  }

  private requiredDataJson(call: MethodCall): string {
    const value = call.argument('dataJson') as string | null;
    if (typeof value !== 'string') throw new Error('卡片参数无效: dataJson');
    return value;
  }
}
