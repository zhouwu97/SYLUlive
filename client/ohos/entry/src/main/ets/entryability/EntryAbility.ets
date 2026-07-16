
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosPathProviderPlugin from '../plugins/OhosPathProviderPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 由项目维护，避免 Flutter 重新生成插件注册器时丢失 path_provider 适配。
    flutterEngine.getPlugins()?.add(new OhosPathProviderPlugin())
  }
}
