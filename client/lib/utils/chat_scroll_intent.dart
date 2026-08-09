/// 聊天滚动的业务意图，避免通用函数猜测滚动原因。
enum ChatScrollIntent {
  /// 用户刚发送自己的消息，不需要动画等待。
  ownSend,

  /// 对方消息到达且用户已经接近底部，可以短暂 settle。
  incomingNearBottom,

  /// 页面状态恢复，不属于动画事件。
  restore,

  /// 用户主动定位某条历史消息，需要空间解释和轻量 highlight。
  messageFocus,
}

extension ChatScrollIntentBehavior on ChatScrollIntent {
  /// 自己发送、恢复位置和 Reduced Motion 都必须即时落位，不能使用
  /// `animateTo(duration: Duration.zero)` 伪装成动画。
  bool usesJumpScroll({required bool reduceMotion}) {
    return reduceMotion ||
        this == ChatScrollIntent.ownSend ||
        this == ChatScrollIntent.restore;
  }

  /// messageFocus 的唯一验收行为：滚到目标并短暂高亮目标消息。
  bool get showsFocusHighlight => this == ChatScrollIntent.messageFocus;

  bool usesAnimatedFocus({required bool reduceMotion}) {
    return showsFocusHighlight && !reduceMotion;
  }
}
