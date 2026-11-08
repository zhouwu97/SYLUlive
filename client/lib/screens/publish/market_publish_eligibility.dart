/// 集市发帖所需的可信凭据：**服务器可独立核验的学生身份**。
///
/// 原教务绑定链路会向学校核验后自动登记，配置或本机标记本身不授予权限。
const marketPublishRequiredCredential = '教务绑定同步完成';

/// 集市发布被拒时的用户侧说明。
///
/// [studentVerified] 为 false 只表示缺少上面那项凭据，**与"毕业"无关**。
/// 历史文案把记录缺失误报为毕业；原教务绑定入口负责核验和自动补交。
///
/// [hasLocalAcademicConnection] 用来区分"已连接教务但未认证"和"什么都没有"，
/// 两者的下一步不一样，不能共用一句话。
///
String marketPublishBlockedMessage({required bool hasLocalAcademicConnection}) {
  const entry = '可到「账号安全 - 教务身份与本机连接」查看同步状态';
  const retryHint = '联网后刷新课表会自动核验补交；学校会话失效时在原教务入口重连，无需反复重新绑定';
  if (hasLocalAcademicConnection) {
    return '集市发帖需要$marketPublishRequiredCredential。'
        '本机已连接教务，服务器绑定记录尚未同步完成。'
        '$retryHint。$entry。';
  }
  return '集市发帖需要$marketPublishRequiredCredential。'
      '请在原教务入口连接账号，登录成功后自动登记。$entry，无需单独认证。';
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
