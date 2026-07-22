
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosPathProviderPlugin from '../plugins/OhosPathProviderPlugin';
import OhosSecureStoragePlugin from '../plugins/OhosSecureStoragePlugin';
import OhosExternalNavigatorPlugin from '../plugins/OhosExternalNavigatorPlugin';
import OhosPreferencesPlugin from '../plugins/OhosPreferencesPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 由项目维护，避免 Flutter 重新生成插件注册器时丢失 path_provider 适配。
    flutterEngine.getPlugins()?.add(new OhosPathProviderPlugin())
    // 认证令牌和教务密码使用系统 Asset Store Kit，不降级写入明文偏好设置。
    flutterEngine.getPlugins()?.add(new OhosSecureStoragePlugin())
    flutterEngine.getPlugins()?.add(new OhosExternalNavigatorPlugin(this.context))
    flutterEngine.getPlugins()?.add(new OhosPreferencesPlugin())
  }
}
