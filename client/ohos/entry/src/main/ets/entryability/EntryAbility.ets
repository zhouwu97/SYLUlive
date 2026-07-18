
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosPathProviderPlugin from '../plugins/OhosPathProviderPlugin';
import OhosSecureStoragePlugin from '../plugins/OhosSecureStoragePlugin';
import OhosSharedPreferencesPlugin from '../plugins/OhosSharedPreferencesPlugin';
import OhosDeepLinkPlugin from '../plugins/OhosDeepLinkPlugin';
import OhosHomeCardPlugin from '../plugins/OhosHomeCardPlugin';
import OhosLiveViewPlugin from '../plugins/OhosLiveViewPlugin';
import OhosScanPlugin from '../plugins/OhosScanPlugin';
import OhosContinuationPlugin from '../plugins/OhosContinuationPlugin';
import ContinuationStore from '../continuation/ContinuationStore';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 由项目维护，避免 Flutter 重新生成插件注册器时丢失 path_provider 适配。
    flutterEngine.getPlugins()?.add(new OhosPathProviderPlugin())
    // 认证令牌和教务密码使用系统 Asset Store Kit，不降级写入明文偏好设置。
    flutterEngine.getPlugins()?.add(new OhosSecureStoragePlugin())
    // shared_preferences 尚无 OHOS 实现，使用 ArkData Preferences 补齐持久化通道。
    flutterEngine.getPlugins()?.add(new OhosSharedPreferencesPlugin())
    // 统一承接冷启动与热启动 URI，并按 Flutter 既有通道协议单次投递。
    flutterEngine.getPlugins()?.add(new OhosDeepLinkPlugin())
    // 课程、考试和竞赛快照通过独立通道写入 ArkData，并刷新系统互动卡片。
    flutterEngine.getPlugins()?.add(new OhosHomeCardPlugin())
    // 阶段 9：通过 Live View Kit 管理下一节课实况窗生命周期。
    flutterEngine.getPlugins()?.add(new OhosLiveViewPlugin())
    // 阶段 10：使用系统 Scan Kit 扫描二维码，业务协议由 Flutter 侧解析。
    flutterEngine.getPlugins()?.add(new OhosScanPlugin())
    // 阶段 11：保存竞赛详情和筛选草稿，供 HarmonyOS 应用接续恢复。
    flutterEngine.getPlugins()?.add(new OhosContinuationPlugin())
  }

  async onContinue(wantParam: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const state = await ContinuationStore.read(this.context);
    if (state !== null) {
      wantParam['syluliveContinuation'] = state;
    }
    return AbilityConstant.OnContinueResult.AGREE;
  }
}
