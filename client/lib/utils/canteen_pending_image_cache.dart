import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/account_session_cleanup_coordinator.dart';

/// 待审核食堂图片专属私有缓存，与公开帖子图片缓存（PostImageCache）严格物理隔离。
///
/// 特性：
/// - 专属独立的 [CacheManager]，禁止放入公开 `PostImageCache`；
/// - 账号作用域：缓存 Key 格式为 `canteen_pending:<accountId>:<url>`，避免管理员切换账号后私有缓存串号；
/// - 凭证安全：绝不将 Bearer Token 或 JWT 拼入 CacheKey；
/// - 会话清理：通过 [AccountSessionCleanupCoordinator] 在登出或切号时统一清空。
class CanteenPendingImageCache {
  CanteenPendingImageCache._() {
    AccountSessionCleanupCoordinator.instance.register(this, clearAll);
  }

  static final CanteenPendingImageCache instance =
      CanteenPendingImageCache._();

  CacheManager? _defaultManager;
  CacheManager? _customManager;
  int? _accountId;

  CacheManager get manager {
    if (_customManager != null) return _customManager!;
    final cacheName = _accountId != null
        ? 'canteen_pending_image_cache_$_accountId'
        : 'canteen_pending_image_cache_anon';
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
  /// 规范格式：`canteen_pending:<accountId>:<url>`（未登录或匿名使用 `canteen_pending:anon:<url>`）。
  /// 绝不把 Bearer Token / JWT / 敏感认证信息拼入 key。
  static String cacheKeyFor(String url, {int? accountId}) {
    final effectiveId = accountId ?? instance.accountId;
    final prefix =
        effectiveId != null ? 'canteen_pending:$effectiveId:' : 'canteen_pending:anon:';
    return '$prefix$url';
  }

  /// 实例快捷方法，等价于 [CanteenPendingImageCache.cacheKeyFor]。
  String buildCacheKey(String url, {int? accountId}) {
    return cacheKeyFor(url, accountId: accountId);
  }

  /// 会话用户变化时调用：账号切换后清空缓存，不跨账号复用审核图片。
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
