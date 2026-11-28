import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { formInfo, formProvider } from '@kit.FormKit';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scheduleCard } from '../forms/ScheduleFormAbility';

export default class OhosWidgetPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private links: MethodChannel | null = null;
  private pendingLink: string | null = null;

  receiveWant(want: Want): boolean {
    const kind = want.parameters?.['scheduleKind'];
    if (kind !== 'course' && kind !== 'exam') return false;
    this.pendingLink = kind === 'course' ? 'widget_timetable' : 'widget_exam';
    this.links?.invokeMethod('onDeepLink', this.pendingLink);
    return true;
  }

  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'OhosWidgetPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/widget');
    this.channel.setMethodCallHandler(this);
    this.links = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/deeplink');
    this.links.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.links?.setMethodCallHandler(null);
    this.links = null;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      if (call.method === 'getPendingDeepLink') {
        result.success(this.pendingLink);
        return;
      }
      if (call.method === 'ackPendingDeepLink') {
        if (call.argument('link') === this.pendingLink) this.pendingLink = null;
        result.success(null);
        return;
      }
      if (call.method === 'requestPinWidget') {
        const response: Record<string, string> = {};
        response['status'] = 'unsupported';
        response['message'] = '请长按应用图标，通过服务卡片添加。';
        result.success(response);
        return;
      }
      if (call.method !== 'updateWidget' && call.method !== 'getInstalledWidgetCounts') {
        result.notImplemented();
        return;
      }
      const forms = (await formProvider.getPublishedRunningFormInfos()).filter((f: formInfo.RunningFormInfo) =>
        f.formName === 'course' || f.formName === 'exam');
      if (call.method === 'updateWidget') {
        await Promise.all(forms.map((f: formInfo.RunningFormInfo) =>
          formProvider.updateForm(f.formId, scheduleCard(this.context, f.formName, f.dimension))));
        result.success(null);
      } else {
        const counts: Record<string, number> = {};
        for (const form of forms) {
          const size = form.dimension === formInfo.FormDimension.Dimension_2_4 ? '4x2' : '2x2';
          const key = form.formName + size;
          counts[key] = (counts[key] ?? 0) + 1;
        }
        result.success(counts);
      }
    } catch (e) {
      result.error('OHOS_WIDGET', '读取或更新桌面卡片失败', (e as BusinessError).code);
    }
  }
}
