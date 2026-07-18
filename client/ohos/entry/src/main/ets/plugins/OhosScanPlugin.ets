import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';

/** 通过系统 Scan Kit 向 Flutter 返回单次扫码结果。 */
export default class OhosScanPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private static readonly CHANNEL_NAME: string = 'com.sylulive.harmony/scan';
  private channel: MethodChannel | null = null;
  private abilityContext: common.Context | null = null;

  getUniqueClassName(): string {
    return 'OhosScanPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      OhosScanPlugin.CHANNEL_NAME,
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityContext = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.abilityContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'scan') {
      result.notImplemented();
      return;
    }
    const context = this.abilityContext;
    if (context === null) {
      result.error('scan_unavailable', '鸿蒙页面上下文尚未就绪', null);
      return;
    }

    const kind = call.argument('kind') as string | null;
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: kind === 'multicode',
      enableAlbum: false,
    };
    scanBarcode.startScanForResult(context, options)
      .then((scanResult: scanBarcode.ScanResult): void => {
        result.success(scanResult.originalValue);
      })
      .catch((error: BusinessError): void => {
        if (error.code === 1000500002) {
          result.error('scan_cancelled', '用户取消扫码', null);
          return;
        }
        result.error('scan_failed', error.message ?? '扫码失败', error.code);
      });
  }
}
