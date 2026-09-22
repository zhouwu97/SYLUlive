/// 集市发帖所需的可信凭据：**服务器可独立核验的学生身份**。
///
/// 本机教务连接、教务账号配置、本机登录成功声明都不构成这个凭据——它们只证明
/// 「这台设备上登录成功过」，服务器无法独立核验。
const marketPublishRequiredCredential = '服务器学生认证';

/// 集市发布被拒时的用户侧说明。
///
/// [studentVerified] 为 false 只表示缺少上面那项凭据，**与"毕业"无关**。
/// 历史文案写成"毕业用户仅可发布普通帖子"，用户会拿着学历问题去反复重绑教务，
/// 而真正缺的是一个能用的认证入口。
///
/// [hasLocalAcademicConnection] 用来区分"已连接教务但未认证"和"什么都没有"，
/// 两者的下一步不一样，不能共用一句话。
///
/// 这里不承诺存在可用的认证入口：学校侧认证退役或冻结时，challenge/verify
/// 都不可用，此时应当说明限制和查询位置，而不是诱导用户反复重新绑定。
String marketPublishBlockedMessage({required bool hasLocalAcademicConnection}) {
  const entry = '请到「账号安全 - 教务身份与本机连接」查看当前可用的认证方式';
  const noEntryHint = '若当前未开放认证，请留意公告，无需反复重新绑定';
  if (hasLocalAcademicConnection) {
    return '集市发帖需要$marketPublishRequiredCredential。'
        '本机已连接教务，但本机连接不构成学生认证，所以暂时不能在集市发帖。'
        '$entry；$noEntryHint。';
  }
  return '集市发帖需要$marketPublishRequiredCredential，当前账号还没有完成认证，'
      '暂时不能在集市发帖。$entry；$noEntryHint。';
}

/// 服务端拒绝集市发布时的统一说明。
///
/// 服务端只回答"能不能发"，不判断学历；客户端同样不能把缺认证说成毕业。
String marketPublishServerDeniedMessage(String? serverMessage) {
  final detail = serverMessage?.trim() ?? '';
  if (detail.isEmpty) {
    return marketPublishBlockedMessage(hasLocalAcademicConnection: false);
  }
  // 服务端已经给出可执行说明时直接透传，不再叠一层猜测。
  return detail;
}
