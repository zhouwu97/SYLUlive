import 'user.dart';

// 私信会话模型
class Conversation {
  final int id;
  final int user1Id;
  final int user2Id;
  final DateTime lastMessageAt;
  final User? user1;
  final User? user2;
  final int unreadCount;
  final Message? lastMessage;

  Conversation({
    required this.id,
    required this.user1Id,
    required this.user2Id,
    required this.lastMessageAt,
    this.user1,
    this.user2,
    this.unreadCount = 0,
    this.lastMessage,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] ?? 0,
      user1Id: json['user1_id'] ?? 0,
      user2Id: json['user2_id'] ?? 0,
      lastMessageAt: DateTime.tryParse(json['last_message_at'] ?? '') ??
          DateTime.tryParse(json['created_at'] ?? '') ??
          DateTime.now(),
      user1: json['user1'] != null ? User.fromJson(json['user1']) : null,
      user2: json['user2'] != null ? User.fromJson(json['user2']) : null,
      unreadCount: json['unread_count'] ?? 0,
      lastMessage: json['last_message'] != null
          ? Message.fromJson(json['last_message'])
          : null,
    );
  }

  User? getOtherUser(int currentUserId) {
    return user1Id == currentUserId ? user2 : user1;
  }

  Conversation copyWith({
    int? unreadCount,
    Message? lastMessage,
    DateTime? lastMessageAt,
  }) {
    return Conversation(
      id: id,
      user1Id: user1Id,
      user2Id: user2Id,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      user1: user1,
      user2: user2,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessage: lastMessage ?? this.lastMessage,
    );
  }
}

enum MessageLocalStatus { pending, sent, failed }

// 私信消息模型
class Message {
  final int id;
  final int conversationId;
  final int senderId;
  final String? clientMessageId;
  final String content;
  final int? fileId;
  final String? stickerId;
  final DateTime createdAt;
  final DateTime? readAt;
  final User? sender;
  final FileItem? file;
  final MessageLocalStatus localStatus;
  final String? localImagePath;
  final String? localError;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.clientMessageId,
    required this.content,
    this.fileId,
    this.stickerId,
    required this.createdAt,
    this.readAt,
    this.sender,
    this.file,
    this.localStatus = MessageLocalStatus.sent,
    this.localImagePath,
    this.localError,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] ?? 0,
      conversationId: json['conversation_id'] ?? 0,
      senderId: json['sender_id'] ?? 0,
      clientMessageId: json['client_message_id'] as String?,
      content: json['content'] ?? '',
      fileId: json['file_id'],
      stickerId: json['sticker_id']?.toString(),
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      readAt:
          json['read_at'] != null ? DateTime.tryParse(json['read_at']) : null,
      sender: json['sender'] != null ? User.fromJson(json['sender']) : null,
      file: json['file'] != null ? FileItem.fromJson(json['file']) : null,
    );
  }

  String get imageUrl => file?.url ?? '';

  bool get hasSticker => stickerId?.trim().isNotEmpty == true;

  bool get hasTextContent {
    final text = content.trim();
    return text.isNotEmpty && !(hasSticker && text == '[表情]');
  }

  bool get isStickerOnly => hasSticker && !hasTextContent;

  bool get isMixedTextSticker => hasSticker && hasTextContent;

  // 兼容现有调用方；新渲染逻辑应根据纯表情或混合消息选择布局。
  bool get isSticker => hasSticker;

  String get stickerUrl => hasSticker ? '/stickers/$stickerId' : '';

  bool get isPending => localStatus == MessageLocalStatus.pending;

  bool get isFailed => localStatus == MessageLocalStatus.failed;

  String get stableKey => id > 0
      ? 'server-$id'
      : 'local-${clientMessageId ?? createdAt.microsecondsSinceEpoch}';

  Message copyWith({
    int? id,
    int? conversationId,
    int? senderId,
    String? clientMessageId,
    String? content,
    int? fileId,
    String? stickerId,
    DateTime? createdAt,
    DateTime? readAt,
    User? sender,
    FileItem? file,
    MessageLocalStatus? localStatus,
    String? localImagePath,
    String? localError,
    bool clearLocalError = false,
  }) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      clientMessageId: clientMessageId ?? this.clientMessageId,
      content: content ?? this.content,
      fileId: fileId ?? this.fileId,
      stickerId: stickerId ?? this.stickerId,
      createdAt: createdAt ?? this.createdAt,
      readAt: readAt ?? this.readAt,
      sender: sender ?? this.sender,
      file: file ?? this.file,
      localStatus: localStatus ?? this.localStatus,
      localImagePath: localImagePath ?? this.localImagePath,
      localError: clearLocalError ? null : (localError ?? this.localError),
    );
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
      path: (json['download_url'] ?? json['path'] ?? '').toString(),
      size: json['size'] ?? 0,
      mimeType: json['mime_type'] ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );
  }

  String get url => path;
}
