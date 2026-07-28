import '../../campus_data/storage/personal_snapshot_models.dart';
import '../ai_model_provider.dart';
import '../skills/personal_skill.dart';

class LocalToolCall {
  LocalToolCall({
    required String id,
    required String tool,
    required Map<String, dynamic> arguments,
    this.legacyFunctionCall = false,
  })  : id = id.trim(),
        tool = tool.trim(),
        arguments = Map<String, dynamic>.unmodifiable(arguments);

  final String id;
  final String tool;
  final Map<String, dynamic> arguments;
  final bool legacyFunctionCall;
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
    this.reasoningContent,
  });

  final ToolMessageRole role;
  final String content;
  final LocalToolCall? toolCall;
  final String? toolCallId;

  /// 服务商要求在工具后续轮次原样回传的推理上下文，不用于界面展示或审计。
  final String? reasoningContent;
}

class ToolModelTurn {
  const ToolModelTurn.finalAnswer(this.text)
      : toolCall = null,
        assistantContent = '',
        reasoningContent = null;
  const ToolModelTurn.call(
    this.toolCall, {
    this.assistantContent = '',
    this.reasoningContent,
  }) : text = '';

  final String text;
  final LocalToolCall? toolCall;

  /// 工具调用所在的原始助手消息字段，仅用于构造下一轮模型请求。
  final String assistantContent;
  final String? reasoningContent;

  bool get isFinal => toolCall == null;
}

abstract interface class ToolCallingModel {
  AIModelProviderKind get providerKind;

  String get destinationLabel;

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
    this.dataType,
    required this.label,
    this.fetchedAt,
    this.isStale = false,
  });

  final PersonalDataType? dataType;
  final String label;
  final DateTime? fetchedAt;
  final bool isStale;
}

class ToolPermissionPreview {
  ToolPermissionPreview({
    required this.toolId,
    required this.sensitivity,
    required this.providerKind,
    required this.destination,
    required List<ToolDataPreviewItem> dataItems,
    required List<String> excludedDataLabels,
    required List<String> outputFields,
  })  : dataItems = List<ToolDataPreviewItem>.unmodifiable(dataItems),
        excludedDataLabels = List<String>.unmodifiable(excludedDataLabels),
        outputFields = List<String>.unmodifiable(outputFields);

  final String toolId;
  final SkillSensitivity sensitivity;
  final AIModelProviderKind providerKind;
  final String destination;
  final List<ToolDataPreviewItem> dataItems;
  final List<String> excludedDataLabels;
  final List<String> outputFields;

  bool get containsPersonalData => dataItems.isNotEmpty;
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
    this.actionArtifacts = const <SkillActionArtifact>[],
  });

  final ToolLoopStatus status;
  final String answer;
  final List<String> warnings;
  final List<SkillEvidence> evidence;
  final List<SkillActionArtifact> actionArtifacts;
}

class ToolLoopCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
