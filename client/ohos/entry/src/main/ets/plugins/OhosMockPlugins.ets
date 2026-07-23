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
    // Simply mock all methods on these channels to prevent MissingPluginException
    // Most methods in Dart check for null or use `?? false`
    if (call.method.startsWith('can') || call.method.startsWith('is') || call.method.startsWith('open')) {
      result.success(false);
    } else {
      result.success(null);
    }
  }
}
