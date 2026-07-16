import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';

/**
 * 为未提供 OHOS 实现的 path_provider 补充应用私有目录。
 *
 * Flutter 的 Hive 初始化会在 runApp 前请求 documents 目录；若该通道未注册，
 * 初始化异常会直接阻断首屏渲染。
 */
export default class OhosPathProviderPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private applicationContext: common.Context | null = null;

  getUniqueClassName(): string {
    return 'OhosPathProviderPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      'plugins.flutter.io/path_provider',
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.applicationContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const context = this.applicationContext;
    if (context === null) {
      result.error('context_unavailable', '应用上下文尚未就绪', null);
      return;
    }

    switch (call.method) {
      case 'getApplicationDocumentsDirectory':
      case 'getApplicationSupportDirectory':
      case 'getLibraryDirectory':
        result.success(context.filesDir);
        return;
      case 'getApplicationCacheDirectory':
        result.success(context.cacheDir);
        return;
      case 'getTemporaryDirectory':
        result.success(context.tempDir);
        return;
      default:
        result.notImplemented();
    }
  }
}
