import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';

export default class OhosExternalNavigatorPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  constructor(context?: common.UIAbilityContext) {
    if (context) {
      this.context = context;
    }
  }

  getUniqueClassName(): string {
    return 'OhosExternalNavigatorPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (!this.context) {
      this.context = binding.getApplicationContext() as common.UIAbilityContext;
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'shenliyuan/external_navigator');
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
    if (call.method === 'openUrl') {
      const args = call.args as Record<string, Object>;
      const url = args['url'] as string;
      if (!url) {
        result.error('INVALID_URL', 'URL cannot be empty', null);
        return;
      }

      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };

      if (this.context) {
        this.context.startAbility(want).then(() => {
          result.success(true);
        }).catch((err: Error) => {
          console.error(`OhosExternalNavigatorPlugin failed to open ${url}: ${JSON.stringify(err)}`);
          result.success(false); // Return false on failure, matching Dart interface expectation
        });
      } else {
        result.error('NO_CONTEXT', 'UIAbilityContext is null', null);
      }
    } else {
      result.notImplemented();
    }
  }
}
