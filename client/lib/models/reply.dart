import 'user.dart';
import 'post.dart';

// 回复模型
class Reply {
  final int id;
  final int postId;
  final int? parentReplyId;
  final int? replyToUserId;
  final int? replyToReplyId;
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

  /// 仅根评论：真实子回复总数（列表可能只携带前 N 条，其余懒加载）。
  final int childReplyCount;

  Reply({
    required this.id,
    required this.postId,
    this.parentReplyId,
    this.replyToUserId,
    this.replyToReplyId,
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
    this.childReplyCount = 0,
  });

  bool get isDeleted => status == 'deleted';

  factory Reply.fromJson(Map<String, dynamic> json) {
    return Reply(
      id: json['id'] ?? 0,
      postId: json['post_id'] ?? 0,
      parentReplyId: json['parent_reply_id'],
      replyToUserId: json['reply_to_user_id'],
      replyToReplyId: json['reply_to_reply_id'],
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
      childReplyCount: (json['child_reply_count'] as num?)?.toInt() ?? 0,
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
    int? replyToUserId,
    int? replyToReplyId,
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
    int? childReplyCount,
  }) {
    return Reply(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      parentReplyId: parentReplyId ?? this.parentReplyId,
      replyToUserId: replyToUserId ?? this.replyToUserId,
      replyToReplyId: replyToReplyId ?? this.replyToReplyId,
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
      childReplyCount: childReplyCount ?? this.childReplyCount,
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
  final String thumbUrl;
  final String mediumUrl;
  final String viewerUrl;
  final String originUrl;

  /// 服务端图片变体状态。只有 `ready` 变体才可作为普通预览资源。
  final Map<String, String> variantStatus;

  ReplyImage({
    required this.id,
    required this.replyId,
    required this.fileId,
    this.sortOrder = 0,
    this.file,
    this.thumbUrl = '',
    this.mediumUrl = '',
    this.viewerUrl = '',
    this.originUrl = '',
    this.variantStatus = const {},
  });

  factory ReplyImage.fromJson(Map<String, dynamic> json) {
    final fileJson = json['file'];
    return ReplyImage(
      id: json['id'] ?? 0,
      replyId: json['reply_id'] ?? 0,
      fileId: json['file_id'] ?? 0,
      sortOrder: json['sort_order'] ?? 0,
      file: fileJson != null ? FileItem.fromJson(fileJson) : null,
      thumbUrl: json['thumb_url']?.toString() ??
          (fileJson is Map ? fileJson['thumb_url']?.toString() : null) ??
          '',
      mediumUrl: json['medium_url']?.toString() ??
          (fileJson is Map ? fileJson['medium_url']?.toString() : null) ??
          '',
      viewerUrl: json['viewer_url']?.toString() ??
          (fileJson is Map ? fileJson['viewer_url']?.toString() : null) ??
          '',
      originUrl: json['origin_url']?.toString() ??
          (fileJson is Map ? fileJson['origin_url']?.toString() : null) ??
          '',
      variantStatus: _parseVariantStatus(
        json['variant_status'] ??
            (fileJson is Map ? fileJson['variant_status'] : null),
      ),
    );
  }

  String get url => file?.url ?? '';
  String get resolvedThumbUrl => thumbUrl.isNotEmpty ? thumbUrl : url;
  String get resolvedMediumUrl => mediumUrl.isNotEmpty ? mediumUrl : url;
  String get resolvedViewerUrl => viewerUrl.isNotEmpty ? viewerUrl : url;
  String get resolvedOriginUrl => originUrl.isNotEmpty ? originUrl : url;

  bool isVariantReady(String variant) {
    final status = variantStatus[variant];
    // 兼容旧接口：没有状态字段时沿用 URL 回退行为。
    return status == null || status == 'ready';
  }

  static Map<String, String> _parseVariantStatus(dynamic raw) {
    if (raw is! Map) return const {};
    final parsed = <String, String>{};
    raw.forEach((key, value) {
      if (key != null && value != null) {
        parsed[key.toString()] = value.toString();
      }
    });
    return parsed.isEmpty ? const {} : Map.unmodifiable(parsed);
  }
}

class FileItem {
  final int id;
  final String hash;
  final String path;
  final int size;
  final String mimeType;
  final int width;
  final int height;

  FileItem({
    required this.id,
    required this.hash,
    required this.path,
    required this.size,
    required this.mimeType,
    this.width = 0,
    this.height = 0,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      id: json['id'] ?? 0,
      hash: json['hash'] ?? '',
      path: json['path'] ?? '',
      size: json['size'] ?? 0,
      mimeType: json['mime_type'] ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );
  }

  String get url => path;
}
