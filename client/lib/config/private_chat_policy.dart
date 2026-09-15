/// 私聊能力总开关。
///
/// 私聊被整体暂停开放：服务端通过 `PRIVATE_CHAT_DISABLED` 环境变量让
/// `/api/messages/*` 全部返回 410，本开关负责同步隐藏客户端的所有入口，
/// 避免用户点进去之后才看到错误提示。
///
/// 恢复方式：把 [enabled] 改回 `true` 并重新打包，同时把服务端的
/// `PRIVATE_CHAT_DISABLED` 置为 `false`（或删除该环境变量）。
class PrivateChatPolicy {
  const PrivateChatPolicy._();

  /// 私聊能力总开关。为 `false` 时隐藏全部入口、跳转和推送处理。
  static const bool enabled = false;

  /// 关闭期间对用户展示的统一文案。
  static const String disabledHint = '私聊功能已暂停开放';
}
