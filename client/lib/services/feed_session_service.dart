import 'dart:math';

/// 首页 Feed 事件会话 ID 的生命周期（FEED-3）。
///
/// 与服务端 Snapshot 的 `session_id`（10 分钟分页快照）是**两个不同概念**：
/// 这里的 `feed_session_id` 只用于 FEED-2 事件归因。
///
/// 需要新建 session：
///   - 首次进入 Feed
///   - 手动下拉并真正应用新内容
///   - 点击「内容有更新」并应用
///   - 后台超过 30 分钟
///   - 切换账号
///
/// 不新建：
///   - freshness probe（只探测，未应用）
///   - 出现更新提示但没点击
///   - loadmore / 进入详情 / 返回详情 / 短暂后台
class FeedSessionService {
  FeedSessionService({int initialGeneration = 0})
      : _generation = initialGeneration;

  static const Duration staleAfter = Duration(minutes: 30);

  int _generation;
  String? _current;
  DateTime? _createdAt;

  /// 当前 feed_session_id；尚未创建（未进入 Feed）时为 null。
  String? get currentSessionId => _current;

  /// 当前 session 是否已超过 30 分钟（应新建）。
  bool get isStale {
    final created = _createdAt;
    if (created == null) return true;
    return DateTime.now().difference(created) > staleAfter;
  }

  /// 新建 session 并返回。
  ///
  /// 结合时间戳 + 自增 generation + 密码学随机数，避免引入额外 UUID 依赖。
  String newSession() {
    _generation++;
    final random = Random.secure();
    _current =
        '${DateTime.now().millisecondsSinceEpoch}_${_generation}_${random.nextInt(1 << 32)}';
    _createdAt = DateTime.now();
    return _current!;
  }

  /// 若当前 session 已过期（后台超时等），新建并返回；否则沿用现有。
  String freshSession() {
    if (_current == null || isStale) return newSession();
    return _current!;
  }

  /// 切换账号：彻底重置并新建 session。
  String resetForAccountChange() => newSession();
}
