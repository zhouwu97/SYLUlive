import 'package:shenliyuan/models/user.dart';

class UnreadReplyNotification {
  final int id;
  final int postId;
  final int relatedId;
  final String content;
  final DateTime createdAt;
  final User? fromUser;

  UnreadReplyNotification({
    required this.id,
    required this.postId,
    required this.relatedId,
    required this.content,
    required this.createdAt,
    this.fromUser,
  });

  factory UnreadReplyNotification.fromJson(Map<String, dynamic> json) {
    return UnreadReplyNotification(
      id: json['id'] as int,
      postId: json['post_id'] as int,
      relatedId: json['related_id'] as int,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      fromUser: json['from_user'] != null
          ? User.fromJson(json['from_user'] as Map<String, dynamic>)
          : null,
    );
  }
}
