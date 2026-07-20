import '../../campus_data/storage/personal_snapshot_models.dart';
import '../ai_model_provider.dart';
import '../skills/personal_skill.dart';

class LocalToolCall {
  LocalToolCall({
    required String id,
    required String tool,
    required Map<String, dynamic> arguments,
  })  : id = id.trim(),
        tool = tool.trim(),
        arguments = Map<String, dynamic>.unmodifiable(arguments);

  final String id;
  final String tool;
  final Map<String, dynamic> arguments;
}

class ToolDefinition {
  ToolDefinition({
    required this.id,
    required this.description,
    required Map<String, dynamic> parameters,
  }) : parameters = Map<String, dynamic>.unmodifiable(parameters);

  final String id;
  final String description;
  final Map<String, dynamic> parameters;
}

enum ToolMessageRole { system, user, assistant, tool }

class ToolConversationMessage {
  const ToolConversationMessage({
    required this.role,
    required this.content,
    this.toolCall,
    this.toolCallId,
  });

  final ToolMessageRole role;
  final String content;
  final LocalToolCall? toolCall;
  final String? toolCallId;
}

class ToolModelTurn {
  const ToolModelTurn.finalAnswer(this.text) : toolCall = null;
  const ToolModelTurn.call(this.toolCall) : text = '';

  final String text;
  final LocalToolCall? toolCall;

  bool get isFinal => toolCall == null;
}

abstract interface class ToolCallingModel {
  AIModelProviderKind get providerKind;

  String get destinationLabel;

  /// 绑定授权的 Provider 配置范围，不包含 API Key。
  String get authorizationScope;

  Future<ToolModelTurn> nextTurn({
    required List<ToolConversationMessage> messages,
    required List<ToolDefinition> tools,
  });

  Future<void> cancel();
}

enum ToolPermissionLifetime { once, session }

enum ToolPermissionDecision { allowOnce, allowSession, denied }

class ToolDataPreviewItem {
  const ToolDataPreviewItem({
    required this.dataType,
    required this.label,
    this.fetchedAt,
    this.isStale = false,
  });

  final PersonalDataType dataType;
  final String label;
  final DateTime? fetchedAt;
  final bool isStale;
}

class ToolPermissionPreview {
  ToolPermissionPreview({
    required this.toolId,
    required this.sensitivity,
    required this.destination,
    required List<ToolDataPreviewItem> dataItems,
    required List<String> excludedDataLabels,
    required List<String> outputFields,
    this.accountScope = '',
    this.providerScope = '',
    this.schemaVersion = 1,
    this.payloadHash = '',
    this.payloadSize = 0,
  })  : dataItems = List<ToolDataPreviewItem>.unmodifiable(dataItems),
        excludedDataLabels = List<String>.unmodifiable(excludedDataLabels),
        outputFields = List<String>.unmodifiable(outputFields);

  final String toolId;
  final SkillSensitivity sensitivity;
  final String destination;
  final List<ToolDataPreviewItem> dataItems;
  final List<String> excludedDataLabels;
  final List<String> outputFields;
  final String accountScope;
  final String providerScope;
  final int schemaVersion;
  final String payloadHash;
  final int payloadSize;

  bool get containsPersonalData => dataItems.isNotEmpty;

  /// 会话授权必须随账号、Provider、字段集合和 Schema 变化而失效。
  String get grantKey {
    final fields = <String>[...outputFields]..sort();
    final data = dataItems.map((item) => item.dataType.storageValue).toList()
      ..sort();
    return <String>[
      accountScope,
      providerScope,
      toolId,
      '$schemaVersion',
      ...data,
      ...fields,
    ].join('\u001f');
  }
}

enum ToolLoopStatus {
  completed,
  permissionDenied,
  cancelled,
  rejected,
  failed,
}

class ToolLoopOutcome {
  const ToolLoopOutcome({
    required this.status,
    this.answer = '',
    this.warnings = const <String>[],
    this.evidence = const <SkillEvidence>[],
  });

  final ToolLoopStatus status;
  final String answer;
  final List<String> warnings;
  final List<SkillEvidence> evidence;
}

class ToolLoopCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
