import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';

export default class OhosMockPlugins implements FlutterPlugin, MethodCallHandler {
  private channels: MethodChannel[] = [];

  getUniqueClassName(): string {
    return 'OhosMockPlugins';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const channelNames = [
      'shenliyuan/keep_alive',
      'shenliyuan/app_update',
      'shenliyuan/foreground',
      'shenliyuan/deeplink',
      'shenliyuan/widget',
      'shenliyuan/course_reminder',
      'shenliyuan/grade_reminder'
    ];

    for (const name of channelNames) {
      let channel = new MethodChannel(binding.getBinaryMessenger(), name);
      channel.setMethodCallHandler(this);
      this.channels.push(channel);
    }
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    for (let channel of this.channels) {
      channel.setMethodCallHandler(null);
    }
    this.channels = [];
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const readMethods = ['canRequest', 'isSupported', 'getWidgetStatus', 'getDiagnostic', 'checkStatus'];
    const clearMethods = ['clearWidget', 'clearNotifications', 'removeReminder', 'cancelAll'];
    
    if (readMethods.includes(call.method) || call.method.startsWith('get') || call.method.startsWith('is') || call.method.startsWith('can')) {
      result.success({
        'supported': false,
        'reason': 'unsupported_on_ohos'
      });
    } else if (clearMethods.includes(call.method) || call.method.startsWith('clear')) {
      result.success(null);
    } else if (call.method === 'scheduleReminder' || call.method === 'syncToken' || call.method === 'updateWidget' || call.method === 'saveConfiguration') {
      result.error('unsupported_on_ohos', 'This write operation is not supported on HarmonyOS', null);
    } else {
      result.notImplemented();
    }
  }
}
