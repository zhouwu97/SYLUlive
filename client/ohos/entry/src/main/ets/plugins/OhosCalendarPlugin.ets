import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import common from '@ohos.app.ability.common';
import calendarManager from '@ohos.calendarManager';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';

export default class OhosCalendarPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  constructor(context?: common.UIAbilityContext) {
    if (context) {
      this.context = context;
    }
  }

  getUniqueClassName(): string {
    return 'OhosCalendarPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (!this.context) {
      this.context = binding.getApplicationContext() as common.UIAbilityContext;
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'add_2_calendar');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.context = null;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method === 'add2Cal') {
      const args = call.args as Record<string, Object>;
      const title = typeof args['title'] === 'string' ? args['title'] : '';
      const descValue = args['desc'];
      const description = typeof descValue === 'string' ? descValue : '';
      const locationValue = args['location'];
      const location = typeof locationValue === 'string' ? locationValue : '';
      const startDate = args['startDate'] as number;
      const endDate = args['endDate'] as number;
      const allDay = args['allDay'] === true;

      // Note: add_2_calendar supports recurrence, invites, timeZone, etc.
      // HarmonyOS calendarManager has support for recurrenceRule, but they have complex mapping.
      // We will map isAllDay. Others will be safely dropped if not fully supported in this mock.

      if (!this.context) {
        result.error('NO_CONTEXT', 'UIAbilityContext is null', null);
        return;
      }

      try {
        let atManager = abilityAccessCtrl.createAtManager();
        let grantStatus = await atManager.requestPermissionsFromUser(this.context, [
          'ohos.permission.READ_CALENDAR',
          'ohos.permission.WRITE_CALENDAR'
        ]);

        if (grantStatus.authResults[0] !== 0 || grantStatus.authResults[1] !== 0) {
          result.success(false);
          return;
        }

        let calendarMgr = calendarManager.getCalendarManager(this.context);
        let calendar = await calendarMgr.getCalendar();

        let event: calendarManager.Event = {
          type: calendarManager.EventType.NORMAL,
          title: title,
          description: description,
          location: { location: location },
          startTime: startDate,
          endTime: endDate,
          isAllDay: allDay
        };

        await calendar.addEvent(event);
        result.success(true);
      } catch (err) {
        console.error(`OhosCalendarPlugin failed to add event: ${JSON.stringify(err)}`);
        result.success(false);
      }
    } else {
      result.notImplemented();
    }
  }
}
