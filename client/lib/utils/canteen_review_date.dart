/// 保留首次发布时间，避免把编辑旧评价误认为一次新的就餐评价。
String formatCanteenReviewDate(DateTime? createdAt, DateTime? updatedAt) {
  if (createdAt == null) return '';
  String date(DateTime value) {
    final local = value.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  final published = '${date(createdAt)} 发布';
  // 沿用评价记录页的一秒容差，忽略创建时数据库时间精度造成的微小差异。
  if (updatedAt == null ||
      updatedAt.difference(createdAt) <= const Duration(seconds: 1)) {
    return published;
  }
  return '$published · ${date(updatedAt)} 更新';
}
