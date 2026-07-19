import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 为个人数据缓存生成不可逆的账号命名空间。
abstract final class AccountCacheNamespace {
  static String fingerprint(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '';
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  static String erkeSnapshot(String appUserId) {
    return 'erke/${fingerprint(appUserId)}/snapshot/v2';
  }

  static String erkeNeedsResync(String appUserId) {
    return 'erke/${fingerprint(appUserId)}/needs_resync/v2';
  }

  static String physicalSnapshot(
    String appUserId,
    String sourceAccountId,
    String year,
  ) {
    return 'physical/${fingerprint(appUserId)}/'
        '${fingerprint(sourceAccountId)}/$year';
  }

  static String physicalNeedsResync(String appUserId) {
    return 'physical/${fingerprint(appUserId)}/needs_resync/v2';
  }
}
