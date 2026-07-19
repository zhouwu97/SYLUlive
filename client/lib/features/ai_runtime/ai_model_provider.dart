/// 阶段 1 的模型运行时只支持普通文本聊天，不定义工具、文件或校园数据能力。
enum AIModelProviderKind {
  campusPublic,
  openAICompatible,
}

extension AIModelProviderKindLabel on AIModelProviderKind {
  String get storageValue => switch (this) {
        AIModelProviderKind.campusPublic => 'campus_public',
        AIModelProviderKind.openAICompatible => 'openai_compatible',
      };

  String get displayName => switch (this) {
        AIModelProviderKind.campusPublic => '校园公益 AI',
        AIModelProviderKind.openAICompatible => 'OpenAI 兼容服务',
      };

  static AIModelProviderKind fromStorage(String? value) => switch (value) {
        'openai_compatible' => AIModelProviderKind.openAICompatible,
        _ => AIModelProviderKind.campusPublic,
      };
}

/// 仅保存可公开的连接配置；API Key 绝不能进入这个对象或其序列化结果。
class AIModelProviderConfig {
  final String id;
  final AIModelProviderKind kind;
  final String endpoint;
  final String model;

  const AIModelProviderConfig({
    this.id = 'default',
    required this.kind,
    this.endpoint = '',
    this.model = '',
  });

  factory AIModelProviderConfig.fromJson(Map<String, dynamic> json) {
    return AIModelProviderConfig(
      id: json['provider_config_id']?.toString().trim() ?? 'default',
      kind: AIModelProviderKindLabel.fromStorage(json['kind']?.toString()),
      endpoint: json['endpoint']?.toString().trim() ?? '',
      model: json['model']?.toString().trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'provider_config_id': id,
        'kind': kind.storageValue,
        'endpoint': endpoint.trim(),
        'model': model.trim(),
      };

  AIModelProviderConfig copyWith({
    String? id,
    AIModelProviderKind? kind,
    String? endpoint,
    String? model,
  }) {
    return AIModelProviderConfig(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      endpoint: endpoint ?? this.endpoint,
      model: model ?? this.model,
    );
  }
}

enum AIModelMessageRole { user, assistant }

class AIModelChatMessage {
  final AIModelMessageRole role;
  final String content;

  const AIModelChatMessage({required this.role, required this.content});

  Map<String, String> toOpenAIJson() => <String, String>{
        'role': role == AIModelMessageRole.user ? 'user' : 'assistant',
        'content': content,
      };
}

enum AIModelChatAvailability { unknown, available, unavailable }

/// 只报告已实际验证的能力，未知不等同于可用。
class AIModelCapabilities {
  final AIModelChatAvailability chatAvailability;
  final bool supportsStreaming;
  final bool supportsToolCalling;
  final bool supportsStreamingToolCalling;
  final List<String> models;

  const AIModelCapabilities({
    required this.chatAvailability,
    this.supportsStreaming = false,
    this.supportsToolCalling = false,
    this.supportsStreamingToolCalling = false,
    this.models = const <String>[],
  });

  bool get chatAvailable =>
      chatAvailability == AIModelChatAvailability.available;
}

class AIModelChatResponse {
  final String content;
  final String? model;

  const AIModelChatResponse({required this.content, this.model});
}

class AIModelProviderException implements Exception {
  final String message;

  const AIModelProviderException(this.message);

  @override
  String toString() => message;
}

abstract interface class AIModelProvider {
  AIModelProviderKind get kind;
  String get displayName;

  Future<AIModelCapabilities> discoverCapabilities();

  /// 只提交普通聊天消息；接口层不接受 Tool Calling 或用户私有数据。
  Future<AIModelChatResponse> complete(List<AIModelChatMessage> messages);
}
