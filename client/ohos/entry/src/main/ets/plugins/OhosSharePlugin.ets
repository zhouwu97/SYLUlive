import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';

export default class OhosSharePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  constructor(context?: common.UIAbilityContext) {
    if (context) {
      this.context = context;
    }
  }

  getUniqueClassName(): string {
    return 'OhosSharePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (!this.context) {
      this.context = binding.getApplicationContext() as common.UIAbilityContext;
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dev.fluttercommunity.plus/share');
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
    const args = call.args as Record<string, Object>;
    if (call.method === 'share' || call.method === 'shareUri') {
      const text = args['text'] as string;
      const uri = args['uri'] as string;
      const subject = args['subject'] as string;

      let want: Want = {
        action: 'ohos.want.action.sendData',
        type: 'text/plain',
        parameters: {
          'ability.want.params.send.text': text || uri,
          'ability.want.params.send.subject': subject || ''
        }
      };
      
      this.showSharePanel(want, result);
    } else if (call.method === 'shareFiles') {
      const paths = args['paths'] as string[];
      
      if (!paths || paths.length === 0) {
        result.error('INVALID_ARGUMENTS', 'paths cannot be empty', null);
        return;
      }

      let want: Want = {
        action: 'ohos.want.action.sendData',
        type: '*/*',
        parameters: {
          'ability.want.params.send.stream': paths.map(p => 'file://' + p)
        }
      };

      this.showSharePanel(want, result);
    } else {
      result.notImplemented();
    }
  }

  private showSharePanel(want: Want, result: MethodResult): void {
    if (this.context) {
      this.context.startAbility(want).then(() => {
        result.success('success');
      }).catch((err: Object) => {
        console.error(`OhosSharePlugin failed to share: ${JSON.stringify(err)}`);
        result.success('dev.fluttercommunity.plus/share/unavailable');
      });
    } else {
      result.error('NO_CONTEXT', 'UIAbilityContext is null', null);
    }
  }
}
