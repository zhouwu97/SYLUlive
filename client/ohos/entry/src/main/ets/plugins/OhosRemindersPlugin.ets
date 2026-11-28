import { FlutterPlugin, FlutterPluginBinding, MethodChannel, MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';
import { reminderAgentManager as reminders } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export default class OhosRemindersPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }

  getUniqueClassName(): string { return 'OhosRemindersPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/ohos_reminders');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      if (call.method === 'requestPermission') {
        if (!await notificationManager.isNotificationEnabled()) {
          await notificationManager.requestEnableNotification(this.context);
        }
        result.success(await notificationManager.isNotificationEnabled());
        return;
      }
      if (call.method !== 'cancel' && call.method !== 'schedule') {
        result.notImplemented();
        return;
      }

      const id = call.argument('id') as number;
      const group = call.argument('group') as string;
      // 操作系统持有提醒，重启后也能按业务分类与编号撤回，不另存映射表。
      const pending = await reminders.getAllValidReminders();
      const previous = pending.find((item: reminders.ReminderInfo) =>
        item.reminderReq.notificationId === id && item.reminderReq.groupId === group);
      if (call.method === 'cancel') {
        if (previous) await reminders.cancelReminder(previous.reminderId);
        result.success(null);
        return;
      }
      const time = new Date(call.argument('time') as number);
      if (time.getTime() <= Date.now() || !await notificationManager.isNotificationEnabled()) {
        result.success(false);
        return;
      }
      const request: reminders.ReminderRequestCalendar = {
        reminderType: reminders.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: { year: time.getFullYear(), month: time.getMonth() + 1, day: time.getDate(),
          hour: time.getHours(), minute: time.getMinutes(), second: time.getSeconds() },
        title: call.argument('title') as string, content: call.argument('body') as string,
        groupId: group, notificationId: id, ringDuration: 0,
        wantAgent: { pkgName: this.context.abilityInfo.bundleName, abilityName: this.context.abilityInfo.name }
      };
      if (previous) await reminders.updateReminder(previous.reminderId, request);
      else await reminders.publishReminder(request);
      result.success(true);
    } catch (e) {
      const code = (e as BusinessError).code;
      if (call.method === 'schedule') result.error('OHOS_REMINDER_SCHEDULE', '系统未接受提醒', code);
      else if (call.method === 'requestPermission') result.success(false);
      else if (call.method === 'cancel' && code === 1700003) result.success(null);
      else result.error('OHOS_REMINDER', '系统提醒操作失败', code);
    }
  }
}
