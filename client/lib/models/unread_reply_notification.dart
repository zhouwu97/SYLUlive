import 'package:shenliyuan/models/user.dart';

class UnreadReplyNotification {
  final int id;
  final int postId;
  final int relatedId;
  final String content;
  final String postTitle;
  final DateTime createdAt;
  final User? fromUser;

  UnreadReplyNotification({
    required this.id,
    required this.postId,
    required this.relatedId,
    required this.content,
    this.postTitle = '',
    required this.createdAt,
    this.fromUser,
  });

  factory UnreadReplyNotification.fromJson(Map<String, dynamic> json) {
    final rawFromUser = json['from_user'];
    return UnreadReplyNotification(
      id: (json['id'] as num?)?.toInt() ?? 0,
      postId: (json['post_id'] as num?)?.toInt() ?? 0,
      relatedId: (json['related_id'] as num?)?.toInt() ?? 0,
      content: json['content']?.toString() ?? '',
      postTitle: json['post_title']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      fromUser: rawFromUser is Map<String, dynamic>
          ? User.fromJson(rawFromUser)
          : null,
    );
  }

  UnreadReplyNotification copyWith({String? postTitle}) {
    return UnreadReplyNotification(
      id: id,
      postId: postId,
      relatedId: relatedId,
      content: content,
      postTitle: postTitle ?? this.postTitle,
      createdAt: createdAt,
      fromUser: fromUser,
    );
  }
}
