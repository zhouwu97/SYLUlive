import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/account_session_cleanup_coordinator.dart';

/// 私信（私有媒体）专属缓存，与公开帖子图片缓存隔离。
///
/// - 短生命周期、小容量，只服务私信图片气泡与全屏查看。
/// - 按账号作用域：缓存 Key 格式为 `pm:<accountId>:<url>`，禁止跨账号读取或泄露凭据。
/// - 退出/换号清理：通过 [AccountSessionCleanupCoordinator] 在退出/换号时统一清空底层物理缓存。
class PrivateMessageMediaCache {
  PrivateMessageMediaCache._() {
    AccountSessionCleanupCoordinator.instance.register(this, clearAll);
  }

  static final PrivateMessageMediaCache instance =
      PrivateMessageMediaCache._();

  CacheManager? _defaultManager;
  CacheManager? _customManager;
  int? _accountId;

  CacheManager get manager {
    if (_customManager != null) return _customManager!;
    final cacheName = _accountId != null
        ? 'private_message_media_cache_$_accountId'
        : 'private_message_media_cache_anon';
    return _defaultManager ??= CacheManager(
      Config(
        cacheName,
        stalePeriod: const Duration(days: 3),
        maxNrOfCacheObjects: 128,
      ),
    );
  }

  @visibleForTesting
  set customManager(CacheManager? customManager) {
    _customManager = customManager;
  }

  int? get accountId => _accountId;

  /// 生成账号作用域的缓存 key。
  ///
  /// 规范格式：`pm:<accountId>:<url>`（未登录或匿名使用 `pm:anon:<url>`）。
  /// 绝不把 Bearer Token / JWT / 敏感认证信息拼入 key。
  static String cacheKeyFor(String url, {int? accountId}) {
    final effectiveId = accountId ?? instance.accountId;
    final prefix = effectiveId != null ? 'pm:$effectiveId:' : 'pm:anon:';
    return '$prefix$url';
  }

  /// 实例快捷方法，等价于 [PrivateMessageMediaCache.cacheKeyFor]。
  String buildCacheKey(String url, {int? accountId}) {
    return cacheKeyFor(url, accountId: accountId);
  }

  /// 会话用户变化时调用：账号切换后清空缓存，不跨账号复用私信媒体。
  void scopeByAccount(int? accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    final oldManager = _defaultManager;
    final custom = _customManager;
    _defaultManager = null;
    if (oldManager != null || custom != null) {
      unawaited(() async {
        try {
          if (oldManager != null) {
            await oldManager.emptyCache();
          }
          if (custom != null) {
            await custom.emptyCache();
          }
        } catch (_) {
          // 清空缓存失败不影响业务
        }
      }());
    }
  }

  Future<void> clearAll() async {
    final oldDefault = _defaultManager;
    final custom = _customManager;
    _defaultManager = null;
    if (custom == null && oldDefault == null) {
      return;
    }
    try {
      if (custom != null) {
        await custom.emptyCache();
      }
      if (oldDefault != null) {
        await oldDefault.emptyCache();
      }
    } catch (_) {
      // 清空缓存失败不影响业务，下次请求会重新拉取。
    }
  }
}
