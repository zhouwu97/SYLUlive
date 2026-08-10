/// 打开 / 停留（open / dwell）事件归因上下文（FEED-3）。
///
/// 从 Feed 卡点击进入详情时携带：记录 open；离开详情时记录 dwell。
/// 桌面分屏切换卡片时也要先 finalize 上一张的 dwell、再记新卡的 open。
class FeedOriginContext {
  const FeedOriginContext({
    required this.feedSessionId,
    required this.feedKind,
    required this.position,
    required this.algorithmVersion,
  });

  final String feedSessionId;
  final String feedKind;
  final int position;
  final String algorithmVersion;
}
