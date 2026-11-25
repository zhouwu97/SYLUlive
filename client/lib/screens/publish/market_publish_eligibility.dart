const marketPublishRequiredCredential = '教务配置已登记';

String marketPublishBlockedMessage({required bool hasLocalAcademicConnection}) {
  return hasLocalAcademicConnection
      ? '集市发帖要求$marketPublishRequiredCredential。本机已连接教务，请联网后在教务入口同步配置。'
      : '集市发帖要求$marketPublishRequiredCredential。请在教务入口连接本科或研究生账号。';
}

/// 服务端拒绝集市发布时的统一说明。
///
/// 服务端只回答"能不能发"，不判断学历；客户端同样不能把缺认证说成毕业。
String marketPublishServerDeniedMessage(String? serverMessage) {
  final detail = serverMessage?.trim() ?? '';
  // 旧服务端把缺少可信身份误报为毕业；升级客户端期间仍可能收到旧提示。
  // 仅兼容旧准入文案，账号限制、上传失败等其他错误继续保留原说明。
  final isLegacyGraduationDenial = detail == 'market_graduated' ||
      detail.contains('毕业用户仅可发布普通帖子') ||
      detail.contains('毕业生暂不能发布集市帖子');
  if (detail.isEmpty || isLegacyGraduationDenial) {
    return marketPublishBlockedMessage(hasLocalAcademicConnection: false);
  }
  // 服务端已经给出可执行说明时直接透传，不再叠一层猜测。
  return detail;
}
