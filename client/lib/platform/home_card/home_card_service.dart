import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../app_platform.dart';

/// 鸿蒙互动卡片能力的服务接口（计划阶段 8）。
///
/// 计划 11.2 + 阶段 8：
///   Flutter Provider → [HomeCardService] → MethodChannel → ArkTS
///   → Preferences / 卡片数据 → FormExtensionAbility
///
/// 数据更新触发点（计划 12.3）：
///   登录恢复、课表拉取成功、学期切换、考试刷新、竞赛计划变更、退出账号。
///
/// 数据格式约定：[dataJson] 由具体业务侧自己序列化，鸿蒙实现按
/// 卡片 ID（`cardId`）落到 Preferences；上层必须自行脱敏，
/// 默认不在锁屏展示完整学号、成绩详情等敏感信息（计划 17.4）。
abstract class HomeCardService {
  AppPlatform get platform;
  bool get isSupported;

  /// 同步某张互动卡片的数据。`cardId` 为鸿蒙卡片标识。
  /// `dataJson` 为空时实现应当清空对应卡片的展示数据。
  Future<void> syncCard({
    required String cardId,
    String? dataJson,
  });

  Future<void> syncCourseCard(Map<String, Object?> data);

  Future<void> syncExamCard(Map<String, Object?> data);

  Future<void> syncCompetitionCard(Map<String, Object?> data);

  Future<void> refreshCards();

  Future<void> openCardSettings();

  /// 同步退出账号后的清理：所有隐私卡片数据归零，避免 App 未运行时漏数据（计划 12.4）。
  Future<void> clearAllCards();

  Future<void> dispose();
}

/// 基于 Flutter OHOS MethodChannel 的互动卡片实现。
class OhosHomeCardService implements HomeCardService {
  OhosHomeCardService({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.sylulive.harmony/home_card');

  final MethodChannel _channel;

  @override
  AppPlatform get platform => AppPlatform.ohos;

  @override
  bool get isSupported => true;

  @override
  Future<void> syncCard({required String cardId, String? dataJson}) async {
    final method = switch (cardId) {
      'course' => 'syncCourseCard',
      'exam' => 'syncExamCard',
      'competition' => 'syncCompetitionCard',
      _ => throw ArgumentError.value(cardId, 'cardId', '未知卡片标识'),
    };
    await _channel.invokeMethod<void>(method, {'dataJson': dataJson ?? ''});
  }

  @override
  Future<void> syncCourseCard(Map<String, Object?> data) =>
      syncCard(cardId: 'course', dataJson: jsonEncode(data));

  @override
  Future<void> syncExamCard(Map<String, Object?> data) =>
      syncCard(cardId: 'exam', dataJson: jsonEncode(data));

  @override
  Future<void> syncCompetitionCard(Map<String, Object?> data) =>
      syncCard(cardId: 'competition', dataJson: jsonEncode(data));

  @override
  Future<void> refreshCards() => _channel.invokeMethod<void>('refreshCards');

  @override
  Future<void> openCardSettings() =>
      _channel.invokeMethod<void>('openCardSettings');

  @override
  Future<void> clearAllCards() => _channel.invokeMethod<void>('clearAllCards');

  @override
  Future<void> dispose() async {}
}

/// 未对接平台的占位实现；调用全部 no-op，[isSupported] 为 false。
/// 鸿蒙 ArkTS 桥接验收通过后，`PlatformCapabilities.supportsNativeWidget`
/// 置为 true，[PlatformServices] 切换到真实实现（计划 12.4 末段）。
class NoopHomeCardService implements HomeCardService {
  const NoopHomeCardService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<void> syncCard({
    required String cardId,
    String? dataJson,
  }) async {}

  @override
  Future<void> syncCourseCard(Map<String, Object?> data) async {}

  @override
  Future<void> syncExamCard(Map<String, Object?> data) async {}

  @override
  Future<void> syncCompetitionCard(Map<String, Object?> data) async {}

  @override
  Future<void> refreshCards() async {}

  @override
  Future<void> openCardSettings() async {}

  @override
  Future<void> clearAllCards() async {}

  @override
  Future<void> dispose() async {}
}
