import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import common from '@ohos.app.ability.common';

export default class OhosNotificationsPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  constructor(context?: common.UIAbilityContext) {
    if (context) {
      this.context = context;
    }
  }

  getUniqueClassName(): string {
    return 'OhosNotificationsPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (!this.context) {
      this.context = binding.getApplicationContext() as common.UIAbilityContext;
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/private_message_notifications');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'syncAlias') {
      // Mock implementation
      result.success(true);
    } else if (call.method === 'clearAlias') {
      result.success(null);
    } else if (call.method === 'clearConversationNotifications') {
      result.success(null);
    } else if (call.method === 'setCurrentConversation') {
      result.success(null);
    } else if (call.method === 'getPendingPrivateMessage') {
      result.success(null);
    } else if (call.method === 'getPushDiagnostics') {
      result.success({
        'status': 'mocked',
        'platform': 'ohos'
      });
    } else {
      result.notImplemented();
    }
  }
}
