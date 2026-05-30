import 'user.dart';

// 帖子图片模型
class PostImage {
  final int id;
  final int postId;
  final int fileId;
  final int sortOrder;
  final FileItem? file;

  PostImage({
    required this.id,
    required this.postId,
    required this.fileId,
    this.sortOrder = 0,
    this.file,
  });

  factory PostImage.fromJson(Map<String, dynamic> json) {
    return PostImage(
      id: json['id'] ?? 0,
      postId: json['post_id'] ?? 0,
      fileId: json['file_id'] ?? 0,
      sortOrder: json['sort_order'] ?? 0,
      file: json['file'] != null ? FileItem.fromJson(json['file']) : null,
    );
  }

  String get url => file?.url ?? '';
}

// 文件模型
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

// 帖子模型
class Post {
  final int id;
  final String title;
  final String content;
  final int boardId;
  final int authorId;
  final String postType;
  final double price;
  final String contact;
  final String status;
  final int viewCount;
  final int replyCount;
  final int likeCount;
  final bool isLiked;
  final List<PostImage> images;
  final User? author;
  final DateTime createdAt;

  Post({
    required this.id,
    this.title = '',
    required this.content,
    required this.boardId,
    required this.authorId,
    this.postType = '',
    this.price = 0,
    this.contact = '',
    this.status = 'normal',
    this.viewCount = 0,
    this.replyCount = 0,
    this.likeCount = 0,
    this.isLiked = false,
    this.images = const [],
    this.author,
    required this.createdAt,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      boardId: json['board_id'] ?? 1,
      authorId: json['author_id'] ?? 0,
      postType: json['post_type'] ?? '',
      price: (json['price'] ?? 0).toDouble(),
      contact: json['contact'] ?? '',
      status: json['status'] ?? 'normal',
      viewCount: json['view_count'] ?? 0,
      replyCount: json['reply_count'] ?? 0,
      likeCount: json['like_count'] ?? 0,
      isLiked: json['is_liked'] == true,
      images: (json['images'] as List<dynamic>?)
          ?.map((e) => PostImage.fromJson(e))
          .toList() ?? [],
      author: json['author'] != null ? User.fromJson(json['author']) : null,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  String get firstImageUrl => images.isNotEmpty ? images.first.url : '';

  Post copyWith({
    int? id,
    String? title,
    String? content,
    int? boardId,
    int? authorId,
    String? postType,
    double? price,
    String? contact,
    String? status,
    int? viewCount,
    int? replyCount,
    int? likeCount,
    bool? isLiked,
    List<PostImage>? images,
    User? author,
    DateTime? createdAt,
  }) {
    return Post(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      boardId: boardId ?? this.boardId,
      authorId: authorId ?? this.authorId,
      postType: postType ?? this.postType,
      price: price ?? this.price,
      contact: contact ?? this.contact,
      status: status ?? this.status,
      viewCount: viewCount ?? this.viewCount,
      replyCount: replyCount ?? this.replyCount,
      likeCount: likeCount ?? this.likeCount,
      isLiked: isLiked ?? this.isLiked,
      images: images ?? this.images,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}