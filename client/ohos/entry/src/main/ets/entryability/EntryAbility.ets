
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosPathProviderPlugin from '../plugins/OhosPathProviderPlugin';
import OhosSecureStoragePlugin from '../plugins/OhosSecureStoragePlugin';
import OhosExternalNavigatorPlugin from '../plugins/OhosExternalNavigatorPlugin';
import OhosPreferencesPlugin from '../plugins/OhosPreferencesPlugin';
import OhosSharePlugin from '../plugins/OhosSharePlugin';
import OhosCalendarPlugin from '../plugins/OhosCalendarPlugin';
import OhosNotificationsPlugin from '../plugins/OhosNotificationsPlugin';
import OhosMockPlugins from '../plugins/OhosMockPlugins';
import OhosRemindersPlugin from '../plugins/OhosRemindersPlugin';
import OhosWidgetPlugin from '../plugins/OhosWidgetPlugin';

import { AbilityConstant, Want } from '@kit.AbilityKit';

export default class EntryAbility extends FlutterAbility {
  private notifications: OhosNotificationsPlugin | null = null;
  private widgets: OhosWidgetPlugin | null = null;

  onCreate(want: Want, params: AbilityConstant.LaunchParam): void {
    this.notifications = new OhosNotificationsPlugin(this.context);
    this.widgets = new OhosWidgetPlugin(this.context);
    if (!this.widgets.receiveWant(want)) this.notifications.receiveWant(want);
    super.onCreate(want, params);
  }

  onNewWant(want: Want, params: AbilityConstant.LaunchParam): void {
    super.onNewWant(want, params);
    if (!this.widgets?.receiveWant(want)) this.notifications?.receiveWant(want);
  }
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 由项目维护，避免 Flutter 重新生成插件注册器时丢失 path_provider 适配。
    flutterEngine.getPlugins()?.add(new OhosPathProviderPlugin())
    // 认证令牌和教务密码使用系统 Asset Store Kit，不降级写入明文偏好设置。
    flutterEngine.getPlugins()?.add(new OhosSecureStoragePlugin())
    flutterEngine.getPlugins()?.add(new OhosExternalNavigatorPlugin(this.context))
    flutterEngine.getPlugins()?.add(new OhosPreferencesPlugin())
    
    // 自定义业务层插件及外部库桥接平替
    flutterEngine.getPlugins()?.add(new OhosSharePlugin(this.context))
    flutterEngine.getPlugins()?.add(new OhosCalendarPlugin(this.context))
    if (this.notifications) flutterEngine.getPlugins()?.add(this.notifications)
    flutterEngine.getPlugins()?.add(new OhosMockPlugins())
    flutterEngine.getPlugins()?.add(new OhosRemindersPlugin(this.context))
    if (this.widgets) flutterEngine.getPlugins()?.add(this.widgets)
  }
}
