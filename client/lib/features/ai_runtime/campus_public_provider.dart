import '../../models/ai_run_event.dart';
import '../../services/ai_assistant_service.dart';
import 'ai_model_provider.dart';

/// 将现有受认证保护的校园公益 AI 适配为阶段 1 的通用模型接口。
/// 它只转发用户手动输入的普通文本，不读取或附带本地校园数据。
class CampusPublicProvider implements AIModelProvider {
  CampusPublicProvider(this._service);

  final AiAssistantService _service;
  String? _conversationId;
  String? _activeRunId;
  bool _cancelRequested = false;

  @override
  AIModelProviderKind get kind => AIModelProviderKind.campusPublic;

  @override
  String get displayName => kind.displayName;

  @override
  Future<AIModelCapabilities> discoverCapabilities() async {
    final capabilities = await _service.getCapabilities();
    return AIModelCapabilities(
      chatAvailability: capabilities.isVisible && capabilities.chatEnabled
          ? AIModelChatAvailability.available
          : AIModelChatAvailability.unavailable,
      models: capabilities.isVisible ? const <String>['校园公益 AI'] : const [],
    );
  }

  @override
  Future<AIModelChatResponse> complete(
      List<AIModelChatMessage> messages) async {
    _cancelRequested = false;
    final input = messages.reversed
        .where((message) => message.role == AIModelMessageRole.user)
        .map((message) => message.content.trim())
        .firstWhere(
          (message) => message.isNotEmpty,
          orElse: () => '',
        );
    if (input.isEmpty) {
      throw const AIModelProviderException('请输入聊天内容');
    }

    final capabilities = await _service.getCapabilities();
    _throwIfCancellationRequested();
    if (!capabilities.isVisible || !capabilities.chatEnabled) {
      throw const AIModelProviderException('校园公益 AI 当前未开放普通聊天');
    }

    final conversationId =
        _conversationId ?? (await _service.createConversation()).id;
    _throwIfCancellationRequested();
    final creation = await _service.createRun(
      conversationId: conversationId,
      clientRequestId: _requestId(),
      message: input,
    );
    _conversationId = creation.run.conversationId;
    final runId = creation.run.id;
    _activeRunId = runId;

    try {
      if (_cancelRequested) {
        await _cancelRunBestEffort(runId);
        throw const AIModelProviderException('本次回答已取消');
      }

      var answer = '';
      await for (final event in _service.streamRunEvents(runId)) {
        switch (event.type) {
          case AiRunEventType.delta:
            answer += event.text;
            break;
          case AiRunEventType.checkpoint:
            if (event.text.isNotEmpty) answer = event.text;
            break;
          case AiRunEventType.completed:
            return _completedAnswer(
              answer,
              runId,
              confirmedCompleted: true,
            );
          case AiRunEventType.failed:
            throw AIModelProviderException(_errorFor(event.errorCode));
          case AiRunEventType.cancelled:
            throw const AIModelProviderException('本次回答已取消');
          case AiRunEventType.started:
          case AiRunEventType.status:
          case AiRunEventType.sources:
          case AiRunEventType.heartbeat:
          case AiRunEventType.toolRequested:
          case AiRunEventType.toolExecuting:
          case AiRunEventType.deviceWaiting:
          case AiRunEventType.deviceClaimed:
          case AiRunEventType.consentRequired:
          case AiRunEventType.eduFetching:
          case AiRunEventType.toolCompleted:
          case AiRunEventType.personalDataEvidence:
          case AiRunEventType.agentActivity:
          case AiRunEventType.unknown:
            break;
        }
      }
      return _completedAnswer(answer, runId);
    } finally {
      if (_activeRunId == runId) _activeRunId = null;
    }
  }

  @override
  Future<void> cancelActiveRequest() async {
    _cancelRequested = true;
    final runId = _activeRunId;
    if (runId == null) return;
    _activeRunId = null;
    await _cancelRunBestEffort(runId);
  }

  void _throwIfCancellationRequested() {
    if (_cancelRequested) {
      throw const AIModelProviderException('本次回答已取消');
    }
  }

  Future<void> _cancelRunBestEffort(String runId) async {
    try {
      await _service.cancelRun(runId).timeout(const Duration(seconds: 2));
    } catch (_) {
      // 本地上下文已关闭，远端取消失败不能阻止退出。
    }
  }

  Future<AIModelChatResponse> _completedAnswer(
    String streamedAnswer,
    String runId, {
    bool confirmedCompleted = false,
  }) async {
    if (confirmedCompleted && streamedAnswer.trim().isNotEmpty) {
      return AIModelChatResponse(content: streamedAnswer, model: displayName);
    }
    final run = await _service.getRun(runId);
    if (run.state == 'completed') {
      final answer = run.answerCheckpoint.trim().isNotEmpty
          ? run.answerCheckpoint
          : streamedAnswer;
      if (answer.trim().isEmpty) {
        throw const AIModelProviderException('校园公益 AI 没有返回文本内容');
      }
      return AIModelChatResponse(
        content: answer,
        model: displayName,
      );
    }
    if (run.state == 'cancelled') {
      throw const AIModelProviderException('本次回答已取消');
    }
    throw AIModelProviderException(_errorFor(run.errorCode));
  }

  String _errorFor(String code) => switch (code) {
        'rag_insufficient_sources' => '校园资料不足，暂时无法回答这个问题',
        'run_expired' => '本次回答已过期，请重新提问',
        _ => '校园公益 AI 暂时无法回答，请稍后重试',
      };
}

String _requestId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  return 'client-runtime-$now';
}
