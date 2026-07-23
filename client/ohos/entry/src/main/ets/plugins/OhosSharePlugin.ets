import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import wantConstant from '@ohos.app.ability.wantConstant';
import fileUri from '@ohos.file.fileuri';

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
      const mimeTypes = args['mimeTypes'] as string[];
      
      if (!paths || paths.length === 0) {
        result.error('INVALID_ARGUMENTS', 'paths cannot be empty', null);
        return;
      }

      const uris = paths.map((path: string): string => fileUri.getUriFromPath(path));
      let want: Want;
      if (uris.length === 1) {
        want = {
          action: 'ohos.want.action.sendData',
          uri: uris[0],
          type: (mimeTypes && mimeTypes.length > 0) ? mimeTypes[0] : '*/*',
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
        };
      } else {
        want = {
          action: 'ohos.want.action.sendMultipleData',
          type: (mimeTypes && mimeTypes.length > 0) ? mimeTypes[0] : '*/*',
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
          parameters: {
            'ability.params.stream': uris
          }
        };
      }

      this.showSharePanel(want, result);
    } else {
      result.notImplemented();
    }
  }

  private showSharePanel(want: Want, result: MethodResult): void {
    if (this.context) {
      this.context.startAbility(want).then(() => {
        // Return unavailable to prevent fake "success" message since we don't know if they actually shared it
        result.success('dev.fluttercommunity.plus/share/unavailable');
      }).catch((err: Object) => {
        console.error(`OhosSharePlugin failed to share: ${JSON.stringify(err)}`);
        result.success('dev.fluttercommunity.plus/share/unavailable');
      });
    } else {
      result.error('NO_CONTEXT', 'UIAbilityContext is null', null);
    }
  }
}
