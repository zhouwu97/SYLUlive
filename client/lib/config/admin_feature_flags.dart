/// 管理员端特性开关配置。
///
/// 当 reviewEnabled 为 false 时：
/// - 暂时下线审核代办区块（教师/专业/试卷/实拍/图标等审核），隐藏无用待办红点；
/// - 完整保留举报处理、水帖版块管理、操作日志与管理员协作能力。
class AdminFeatureFlags {
  const AdminFeatureFlags._();

  /// 审核模块总开关
  static const bool reviewEnabled = false;
}
