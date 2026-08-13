import 'user.dart';
import 'post.dart';

// 回复模型
class Reply {
  final int id;
  final int postId;
  final int? parentReplyId;
  final int authorId;
  final String content;
  final String? stickerId;
  final String status;
  final int likeCount;
  final bool isLiked;
  final int? expEarned; // 服务器返回的本次经验值
  final List<ExpAward> expAwards;
  final List<ReplyImage> images;
  final User? author;
  final DateTime createdAt;

  Reply({
    required this.id,
    required this.postId,
    this.parentReplyId,
    required this.authorId,
    required this.content,
    this.stickerId,
    this.status = 'normal',
    this.likeCount = 0,
    this.isLiked = false,
    this.expEarned,
    this.expAwards = const [],
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
      stickerId: json['sticker_id']?.toString(),
      status: json['status'] ?? 'normal',
      likeCount: json['like_count'] ?? 0,
      isLiked: json['is_liked'] == true,
      expEarned: json['exp_earned'] != null
          ? (json['exp_earned'] as num).toInt()
          : null,
      expAwards: (json['exp_awards'] as List<dynamic>?)
              ?.map((e) => ExpAward.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => ReplyImage.fromJson(e))
              .toList() ??
          [],
      author: json['author'] != null ? User.fromJson(json['author']) : null,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  bool get hasSticker => stickerId?.trim().isNotEmpty == true;

  bool get hasTextContent {
    final text = content.trim();
    return text.isNotEmpty && !(hasSticker && text == '[表情]');
  }

  bool get isStickerOnly => hasSticker && !hasTextContent;

  bool get isMixedTextSticker => hasSticker && hasTextContent;

  // 兼容现有调用方；新渲染逻辑应根据纯表情或混合回复选择布局。
  bool get isSticker => hasSticker;

  String get stickerUrl => hasSticker ? '/stickers/$stickerId' : '';

  /// 创建副本，仅覆盖显式传入的字段；其余字段（含 parentReplyId、images、
  /// sticker、author、createdAt）完整保留。
  Reply copyWith({
    int? id,
    int? postId,
    int? parentReplyId,
    int? authorId,
    String? content,
    String? stickerId,
    String? status,
    int? likeCount,
    bool? isLiked,
    int? expEarned,
    List<ExpAward>? expAwards,
    List<ReplyImage>? images,
    User? author,
    DateTime? createdAt,
  }) {
    return Reply(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      parentReplyId: parentReplyId ?? this.parentReplyId,
      authorId: authorId ?? this.authorId,
      content: content ?? this.content,
      stickerId: stickerId ?? this.stickerId,
      status: status ?? this.status,
      likeCount: likeCount ?? this.likeCount,
      isLiked: isLiked ?? this.isLiked,
      expEarned: expEarned ?? this.expEarned,
      expAwards: expAwards ?? this.expAwards,
      images: images ?? this.images,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
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
