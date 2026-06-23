import 'user.dart';
import 'post.dart';

// 回复模型
class Reply {
  final int id;
  final int postId;
  final int? parentReplyId;
  final int authorId;
  final String content;
  final String status;
  final int likeCount;
  final bool isLiked;
  final List<ReplyImage> images;
  final User? author;
  final DateTime createdAt;

  Reply({
    required this.id,
    required this.postId,
    this.parentReplyId,
    required this.authorId,
    required this.content,
    this.status = 'normal',
    this.likeCount = 0,
    this.isLiked = false,
    this.images = const [],
    this.author,
    required this.createdAt,
  });

  factory Reply.fromJson(Map<String, dynamic> json) {
    return Reply(
      id: json['id'] ?? 0,
      postId: json['post_id'] ?? 0,
      parentReplyId: json['parent_reply_id'],
      authorId: json['author_id'] ?? 0,
      content: json['content'] ?? '',
      status: json['status'] ?? 'normal',
      likeCount: json['like_count'] ?? 0,
      isLiked: json['is_liked'] == true,
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => ReplyImage.fromJson(e))
              .toList() ??
          [],
      author: json['author'] != null ? User.fromJson(json['author']) : null,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}

// 回复图片模型
class ReplyImage {
  final int id;
  final int replyId;
  final int fileId;
  final int sortOrder;
  final FileItem? file;

  ReplyImage({
    required this.id,
    required this.replyId,
    required this.fileId,
    this.sortOrder = 0,
    this.file,
  });

  factory ReplyImage.fromJson(Map<String, dynamic> json) {
    return ReplyImage(
      id: json['id'] ?? 0,
      replyId: json['reply_id'] ?? 0,
      fileId: json['file_id'] ?? 0,
      sortOrder: json['sort_order'] ?? 0,
      file: json['file'] != null ? FileItem.fromJson(json['file']) : null,
    );
  }
}

class FileItem {
  final int id;
  final String hash;
  final String path;
  final int size;
  final String mimeType;

  FileItem({
    required this.id,
    required this.hash,
    required this.path,
    required this.size,
    required this.mimeType,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      id: json['id'] ?? 0,
      hash: json['hash'] ?? '',
      path: json['path'] ?? '',
      size: json['size'] ?? 0,
      mimeType: json['mime_type'] ?? '',
    );
  }

  String get url => path;
}
