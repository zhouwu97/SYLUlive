import '../../../campus_data/storage/account_cache_namespace.dart';

/// Gateway 创建时固定的当前账号上下文，外部调用方不能在读取时替换账号。
class PersonalAccountContext {
  PersonalAccountContext({
    required String appUserId,
    required String sourceAccountId,
  })  : appUserId = appUserId.trim(),
        sourceAccountId = sourceAccountId.trim() {
    if (this.appUserId.isEmpty || this.sourceAccountId.isEmpty) {
      throw ArgumentError('个人数据 Gateway 缺少有效账号上下文');
    }
  }

  final String appUserId;
  final String sourceAccountId;

  String get appUserFingerprint => AccountCacheNamespace.fingerprint(appUserId);
}
