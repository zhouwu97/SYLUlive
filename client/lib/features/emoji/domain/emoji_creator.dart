String emojiCreatorStatus(String status) => switch (status) {
      'none' => '尚未申请',
      'pending' => '申请待审核',
      'active' => '创作者权限已开通',
      'rejected' => '申请已驳回',
      'suspended' => '创作者权限已暂停',
      _ => '状态未知'
    };

class EmojiCreator {
  const EmojiCreator(
      {required this.status,
      this.userId = 0,
      this.version = 0,
      this.description = '',
      this.reviewReason = ''});
  final String status, description, reviewReason;
  final int userId, version;
  bool get active => status == 'active';
  factory EmojiCreator.fromJson(Map<String, dynamic> json) => EmojiCreator(
      status: json['status'] as String,
      userId: json['user_id'] as int? ?? 0,
      version: json['version'] as int? ?? 0,
      description: json['description'] as String? ?? '',
      reviewReason: json['review_reason'] as String? ?? '');
}

class EmojiCreatorPage {
  const EmojiCreatorPage(this.items, this.total);
  final List<EmojiCreator> items;
  final int total;
}
