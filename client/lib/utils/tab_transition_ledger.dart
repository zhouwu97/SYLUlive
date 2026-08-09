/// Root Tab 转场的状态账本。
///
/// 页面是否已创建（visited）与首次 reveal 是否已消费（revealed）必须分开
/// 保存。每次新的目标都会递增 serial，旧的异步动画完成时只能提交当前
/// serial，避免 A → B → C retarget 把过期状态写回页面。
class TabTransitionPlan {
  const TabTransitionPlan({
    required this.serial,
    required this.targetIndex,
    required this.commit,
    required this.shouldReveal,
  });

  final int serial;
  final int targetIndex;
  final bool commit;
  final bool shouldReveal;
}

class TabTransitionLedger {
  TabTransitionLedger({
    required this.itemCount,
    required int initialIndex,
  })  : assert(itemCount > 0),
        assert(initialIndex >= 0 && initialIndex < itemCount),
        currentIndex = initialIndex,
        visualIndex = initialIndex.toDouble(),
        visitedTabs = {initialIndex},
        revealedTabs = {initialIndex};

  final int itemCount;
  final Set<int> visitedTabs;
  final Set<int> revealedTabs;

  int currentIndex;
  double visualIndex;
  int? targetIndex;
  int serial = 0;

  TabTransitionPlan begin(
    int target, {
    required bool commit,
    required double visualStart,
  }) {
    _assertValidIndex(target);
    final requestSerial = ++serial;
    final shouldReveal = commit && !revealedTabs.contains(target);
    visitedTabs.add(target);
    targetIndex = target;
    visualIndex = visualStart;
    if (commit) currentIndex = target;
    return TabTransitionPlan(
      serial: requestSerial,
      targetIndex: target,
      commit: commit,
      shouldReveal: shouldReveal,
    );
  }

  /// 取消当前请求并恢复到已提交 Tab。用于重复点击、手势取消和边界返回。
  void cancel() {
    serial++;
    targetIndex = null;
    visualIndex = currentIndex.toDouble();
  }

  bool isCurrent(int requestSerial) => serial == requestSerial;

  bool complete(TabTransitionPlan plan) {
    if (!isCurrent(plan.serial)) return false;
    if (plan.commit && plan.shouldReveal) {
      revealedTabs.add(plan.targetIndex);
    }
    targetIndex = null;
    visualIndex = currentIndex.toDouble();
    return true;
  }

  void _assertValidIndex(int index) {
    assert(index >= 0 && index < itemCount);
  }
}
