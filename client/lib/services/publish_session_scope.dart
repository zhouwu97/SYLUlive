/// 发布写请求的会话边界。
///
/// 用户点击提交的那一刻捕获账号 ID 与会话代次，把它贯穿图片处理、上传和最终写入。
/// 认证拦截器会在真正发请求前再确认一次（`expectedAuthSessionEpoch` /
/// `expectedAuthUserId`），所以「A 开始发布 → 等图片 → 切到 B → 旧流程继续」
/// 不会以 B 的身份上传或落库。
///
/// 水帖与集市共用这一个定义：两处各自实现同一套检查，迟早会有一处漏掉某个异步边界。
final class PublishSessionScope {
  const PublishSessionScope({
    required this.accountId,
    required this.accountSessionEpoch,
  });

  final int accountId;
  final int accountSessionEpoch;

  /// 是否仍由发起操作的那个账号会话持有。
  bool owns({required int? userId, required int sessionEpoch}) =>
      userId == accountId && sessionEpoch == accountSessionEpoch;

  /// 请求体之外的会话预期：拦截器据此在发送前拦截跨会话写入。
  Map<String, dynamic> get requestExtra => <String, dynamic>{
        'expectedAuthUserId': accountId,
        'expectedAuthSessionEpoch': accountSessionEpoch,
      };

  /// 确认会话未变；变了就抛 [PublishSessionChanged]，让调用方中止本次发布。
  void ensure({required int? userId, required int sessionEpoch}) {
    if (!owns(userId: userId, sessionEpoch: sessionEpoch)) {
      throw const PublishSessionChanged();
    }
  }
}

/// 发布过程中登录状态已变化：本次操作属于旧账号，必须整体取消。
final class PublishSessionChanged implements Exception {
  const PublishSessionChanged();
}
