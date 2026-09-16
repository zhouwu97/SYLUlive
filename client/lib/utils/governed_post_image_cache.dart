import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/account_session_cleanup_coordinator.dart';

/// 治理隐藏帖子（`moderated_hidden`）图片的专属私有缓存。
///
/// 帖子被治理隐藏时，服务端 `ReconcileFilePublicAccess` 会把没有其他公开引用的
/// 文件从 public 降级为 private —— 这是正确的安全设计，客户端**不得**为了
/// 「图片能显示」而把资源重新读成公开。降级之后 `/uploads` 只对两类人放行
/// （见服务端 `isAuthorizedForPrivateFile`）：管理员，以及文件 uploader 本人
/// （帖子作者）。因此客户端必须以鉴权方式加载：
///
/// - 携带 `Authorization: Bearer <JWT>`；
/// - 使用本类提供的专属 [CacheManager]，**禁止**落入公开 [PostImageCache]；
/// - 使用账号作用域的 cacheKey，避免切号后读到上一个账号的私有图片；
/// - 通过 [AccountSessionCleanupCoordinator] 在登出/换号时统一清空。
///
/// 与 [CanteenPendingImageCache] 保持物理隔离的原因：治理图片回源的
/// thumb/medium/viewer 变体路径与公开帖子图片完全同名，共用缓存目录会互相污染，
/// 一旦被污染，公开流可能命中私有响应、私有页也可能命中已被降权的旧副本。
class GovernedPostImageCache {
  GovernedPostImageCache._() {
    AccountSessionCleanupCoordinator.instance.register(this, clearAll);
  }

  static final GovernedPostImageCache instance = GovernedPostImageCache._();

  static const String _keyPrefix = 'governed_post';

  CacheManager? _defaultManager;
  CacheManager? _customManager;
  int? _accountId;

  CacheManager get manager {
    if (_customManager != null) return _customManager!;
    final cacheName = _accountId != null
        ? 'governed_post_image_cache_$_accountId'
        : 'governed_post_image_cache_anon';
    return _defaultManager ??= _GovernedPostImageCacheManager(
      Config(
        cacheName,
        // 治理帖生命周期由管理员复审决定，缓存只服务一次审核会话，短 TTL
        // 可以避免「已恢复公开的帖子仍从私有目录读旧副本」。
        stalePeriod: const Duration(days: 3),
        maxNrOfCacheObjects: 128,
      ),
    );
  }

  @visibleForTesting
  set customManager(CacheManager? customManager) {
    _customManager = customManager;
  }

  /// 缓存管理器绑定创建时的磁盘目录；目录被删除后实例会静默失效
  /// （加载不产生任何事件）。测试中 mock 目录随 teardown 删除，必须重建。
  @visibleForTesting
  void resetManager() {
    _defaultManager = null;
  }

  int? get accountId => _accountId;

  /// 生成账号作用域的缓存 key。
  ///
  /// 规范格式：`governed_post:<accountId>:<url>`；未登录时使用
  /// `governed_post:anon:<url>`。绝不把 Bearer Token / JWT 拼入 key ——
  /// 缓存 key 会落到磁盘文件名，凭证不能进入文件名。
  static String cacheKeyFor(String url, {int? accountId}) {
    final effectiveId = accountId ?? instance.accountId;
    final prefix = effectiveId != null
        ? '$_keyPrefix:$effectiveId:'
        : '$_keyPrefix:anon:';
    return '$prefix$url';
  }

  /// 会话用户变化时调用：账号切换后清空缓存，不跨账号复用私有图片。
  void scopeByAccount(int? accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    final oldManager = _defaultManager;
    final custom = _customManager;
    _defaultManager = null;
    if (oldManager != null || custom != null) {
      unawaited(() async {
        try {
          if (oldManager != null) await oldManager.emptyCache();
          if (custom != null) await custom.emptyCache();
        } catch (_) {
          // 清空缓存失败不影响业务，下次请求会重新拉取。
        }
      }());
    }
  }

  Future<void> clearAll() async {
    final oldDefault = _defaultManager;
    final custom = _customManager;
    _defaultManager = null;
    if (custom == null && oldDefault == null) return;
    try {
      if (custom != null) await custom.emptyCache();
      if (oldDefault != null) await oldDefault.emptyCache();
    } catch (_) {
      // 清空缓存失败不影响业务，下次请求会重新拉取。
    }
  }
}

/// 治理帖图片缓存同样要支持磁盘尺寸约束。
///
/// `cached_network_image` 在收到 `maxWidthDiskCache` / `maxHeightDiskCache` 时会
/// `assert(cacheManager is ImageCacheManager || ...)`：普通 [CacheManager] 在 debug
/// 构建下会直接抛断言。治理帖缩略图（我的内容集市封面、列表小图）会传磁盘尺寸，
/// 因此这里必须与公开缓存 [PostImageCache] 一样混入 [ImageCacheManager]。
class _GovernedPostImageCacheManager extends CacheManager with ImageCacheManager {
  _GovernedPostImageCacheManager(super.config);
}
