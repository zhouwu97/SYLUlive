import 'app_platform.dart';
import 'continuation/continuation_service.dart';
import 'platform_capabilities.dart';
import 'deeplink/deep_link_service.dart';
import 'home_card/home_card_service.dart';
import 'live_view/live_view_service.dart';
import 'notification/app_notification_service.dart';
import 'notification/notification_service.dart';
import 'reminder/reminder_service.dart';
import 'scan/scan_service.dart';
import 'secure_storage/secure_storage_service.dart';
import 'update/app_update_service.dart';

/// 平台服务聚合访问点。
///
/// 计划 11.2：把分散在 `main.dart` / `services/*` 中的 Android 原生代码
/// 按能力切片，对外统一为不可破口、可在 Android 与 OHOS 各自实现的接口集合。
///
/// 计划 3.4：未接入能力必须隐藏——[PlatformServices] 在所有 `PlatformCapabilities.supports*`
/// 仍为 false 的平台上必须返回 Noop 实现，业务侧只能通过 `isSupported` 判定后再调用。
///
/// 使用约定：
///   final services = PlatformServices.current;
///   if (services.homeCard.isSupported) {
///     await services.homeCard.syncCard(cardId: 'next_class', dataJson: payload);
///   }
class PlatformServices {
  const PlatformServices._({
    required this.platform,
    required this.capabilities,
    required this.notifications,
    required this.reminders,
    required this.secureStorage,
    required this.updates,
    required this.deepLinks,
    required this.homeCards,
    required this.scan,
    required this.liveView,
    required this.continuation,
  });

  final AppPlatform platform;
  final PlatformCapabilities capabilities;

  final NotificationService notifications;
  final ReminderService reminders;
  final SecureStorageService secureStorage;
  final AppUpdateService updates;
  final DeepLinkService deepLinks;
  final HomeCardService homeCards;
  final ScanService scan;
  final LiveViewService liveView;
  final ContinuationService continuation;

  /// 当前平台的服务表。
  ///
  /// 互动卡片在 OHOS 使用真实实现，其余未接入能力仍返回 Noop 实现。
  /// 后续在对应阶段（9 实况窗 / 10 Scan Kit）中
  /// 按 `PlatformCapabilities.supports*` 切换为真实实现。
  static final Map<AppPlatform, PlatformServices> _instances = {};

  static PlatformServices get current => forPlatform(AppPlatforms.current);

  static PlatformServices forPlatform(AppPlatform platform) {
    return _instances.putIfAbsent(platform, () => _create(platform));
  }

  static PlatformServices _create(AppPlatform platform) {
    final capabilities = PlatformCapabilities.forPlatform(platform);
    // 标准平台通知走应用协调器；OHOS 在 Push Kit 接入前严格返回空实现。
    // 其它服务（提醒/安全存储/更新/深链/卡片/扫码/实况窗）目前仍由各页面的
    // 业务代码直接处理，本轮不强行下沉，避免破坏现有 Android 行为。
    final notifications = platform == AppPlatform.android
        ? AppNotificationService.instance
        : NoopNotificationService(platform: platform);

    return PlatformServices._(
      platform: platform,
      capabilities: capabilities,
      notifications: notifications,
      reminders: NoopReminderService(platform: platform),
      secureStorage: NoopSecureStorageService(platform: platform),
      updates: NoopAppUpdateService(platform: platform),
      deepLinks: NoopDeepLinkService(platform: platform),
      homeCards: platform == AppPlatform.ohos
          ? OhosHomeCardService()
          : NoopHomeCardService(platform: platform),
      scan: platform == AppPlatform.ohos
          ? OhosScanService()
          : NoopScanService(platform: platform),
      continuation: platform == AppPlatform.ohos
          ? OhosContinuationService()
          : NoopContinuationService(platform: platform),
      liveView: platform == AppPlatform.ohos
          ? OhosLiveViewService()
          : NoopLiveViewService(platform: platform),
    );
  }
}
