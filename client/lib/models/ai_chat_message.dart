import 'ai_source.dart';

enum AiMessageRole { user, assistant }

enum AiMessageStatus { pending, streaming, completed, failed }

class AiChatMessage {
  final String id;
  final String requestId;
  final AiMessageRole role;
  final String content;
  final AiMessageStatus status;
  final List<AiSource> sources;
  final DateTime createdAt;

  const AiChatMessage({
    required this.id,
    required this.requestId,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.sources = const [],
  });
}
