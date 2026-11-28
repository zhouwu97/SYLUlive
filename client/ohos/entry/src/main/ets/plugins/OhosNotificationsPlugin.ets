import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common, Want } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import JpushHarmonySdkPlugin from 'jpush_flutter';

export default class OhosNotificationsPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private ready: boolean = false;
  private pending: Want | null = null;

  constructor(context: common.UIAbilityContext) { this.context = context; }

  receiveWant(want: Want): void {
    const prefs = preferences.getPreferencesSync(this.context.getApplicationContext(), { name: 'FlutterSharedPreferences' });
    if (prefs.getSync('push_data_processing_enabled', false) !== true) return;
    if (this.ready) JpushHarmonySdkPlugin.setClickWant(want, this.context);
    else this.pending = want;
  }

  getUniqueClassName(): string { return 'OhosNotificationsPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/private_message_notifications');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.ready = false;
    this.pending = null;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {

      switch (call.method) {
        case 'setPushOptIn':
          if (!call.argument('enabled')) {
            this.ready = false;
            this.pending = null;
          }
          result.success(null);
          return;
        case 'consumePushWant':
          // 等用户开启推送、Flutter 注册回调后再投递冷启动点击。
          this.ready = true;
          if (this.pending) JpushHarmonySdkPlugin.setClickWant(this.pending, this.context);
          this.pending = null;
          result.success(null);
          return;
        case 'requestPermission':
          if (!await notificationManager.isNotificationEnabled()) {
            await notificationManager.requestEnableNotification(this.context);
          }
          if (await notificationManager.isNotificationEnabled()) {
            await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
            result.success(true);
          } else {
            result.success(false);
          }
          return;
        case 'openNotificationChannelSettings':
        case 'openAppNotificationSettings':
          await notificationManager.openNotificationSettings(this.context);
          result.success(true);
          return;
        case 'getPushDiagnostics': {
          const report: Record<string, Object> = {};
          report['notificationsEnabled'] = await notificationManager.isNotificationEnabled();
          const slots = await notificationManager.getSlots();
          const social = slots.find((slot: notificationManager.NotificationSlot) =>
            slot.type === notificationManager.SlotType.SOCIAL_COMMUNICATION);
          report['privateMessageChannelExists'] = social !== undefined;
          report['privateMessageChannelBlocked'] = social?.enabled === false;
          result.success(report);
          return;
        }
        case 'clearConversationNotifications': {
          const id = call.argument('conversationId') as number;
          const active = await notificationManager.getActiveNotifications();
          for (const note of active) {
            if (note.id === id && note.slotType === notificationManager.SlotType.SOCIAL_COMMUNICATION) {
              await notificationManager.cancel(id, note.label);
            }
          }
          result.success(null);
          return;
        }
        default: result.notImplemented();
      }
    } catch (e) {
      if (call.method === 'requestPermission') result.success(false);
      else result.error('OHOS_NOTIFICATION', '鸿蒙通知操作失败', (e as BusinessError).code);
    }
  }
}
