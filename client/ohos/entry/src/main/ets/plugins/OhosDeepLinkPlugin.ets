import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  NewWantListener,
} from '@ohos/flutter_ohos';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';

/**
 * 接收系统 URI Want，并与 Flutter 的深链处理器保持单次消费语义。
 *
 * Dart 首次拉取前只缓存冷启动 URI；拉取完成后，热启动 URI 直接推送给
 * Dart，避免应用恢复时再次拉取同一链接而重复导航。
 */
export default class OhosDeepLinkPlugin implements FlutterPlugin, MethodCallHandler,
  AbilityAware, NewWantListener {
  private static readonly CHANNEL_NAME: string = 'shenliyuan/deeplink';
  private channel: MethodChannel | null = null;
  private abilityBinding: AbilityPluginBinding | null = null;
  private pendingDeepLink: string | null = null;
  private pendingContinuation: string | null = null;
  private dartReady: boolean = false;

  getUniqueClassName(): string {
    return 'OhosDeepLinkPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      OhosDeepLinkPlugin.CHANNEL_NAME,
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.dartReady = false;
    this.pendingContinuation = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityBinding = binding;
    binding.addOnNewWantListener(this);
    this.acceptWant(binding.getAbility().launchWant);
  }

  onDetachedFromAbility(): void {
    this.abilityBinding?.removeOnNewWantListener(this);
    this.abilityBinding = null;
  }

  onNewWant(want: Want, _: AbilityConstant.LaunchParam): void {
    this.acceptWant(want);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'getPendingDeepLink') {
      if (call.method === 'getPendingContinuation') {
        this.dartReady = true;
        const pending = this.pendingContinuation;
        this.pendingContinuation = null;
        result.success(pending);
        return;
      }
      result.notImplemented();
      return;
    }

    this.dartReady = true;
    const pending = this.pendingDeepLink;
    this.pendingDeepLink = null;
    result.success(pending);
  }

  private acceptWant(want: Want): void {
    const continuation = want.parameters?.['syluliveContinuation'];
    if (typeof continuation === 'string') {
      if (this.dartReady && this.channel !== null) {
        this.channel.invokeMethod('onContinuation', continuation);
      } else {
        this.pendingContinuation = continuation;
      }
    }
    const directRoute = want.parameters?.['homeCardRoute'];
    const nestedParameters = want.parameters?.['params'] as Record<string, Object> | undefined;
    const nestedRoute = nestedParameters?.['homeCardRoute'];
    const route = typeof directRoute === 'string'
      ? directRoute
      : (typeof nestedRoute === 'string' ? nestedRoute : undefined);
    const uri = typeof want.uri === 'string'
      ? want.uri
      : (typeof route === 'string' ? route : undefined);
    if (typeof uri !== 'string' || !this.isSupportedUri(uri)) {
      return;
    }

    if (this.dartReady && this.channel !== null) {
      this.channel.invokeMethod('onDeepLink', uri);
      return;
    }
    this.pendingDeepLink = uri;
  }

  private isSupportedUri(uri: string): boolean {
    if (uri === 'campus://timetable') {
      return true;
    }
    if (uri === 'sylulive://exams' || uri === 'sylulive://competition/calendar') {
      return true;
    }
    const prefix = 'sylulive://grades';
    if (!uri.startsWith(prefix)) {
      return false;
    }
    if (uri.length === prefix.length) {
      return true;
    }
    const boundary = uri.charAt(prefix.length);
    return boundary === '?' || boundary === '#' || boundary === '/';
  }
}
