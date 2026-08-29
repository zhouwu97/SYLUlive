import 'package:dio/dio.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

import '../campus_data/erke/erke_models.dart';
import '../campus_data/storage/account_cache_namespace.dart';

/// 二课快照的上传授权策略。仅本次上传不写入偏好，其他策略按 App 账号隔离保存。
enum ErkeSnapshotUploadPolicy {
  uploadThisTime,
  askEveryUpdate,
  autoUploadSummary,
  neverUpload,
}

/// 提供当前二课上传策略，避免同步协调器依赖页面交互或偏好存储实现。
abstract interface class ErkeSnapshotUploadPolicyStore {
  Future<ErkeSnapshotUploadPolicy> read();
  Future<void> write(ErkeSnapshotUploadPolicy policy);
}

/// 将策略绑定到当前 App 账号；不保存学号、二课数据或任何凭据。
class PreferenceErkeSnapshotUploadPolicyStore
    implements ErkeSnapshotUploadPolicyStore {
  PreferenceErkeSnapshotUploadPolicyStore({required String appUserId})
      : _key =
            'erke_snapshot_upload_policy.${AccountCacheNamespace.fingerprint(appUserId)}';

  final String _key;

  @override
  Future<ErkeSnapshotUploadPolicy> read() async {
    final preferences = await AppPreferencesStore.getInstance();
    return switch (preferences.getString(_key)) {
      'auto_upload_summary' => ErkeSnapshotUploadPolicy.autoUploadSummary,
      'never_upload' => ErkeSnapshotUploadPolicy.neverUpload,
      _ => ErkeSnapshotUploadPolicy.askEveryUpdate,
    };
  }

  @override
  Future<void> write(ErkeSnapshotUploadPolicy policy) async {
    final preferences = await AppPreferencesStore.getInstance();
    switch (policy) {
      case ErkeSnapshotUploadPolicy.autoUploadSummary:
        await preferences.setString(_key, 'auto_upload_summary');
        return;
      case ErkeSnapshotUploadPolicy.neverUpload:
        await preferences.setString(_key, 'never_upload');
        return;
      case ErkeSnapshotUploadPolicy.askEveryUpdate:
        await preferences.remove(_key);
        return;
      case ErkeSnapshotUploadPolicy.uploadThisTime:
        throw ArgumentError('仅本次上传不能作为持久化策略');
    }
  }
}

/// 二课结构化快照上传失败时的稳定错误类型，不暴露服务端响应正文。
class ErkeSnapshotUploadException implements Exception {
  const ErkeSnapshotUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 发送到服务端的最小化二课结构化快照。
///
/// 只包含校园 Agent 生成二课概览所需的汇总、分类缺口和最近活动摘要，
/// 不会从本地缓存透传密码、Cookie、会话、HTML 或完整活动历史。
class ErkeSnapshotUploadPayload {
  const ErkeSnapshotUploadPayload._(this._value);

  final Map<String, dynamic> _value;

  factory ErkeSnapshotUploadPayload.fromSnapshot(ErkeSnapshot snapshot) {
    final graduation = snapshot.graduation;
    final yearly = snapshot.yearly;
    return ErkeSnapshotUploadPayload._(<String, dynamic>{
      'schema_version': 2,
      'fetched_at':
          (snapshot.fetchedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'graduation': <String, dynamic>{
        if (graduation != null) ...<String, dynamic>{
          'earned_total': graduation.earnedTotal,
          'required_total': graduation.requiredTotal,
          'graduation_gap': graduation.graduationGap,
          'unmet_categories': graduation.categories
              .where((category) => category.gap > 0)
              .take(16)
              .map((category) => <String, dynamic>{
                    'name': category.name,
                    'gap': category.gap,
                  })
              .toList(growable: false),
          'official_conclusion': graduation.officialConclusion,
        },
      },
      'yearly': <String, dynamic>{
        if (yearly != null) ...<String, dynamic>{
          'year': yearly.year,
          'earned_total': yearly.yearEarnedTotal,
          'required_total': yearly.requiredTotal,
          'yearly_gap': yearly.minimumGap,
          'official_conclusion': yearly.officialConclusion,
        },
      },
      'recent_activities': snapshot.activities
          .take(20)
          .map((activity) => <String, dynamic>{
                'category': activity.category,
                'score': activity.scoreValue,
                'date': activity.date,
              })
          .toList(growable: false),
    });
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.unmodifiable(_value);
}

/// 调用已鉴权的服务端接口。Dio 由上层注入，复用当前用户的 JWT 请求头。
/// 路径不带 `/api` 前缀：Dio baseUrl 已含该前缀，重复书写会拼出 /api/api/。
class ErkeSnapshotUploadGateway {
  ErkeSnapshotUploadGateway(this._dio);

  final Dio _dio;

  Future<void> upload(ErkeSnapshot snapshot) async {
    try {
      final response = await _dio.put(
        '/personal-snapshots/erke',
        data: ErkeSnapshotUploadPayload.fromSnapshot(snapshot).toJson(),
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw const ErkeSnapshotUploadException('二课摘要上传失败');
      }
    } on ErkeSnapshotUploadException {
      rethrow;
    } on DioException {
      throw const ErkeSnapshotUploadException('二课摘要上传失败，请稍后重试');
    }
  }

  Future<void> delete() async {
    try {
      final response = await _dio.delete('/personal-snapshots/erke');
      if (response.statusCode != 204) {
        throw const ErkeSnapshotUploadException('删除已上传二课快照失败');
      }
    } on ErkeSnapshotUploadException {
      rethrow;
    } on DioException {
      throw const ErkeSnapshotUploadException('删除已上传二课快照失败，请稍后重试');
    }
  }
}
