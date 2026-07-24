import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import common from '@ohos.app.ability.common';
import calendarManager from '@ohos.calendarManager';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';

export default class OhosCalendarPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private recentInsertions: Set<string> = new Set();

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

      if (!title || title.trim() === '') {
        result.error('INVALID_ARGUMENT', 'Title cannot be empty', null);
        return;
      }
      if (typeof startDate !== 'number' || typeof endDate !== 'number' || isNaN(startDate) || isNaN(endDate)) {
        result.error('INVALID_ARGUMENT', 'Invalid startDate or endDate', null);
        return;
      }
      if (endDate <= startDate) {
        result.error('INVALID_ARGUMENT', 'endDate must be greater than startDate', null);
        return;
      }

      const dupKey = `${title}_${startDate}_${endDate}`;
      if (this.recentInsertions.has(dupKey)) {
        result.success(true); // Ignore duplicate click
        return;
      }
      this.recentInsertions.add(dupKey);
      setTimeout(() => {
        this.recentInsertions.delete(dupKey);
      }, 5000); // Clear after 5 seconds

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
