/// 管理员端特性开关配置。
///
/// 审核系统架构规范：
/// - 教师审核、专业审核、试卷审核、精华申请、版块图标审核正常在线并具备待办红点；
/// - 菜品实拍已切换为学生端直接上传发布，无需管理员前置审核。
class AdminFeatureFlags {
  const AdminFeatureFlags._();

  /// 菜品实拍审核开关（菜品实拍已变更为直传入库，无需后台审核）
  static const bool canteenDishPhotoReviewEnabled = false;
}
