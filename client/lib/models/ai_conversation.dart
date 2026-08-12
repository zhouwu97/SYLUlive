import 'ai_source.dart';
import 'ai_personal_data_evidence.dart';

class AiConversation {
  final String id;
  final String title;
  final String lastMessagePreview;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const AiConversation({
    required this.id,
    required this.title,
    this.lastMessagePreview = '',
    this.createdAt,
    this.updatedAt,
  });

  factory AiConversation.fromJson(Map<String, dynamic> json) {
    return AiConversation(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '新会话',
      lastMessagePreview: json['last_message_preview']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal(),
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

class AiConversationMessage {
  final String id;
  final String conversationId;
  final String? runId;
  final String role;
  final String content;
  final List<AiSource> sources;
  final List<AiPersonalDataEvidence> personalDataEvidence;
  final DateTime? createdAt;

  const AiConversationMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.runId,
    this.sources = const [],
    this.personalDataEvidence = const [],
    this.createdAt,
  });

  factory AiConversationMessage.fromJson(Map<String, dynamic> json) {
    return AiConversationMessage(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      runId: json['run_id']?.toString(),
      role: json['role']?.toString() ?? 'assistant',
      content: json['content']?.toString() ?? '',
      sources: _parseSources(json['sources']),
      personalDataEvidence: _parsePersonalDataEvidence(
        json['personal_data_evidence'],
      ),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

List<AiPersonalDataEvidence> _parsePersonalDataEvidence(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => AiPersonalDataEvidence.fromJson(
            Map<String, dynamic>.from(item),
          ))
      .toList(growable: false);
}

List<AiSource> _parseSources(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => AiSource.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

class AiConversationDetails {
  final AiConversation conversation;
  final List<AiConversationMessage> messages;

  const AiConversationDetails(
      {required this.conversation, required this.messages});

  factory AiConversationDetails.fromJson(Map<String, dynamic> json) {
    final conversationJson = json['conversation'];
    final messagesJson = json['messages'];
    return AiConversationDetails(
      conversation: AiConversation.fromJson(
        conversationJson is Map
            ? Map<String, dynamic>.from(conversationJson)
            : const {},
      ),
      messages: messagesJson is List
          ? messagesJson
              .whereType<Map>()
              .map((item) => AiConversationMessage.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : const [],
    );
  }
}
