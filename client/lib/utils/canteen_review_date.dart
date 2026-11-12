/// 评价只展示一个时间：编辑过的显示“更新”，否则显示“发布”，用“更新”字样区分，
/// 避免把编辑旧评价误认为一次新的就餐评价。
String formatCanteenReviewDate(DateTime? createdAt, DateTime? updatedAt) {
  if (createdAt == null) return '';
  String date(DateTime value) {
    final local = value.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  // 沿用评价记录页的一秒容差，忽略创建时数据库时间精度造成的微小差异。
  // 只显示一个时间：改过的评价显示最后更新时间，没改过的显示发布时间。
  if (updatedAt == null ||
      updatedAt.difference(createdAt) <= const Duration(seconds: 1)) {
    return '${date(createdAt)} 发布';
  }
  return '${date(updatedAt)} 更新';
}
