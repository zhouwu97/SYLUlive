/// 管理员端特性开关配置。
///
/// 审核系统架构规范：
/// - 教师审核、专业审核、试卷审核、精华申请、版块图标审核正常在线并具备待办红点；
/// - 菜品与实拍审核必须保留待办、通过、驳回、合并和下架日志。
class AdminFeatureFlags {
  const AdminFeatureFlags._();

  /// 菜品与实拍审核开关。
  static const bool canteenDishPhotoReviewEnabled = true;
}
