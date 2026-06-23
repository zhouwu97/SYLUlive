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
      lastMessageAt:
          DateTime.tryParse(json['last_message_at'] ?? '') ??
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

// 私信消息模型
class Message {
  final int id;
  final int conversationId;
  final int senderId;
  final String content;
  final int? fileId;
  final DateTime createdAt;
  final DateTime? readAt;
  final User? sender;
  final FileItem? file;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    this.fileId,
    required this.createdAt,
    this.readAt,
    this.sender,
    this.file,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] ?? 0,
      conversationId: json['conversation_id'] ?? 0,
      senderId: json['sender_id'] ?? 0,
      content: json['content'] ?? '',
      fileId: json['file_id'],
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      readAt: json['read_at'] != null
          ? DateTime.tryParse(json['read_at'])
          : null,
      sender: json['sender'] != null ? User.fromJson(json['sender']) : null,
      file: json['file'] != null ? FileItem.fromJson(json['file']) : null,
    );
  }

  String get imageUrl => file?.url ?? '';
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
