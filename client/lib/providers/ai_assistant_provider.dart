import 'dart:async';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../models/ai_capabilities.dart';
import '../models/ai_chat_message.dart';
import '../models/ai_conversation.dart';
import '../models/ai_personal_data_evidence.dart';
import '../models/ai_quick_prompt.dart';
import '../models/ai_quota.dart';
import '../models/ai_run.dart';
import '../models/ai_run_event.dart';
import '../models/ai_source.dart';
import '../services/ai_assistant_service.dart';

enum AiConnectionState {
  idle,
  connecting,
  streaming,
  completed,
  failed,
  cancelled
}

enum AiSubmitResult {
  accepted,
  blank,
  tooLong,
  unavailable,
  quotaExceeded,
  busy,
  failed
}

/// 一次提交的完整身份。手动或自动重试都必须沿用同一个 [requestId]，
/// 否则在“服务器已经创建 Run、响应丢失”的情况下会创建出第二个 Run。
class AiPendingSubmission {
  final String requestId;
  final String conversationId;
  final String message;

  const AiPendingSubmission({
    required this.requestId,
    required this.conversationId,
    required this.message,
  });
}

String normalizeAiMessage(String value) {
  return value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
}

int aiVisibleCharacterCount(String value) =>
    normalizeAiMessage(value).characters.length;

class AiAssistantProvider extends ChangeNotifier {
  final AiAssistantService _service;
  final Future<void> Function()? _deviceToolSync;
  final Random _random;

  AiAssistantProvider(
    this._service, {
    AiCapabilities? initialCapabilities,
    Future<void> Function()? deviceToolSync,
    Random? random,
  })  : _capabilities = initialCapabilities,
        _quota = initialCapabilities?.quota,
        _deviceToolSync = deviceToolSync,
        _random = random ?? Random() {
    _syncQuickPrompts();
  }

  AiCapabilities? _capabilities;
  AiQuota? _quota;
  final List<AiChatMessage> _messages = [];
  final List<AiConversation> _conversations = [];
  AiRunEvent? _currentRun;
  AiRun? _run;
  AiRunEvent? _pendingConsent;
  bool _submittingConsent = false;
  AiConnectionState _connectionState = AiConnectionState.idle;
  String _streamedText = '';
  List<AiSource> _sources = [];
  final Map<String, List<AiPersonalDataEvidence>> _personalDataEvidence = {};
  String? _error;
  String? _conversationId;
  AiPendingSubmission? _lastFailedSubmission;
  int _lastEventSeq = 0;
  bool _loading = false;
  bool _loadingConversations = false;
  bool _disposed = false;
  int _streamGeneration = 0;
  List<AiQuickPrompt> _quickPrompts = const [];
  String _quickPromptPoolKey = '';

  AiCapabilities? get capabilities => _capabilities;
  AiQuota? get quota => _quota;
  List<AiChatMessage> get messages => List.unmodifiable(_messages);
  List<AiConversation> get conversations => List.unmodifiable(_conversations);
  AiRunEvent? get currentRun => _currentRun;
  AiRunEvent? get pendingConsent => _pendingConsent;
  bool get submittingConsent => _submittingConsent;
  AiConnectionState get connectionState => _connectionState;
  String get streamedText => _streamedText;
  List<AiSource> get sources => List.unmodifiable(_sources);
  String? get error => _error;
  String? get conversationId => _conversationId;
  bool get loading => _loading;
  bool get loadingConversations => _loadingConversations;
  bool get canRetry => _lastFailedSubmission != null && !isRunning;
  bool get canReconnectRun => _run != null && !isRunning;
  bool get isRunning =>
      _connectionState == AiConnectionState.connecting ||
      _connectionState == AiConnectionState.streaming;

  String get friendlyRunStatus {
    final event = _currentRun;
    switch (event?.type) {
      case AiRunEventType.deviceWaiting:
        return _deviceWaitingStatus(event!.datasets);
      case AiRunEventType.consentRequired:
        return '需要你的许可才能刷新最新成绩';
      case AiRunEventType.eduFetching:
        return '正在通过教务服务更新个人数据';
      case AiRunEventType.toolRequested:
      case AiRunEventType.toolExecuting:
        return '正在读取已授权的校园数据';
      case AiRunEventType.deviceClaimed:
        return '你的手机正在读取本地缓存';
      case AiRunEventType.toolCompleted:
        return '正在整理已授权数据';
      case AiRunEventType.personalDataEvidence:
        return '正在核对个人数据来源';
      case null:
      case AiRunEventType.started:
      case AiRunEventType.status:
      case AiRunEventType.delta:
      case AiRunEventType.checkpoint:
      case AiRunEventType.sources:
      case AiRunEventType.completed:
      case AiRunEventType.failed:
      case AiRunEventType.cancelled:
      case AiRunEventType.heartbeat:
      case AiRunEventType.unknown:
        break;
    }
    final raw = (_currentRun?.status ?? _run?.state ?? '').toLowerCase();
    if (raw.contains('waiting_device')) return '正在请求你的手机读取本地缓存';
    if (raw.contains('waiting_user_consent')) return '需要你的许可才能刷新最新成绩';
    if (raw.contains('waiting_edu')) return '正在通过教务服务更新个人数据';
    if (raw.contains('schedule') || raw.contains('course')) {
      return '正在查看已保存的课表…';
    }
    if (raw.contains('retriev') ||
        raw.contains('rag') ||
        raw.contains('policy')) {
      return '正在查找学校资料…';
    }
    if (_connectionState == AiConnectionState.connecting) return '正在连接沈理 AI…';
    return '正在整理回答…';
  }

  String _deviceWaitingStatus(List<String> datasets) {
    if (datasets.contains('schedule')) return '正在请求你的手机读取本地课表';
    if (datasets.contains('erke')) return '正在请求你的手机读取本地二课缓存';
    if (datasets.contains('grades')) return '正在请求你的手机读取本地成绩缓存';
    return '正在请求你的手机读取本地缓存';
  }

  List<AiQuickPrompt> get quickPrompts => List.unmodifiable(_quickPrompts);

  void refreshQuickPrompts() {
    _selectQuickPrompts(avoidCurrent: true);
    _notify();
  }

  Future<void>? _bootstrapFuture;

  Future<void> retryBootstrap() {
    return _bootstrapFuture ??= _retryBootstrapInternal().whenComplete(() {
      _bootstrapFuture = null;
    });
  }

  Future<void> _retryBootstrapInternal() async {
    _error = null;
    _loading = true;
    _notify();

    try {
      await refreshCapabilities(silent: true);
      await loadConversations();
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> initialize() async {
    await retryBootstrap();
  }

  Future<void> refreshCapabilities({bool silent = false}) async {
    if (!silent) {
      _loading = true;
      _error = null;
      _notify();
    }
    try {
      final result = await _service.getCapabilities();
      _capabilities = result;
      _quota = result.quota;
      _syncQuickPrompts();
    } catch (_) {
      if (!silent) _error = '暂时无法读取 AI 服务状态';
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> loadConversations() async {
    if (_capabilities?.chatEnabled != true) {
      _conversations.clear();
      _loadingConversations = false;
      _notify();
      return;
    }
    _loadingConversations = true;
    _notify();
    try {
      final result = await _service.listConversations();
      _conversations
        ..clear()
        ..addAll(result);
    } on AiAssistantServiceException catch (error) {
      _error = error.message;
    } catch (_) {
      _error = '读取历史会话失败，请稍后重试';
    } finally {
      _loadingConversations = false;
      _notify();
    }
  }

  Future<void> startNewConversation() async {
    if (isRunning) return;
    _streamGeneration++;
    _conversationId = null;
    _messages.clear();
    _resetRunState();
    _selectQuickPrompts(avoidCurrent: true);
    _notify();
  }

  Future<void> openConversation(String id) async {
    if (isRunning || id == _conversationId) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final details = await _service.getConversation(id);
      _streamGeneration++;
      _conversationId = id;
      _messages
        ..clear()
        ..addAll(details.messages.map(_fromHistory));
      _resetRunState();
      _moveConversationToFront(details.conversation);
      await _restoreSources(details.messages);
    } on AiAssistantServiceException catch (error) {
      _error = error.message;
    } catch (_) {
      _error = '会话加载失败，请稍后重试';
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> deleteConversation(String id) async {
    try {
      await _service.deleteConversation(id);
      _conversations.removeWhere((item) => item.id == id);
      if (_conversationId == id) await startNewConversation();
      _notify();
    } on AiAssistantServiceException catch (error) {
      _error = error.message;
      _notify();
      rethrow;
    } catch (_) {
      _error = '删除会话失败，请稍后重试';
      _notify();
      rethrow;
    }
  }

  AiSubmitResult submit(String rawMessage) {
    final message = normalizeAiMessage(rawMessage);
    if (message.isEmpty) return AiSubmitResult.blank;
    final maxChars =
        _capabilities?.maxMessageChars ?? AiCapabilities.defaultMessageChars;
    if (message.characters.length > maxChars) return AiSubmitResult.tooLong;
    final blocked = _submissionBlocker();
    if (blocked != null) return blocked;

    return _startSubmission(AiPendingSubmission(
      requestId: _uuidV4(),
      conversationId: _conversationId ?? '',
      message: message,
    ));
  }

  /// 返回阻止本次提交的原因，没有阻塞时返回 null。
  AiSubmitResult? _submissionBlocker() {
    if (isRunning) return AiSubmitResult.busy;
    if (_quota?.unlimited != true && (_quota?.remaining ?? 0) <= 0) {
      return AiSubmitResult.quotaExceeded;
    }
    if (_capabilities?.chatEnabled != true) {
      _error = '基础设施测试中，暂未开放真实问答';
      _notify();
      return AiSubmitResult.unavailable;
    }
    return null;
  }

  AiSubmitResult _startSubmission(AiPendingSubmission submission) {
    _error = null;
    _lastFailedSubmission = null;
    _streamedText = '';
    _sources = [];
    _personalDataEvidence.clear();
    _lastEventSeq = 0;
    _connectionState = AiConnectionState.connecting;
    _messages.add(AiChatMessage(
      id: submission.requestId,
      requestId: submission.requestId,
      role: AiMessageRole.user,
      content: submission.message,
      status: AiMessageStatus.pending,
      createdAt: DateTime.now(),
    ));
    _notify();

    unawaited(_submitAsync(submission));
    return AiSubmitResult.accepted;
  }

  Future<void> _submitAsync(AiPendingSubmission submission) async {
    try {
      final creation = await _service.createRun(
        conversationId: submission.conversationId,
        clientRequestId: submission.requestId,
        message: submission.message,
      );
      _run = creation.run;
      _conversationId = creation.run.conversationId;
      _replaceUserStatus(submission.requestId, AiMessageStatus.completed);
      unawaited(
          _consumeEvents(creation.run.id, generation: ++_streamGeneration));
    } on AiAssistantServiceException catch (exception) {
      _handleSubmitFailure(submission, exception);
    } catch (_) {
      _handleSubmitFailure(
        submission,
        const AiAssistantServiceException('请求发送失败，请检查网络后重试', retryable: true),
      );
    }
  }

  /// 手动“重新发送”复用原来的 client_request_id。
  /// 服务端已经按 user_id + client_request_id 幂等：若上一次其实已经建好 Run，
  /// 重试会命中 duplicate 并接回同一个 Run，而不会产生第二次计费。
  AiSubmitResult retryLast() {
    final submission = _lastFailedSubmission;
    if (submission == null) return AiSubmitResult.blank;
    final blocked = _submissionBlocker();
    if (blocked != null) return blocked;
    _messages.removeWhere(
      (item) =>
          item.role == AiMessageRole.user &&
          item.status == AiMessageStatus.failed,
    );
    return _startSubmission(submission);
  }

  Future<void> cancel() async {
    final runId = _run?.id;
    if (runId == null || !isRunning) return;
    try {
      await _service.cancelRun(runId);
      _connectionState = AiConnectionState.cancelled;
      _error = '已取消本次回答';
      _streamGeneration++;
      _notify();
      unawaited(refreshCapabilities(silent: true));
    } on AiAssistantServiceException catch (exception) {
      _error = exception.message;
      _notify();
    } catch (_) {
      _error = '取消回答失败，请稍后重试';
      _notify();
    }
  }

  Future<bool> submitConsent(bool granted) async {
    final consent = _pendingConsent;
    final runId = consent?.runId.isNotEmpty == true ? consent!.runId : _run?.id;
    if (consent == null ||
        runId == null ||
        consent.consentScope.isEmpty ||
        _submittingConsent) {
      return false;
    }
    _submittingConsent = true;
    _notify();
    try {
      await _service.submitRunConsent(
        runId: runId,
        scope: consent.consentScope,
        granted: granted,
      );
      if (identical(_pendingConsent, consent)) _pendingConsent = null;
      return true;
    } on AiAssistantServiceException catch (exception) {
      _error = exception.message;
      return false;
    } catch (_) {
      _error = '提交本次授权失败，请稍后重试';
      return false;
    } finally {
      _submittingConsent = false;
      _notify();
    }
  }

  Future<void> reconnect() async {
    final runId = _run?.id;
    if (runId == null || isRunning) return;
    _error = null;
    _connectionState = AiConnectionState.connecting;
    _notify();
    await _consumeEvents(runId,
        generation: ++_streamGeneration, allowReconnect: false);
  }

  Future<void> _consumeEvents(
    String runId, {
    required int generation,
    bool allowReconnect = true,
  }) async {
    try {
      await for (final event
          in _service.streamRunEvents(runId, lastEventId: _lastEventSeq)) {
        if (_disposed || generation != _streamGeneration) return;
        applyRunEvent(event);
        if (_isTerminal(event.type)) break;
      }
      if (!_disposed && generation == _streamGeneration && isRunning) {
        await _recoverRun(runId, generation, allowReconnect: allowReconnect);
      }
    } catch (_) {
      if (!_disposed && generation == _streamGeneration) {
        await _recoverRun(runId, generation, allowReconnect: allowReconnect);
      }
    }
  }

  Future<void> _recoverRun(String runId, int generation,
      {required bool allowReconnect}) async {
    try {
      final run = await _service.getRun(runId);
      if (_disposed || generation != _streamGeneration) return;
      _run = run;
      if (run.answerCheckpoint.isNotEmpty &&
          run.answerCheckpoint != _streamedText) {
        _streamedText = run.answerCheckpoint;
        _upsertAssistant(run.answerCheckpoint, AiMessageStatus.streaming);
      }
      if (run.state == 'completed') {
        _connectionState = AiConnectionState.completed;
        _upsertAssistant(_streamedText, AiMessageStatus.completed);
        await _finishRun();
      } else if (run.state == 'failed' || run.state == 'expired') {
        _connectionState = AiConnectionState.failed;
        _error = _friendlyError(run.errorCode);
        _notify();
      } else if (run.state == 'cancelled') {
        _connectionState = AiConnectionState.cancelled;
        _error = '已取消本次回答';
        _notify();
      } else if (_isWaitingState(run.state)) {
        _connectionState = AiConnectionState.streaming;
        _currentRun = AiRunEvent(
          runId: run.id,
          type: AiRunEventType.status,
          status: run.state,
        );
        if (run.state == 'waiting_device') _syncDeviceTools();
        _notify();
      } else if (allowReconnect) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!_disposed && generation == _streamGeneration) {
          await _consumeEvents(runId,
              generation: generation, allowReconnect: false);
        }
      } else {
        _connectionState = AiConnectionState.failed;
        _error = '连接已中断，可点击重新连接继续回放';
        _notify();
      }
    } catch (_) {
      _connectionState = AiConnectionState.failed;
      _error = '连接已中断，可点击重新连接继续回放';
      _notify();
    }
  }

  /// SSE 回放可能重复到达，统一按 seq 去重，并用 checkpoint 覆盖增量文本。
  void applyRunEvent(AiRunEvent event) {
    if (event.type != AiRunEventType.heartbeat && event.seq > 0) {
      if (event.seq <= _lastEventSeq) return;
      _lastEventSeq = event.seq;
    }
    _currentRun = event;
    switch (event.type) {
      case AiRunEventType.started:
        _connectionState = AiConnectionState.connecting;
        break;
      case AiRunEventType.status:
        _connectionState = AiConnectionState.streaming;
        break;
      case AiRunEventType.delta:
        _connectionState = AiConnectionState.streaming;
        _streamedText += event.text;
        _upsertAssistant(
          _streamedText,
          AiMessageStatus.streaming,
          personalDataEvidence: _evidenceForRun(event.runId),
        );
        break;
      case AiRunEventType.checkpoint:
        _connectionState = AiConnectionState.streaming;
        if (event.text.isNotEmpty) {
          _streamedText = event.text;
          _upsertAssistant(
            _streamedText,
            AiMessageStatus.streaming,
            personalDataEvidence: _evidenceForRun(event.runId),
          );
        }
        break;
      case AiRunEventType.sources:
        _sources = List<AiSource>.unmodifiable(event.sources);
        _upsertAssistant(_streamedText, AiMessageStatus.streaming,
            sources: _sources,
            personalDataEvidence: _evidenceForRun(event.runId));
        break;
      case AiRunEventType.personalDataEvidence:
        _mergePersonalDataEvidence(event.runId, event.personalDataEvidence);
        _upsertAssistant(
          _streamedText,
          AiMessageStatus.streaming,
          personalDataEvidence: _evidenceForRun(event.runId),
        );
        break;
      case AiRunEventType.toolRequested:
      case AiRunEventType.toolExecuting:
      case AiRunEventType.deviceClaimed:
      case AiRunEventType.consentRequired:
        _pendingConsent = event;
        _connectionState = AiConnectionState.streaming;
        break;
      case AiRunEventType.deviceWaiting:
        _pendingConsent = event;
        _connectionState = AiConnectionState.streaming;
        _syncDeviceTools();
        break;
      case AiRunEventType.eduFetching:
      case AiRunEventType.toolCompleted:
        _connectionState = AiConnectionState.streaming;
        break;
      case AiRunEventType.completed:
        _connectionState = AiConnectionState.completed;
        if (event.quota != null) _quota = event.quota;
        _upsertAssistant(_streamedText, AiMessageStatus.completed,
            sources: _sources,
            personalDataEvidence: _evidenceForRun(event.runId));
        unawaited(_finishRun());
        break;
      case AiRunEventType.failed:
        _connectionState = AiConnectionState.failed;
        _error = _friendlyError(event.errorCode);
        if (_streamedText.isNotEmpty) {
          _upsertAssistant(_streamedText, AiMessageStatus.failed,
              sources: _sources,
              personalDataEvidence: _evidenceForRun(event.runId));
        }
        break;
      case AiRunEventType.cancelled:
        _connectionState = AiConnectionState.cancelled;
        _error = '已取消本次回答';
        break;
      case AiRunEventType.heartbeat:
      case AiRunEventType.unknown:
        break;
    }
    _notify();
  }

  Future<void> _finishRun() async {
    await refreshCapabilities(silent: true);
    await loadConversations();
  }

  Future<void> _restoreSources(List<AiConversationMessage> history) async {
    for (final message in history
        .where((item) => item.role == 'assistant' && item.runId != null)) {
      try {
        List<AiSource> restored = const [];
        final evidence = <AiPersonalDataEvidence>[];
        await for (final event in _service.streamRunEvents(message.runId!)) {
          if (event.type == AiRunEventType.sources) restored = event.sources;
          if (event.type == AiRunEventType.personalDataEvidence) {
            _mergeEvidenceList(evidence, event.personalDataEvidence);
          }
          if (_isTerminal(event.type)) break;
        }
        if (restored.isNotEmpty || evidence.isNotEmpty) {
          final index = _messages.indexWhere((item) => item.id == message.id);
          if (index >= 0) {
            _messages[index] = _messages[index].copyWith(
              sources: restored,
              personalDataEvidence: evidence,
            );
          }
        }
      } catch (_) {
        // 历史来源恢复失败不阻断正文展示。
      }
    }
  }

  AiChatMessage _fromHistory(AiConversationMessage message) {
    return AiChatMessage(
      id: message.id,
      requestId: message.runId ?? message.id,
      role:
          message.role == 'user' ? AiMessageRole.user : AiMessageRole.assistant,
      content: message.content,
      status: AiMessageStatus.completed,
      createdAt: message.createdAt ?? DateTime.now(),
    );
  }

  void _upsertAssistant(
    String text,
    AiMessageStatus status, {
    List<AiSource>? sources,
    List<AiPersonalDataEvidence>? personalDataEvidence,
  }) {
    if (text.isEmpty &&
        (sources == null || sources.isEmpty) &&
        (personalDataEvidence == null || personalDataEvidence.isEmpty)) {
      return;
    }
    final runId = _run?.id ?? _currentRun?.runId ?? '';
    final index = _messages.lastIndexWhere(
      (item) => item.role == AiMessageRole.assistant && item.requestId == runId,
    );
    if (index >= 0) {
      _messages[index] = _messages[index].copyWith(
        content: text.isEmpty ? _messages[index].content : text,
        status: status,
        sources: sources,
        personalDataEvidence: personalDataEvidence,
      );
      return;
    }
    _messages.add(AiChatMessage(
      id: 'assistant-$runId',
      requestId: runId,
      role: AiMessageRole.assistant,
      content: text,
      status: status,
      createdAt: DateTime.now(),
      sources: sources ?? const [],
      personalDataEvidence: personalDataEvidence ?? const [],
    ));
  }

  void _replaceUserStatus(String requestId, AiMessageStatus status) {
    final index = _messages.indexWhere((item) => item.requestId == requestId);
    if (index >= 0) {
      _messages[index] = _messages[index].copyWith(status: status);
    }
    _notify();
  }

  void _handleSubmitFailure(
    AiPendingSubmission submission,
    AiAssistantServiceException exception,
  ) {
    _connectionState = AiConnectionState.failed;
    _error = exception.message;
    _lastFailedSubmission = exception.retryable ? submission : null;
    _replaceUserStatus(submission.requestId, AiMessageStatus.failed);
    unawaited(refreshCapabilities(silent: true));
  }

  void _moveConversationToFront(AiConversation conversation) {
    _conversations.removeWhere((item) => item.id == conversation.id);
    _conversations.insert(0, conversation);
  }

  void _resetRunState() {
    _run = null;
    _currentRun = null;
    _pendingConsent = null;
    _submittingConsent = false;
    _connectionState = AiConnectionState.idle;
    _streamedText = '';
    _sources = [];
    _personalDataEvidence.clear();
    _lastEventSeq = 0;
    _lastFailedSubmission = null;
    _error = null;
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void _syncQuickPrompts() {
    final features = _capabilities?.features;
    final poolKey = [
      features?.policyRag == true,
      features?.scheduleWindows == true,
      features?.hy3CompetitionCompare == true,
      features?.hy3AcademicAnalysis == true,
      features?.hy3WeekPlan == true,
    ].join(':');
    if (_quickPromptPoolKey == poolKey && _quickPrompts.isNotEmpty) return;
    _quickPromptPoolKey = poolKey;
    _selectQuickPrompts();
  }

  void _selectQuickPrompts({bool avoidCurrent = false}) {
    final features = _capabilities?.features;
    final pool = aiCommonQuestionBank.where((item) {
      switch (item.feature) {
        case AiQuickPromptFeature.policy:
          return features?.policyRag == true;
        case AiQuickPromptFeature.schedule:
          return features?.scheduleWindows == true;
        case AiQuickPromptFeature.competitionCompare:
          return features?.hy3CompetitionCompare == true;
        case AiQuickPromptFeature.academicAnalysis:
          return features?.hy3AcademicAnalysis == true;
        case AiQuickPromptFeature.weekPlan:
          return features?.hy3WeekPlan == true;
      }
    }).toList();
    if (pool.isEmpty) {
      _quickPrompts = const [];
      return;
    }

    if (avoidCurrent && pool.length > _quickPromptDisplayCount) {
      final currentQuestions =
          _quickPrompts.map((item) => item.question).toSet();
      pool.removeWhere((item) => currentQuestions.contains(item.question));
    }
    pool.shuffle(_random);
    _quickPrompts = List.unmodifiable(
      pool.take(_quickPromptDisplayCount),
    );
  }

  bool _isTerminal(AiRunEventType type) =>
      type == AiRunEventType.completed ||
      type == AiRunEventType.failed ||
      type == AiRunEventType.cancelled;

  bool _isWaitingState(String state) =>
      state == 'waiting_device' ||
      state == 'waiting_user_consent' ||
      state == 'waiting_edu';

  void _syncDeviceTools() {
    final sync = _deviceToolSync;
    if (sync == null) return;
    // 推送可能延迟或被系统拦截，SSE 已知任务等待时立即主动补拉。
    unawaited(() async {
      try {
        await sync();
      } catch (_) {
        // 任务保留在服务端，后续推送、恢复前台或重连仍会再次补拉。
      }
    }());
  }

  List<AiPersonalDataEvidence> _evidenceForRun(String runId) =>
      List.unmodifiable(_personalDataEvidence[runId] ?? const []);

  void _mergePersonalDataEvidence(
    String runId,
    List<AiPersonalDataEvidence> incoming,
  ) {
    if (runId.isEmpty || incoming.isEmpty) return;
    final current = _personalDataEvidence.putIfAbsent(
      runId,
      () => <AiPersonalDataEvidence>[],
    );
    _mergeEvidenceList(current, incoming);
  }

  void _mergeEvidenceList(
    List<AiPersonalDataEvidence> target,
    List<AiPersonalDataEvidence> incoming,
  ) {
    final known = target.map((item) => item.stableKey).toSet();
    for (final item in incoming) {
      if (known.add(item.stableKey)) target.add(item);
    }
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'rag_insufficient_sources':
        return '当前已发布资料不足，暂时无法回答这个问题';
      case 'rag_unavailable':
        return '政策资料服务暂时不可用，请稍后重试';
      case 'provider_missing_citations':
        return '回答未生成可核验来源，请重试';
      case 'output_limit_reached':
        return '回答达到长度上限，未完整生成，请重试';
      case 'knowledge_validation_failed':
        return '政策资料校验失败，请稍后重试';
      case 'server_restarted':
        return '服务刚刚恢复，本次回答未完成，请重新提问';
      case 'context_cancelled':
        return '本次回答已取消';
      case 'run_expired':
        return '本次回答已过期，请重新提问';
      case 'personal_context_unavailable':
        return '暂时没有可核验的学业数据，请先刷新成绩和学分后重试';
      case 'tool_call_limit':
        return '本次分析步骤过多，请一次只问一个问题后重试';
      case 'tool_loop_limit':
        return '本次分析步骤达到上限，请缩小问题范围后重试';
      case 'academic_snapshot_corrupted':
        return '学业数据校验失败，请刷新教务数据后重试';
      case 'external_mcp_disabled':
      case 'external_mcp_tool_missing':
        return '学业分析服务正在更新，请稍后重试';
      case 'external_mcp_unavailable':
        return '学业分析服务暂时不可用，请稍后重试';
      case 'external_mcp_timeout':
        return '学业分析服务响应超时，请稍后重试';
      case 'external_mcp_protocol_error':
      case 'external_mcp_invalid_result':
        return '学业分析结果校验失败，请稍后重试';
      case 'external_mcp_constraint_violation':
        return '当前数据不满足分析条件，请刷新数据或缩小问题范围后重试';
      case 'rate_limited':
        return '当前请求较多，请稍后重试';
      case 'provider_timeout':
        return '回答服务响应超时，请稍后重试';
      case 'provider_unavailable':
      case 'authentication_error':
        return '回答服务暂时不可用，请稍后重试';
      case 'content_rejected':
        return '该问题暂时无法处理，请调整表述后重试';
      case 'invalid_response':
      case 'unknown_provider_error':
        return '回答结果异常，请重新提问';
      default:
        return '回答生成失败，请稍后重试';
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _streamGeneration++;
    super.dispose();
  }
}

const int _quickPromptDisplayCount = 4;

const List<AiQuickPrompt> aiCommonQuestionBank = [
  AiQuickPrompt(
    category: '竞赛规划',
    question: '对比适合我的竞赛',
    feature: AiQuickPromptFeature.competitionCompare,
  ),
  AiQuickPrompt(
    category: '学业分析',
    question: '分析我的学业情况',
    feature: AiQuickPromptFeature.academicAnalysis,
  ),
  AiQuickPrompt(
    category: '学习计划',
    question: '制定本周学习计划',
    feature: AiQuickPromptFeature.weekPlan,
  ),
  AiQuickPrompt(
    category: '学业考试',
    question: '挂科后怎么办',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学业考试',
    question: '补考成绩怎么算',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学业考试',
    question: '补考没过怎么办',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '教学管理',
    question: '重修有什么规定',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '教学管理',
    question: '重修成绩如何记载',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学业考试',
    question: '实践课不及格怎么办',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '教学管理',
    question: '缓考怎么申请',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '教学管理',
    question: '课程免修怎么申请',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学籍管理',
    question: '休学如何办理',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学籍管理',
    question: '复学需要什么材料',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学籍管理',
    question: '转专业有什么条件',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学籍管理',
    question: '退学有哪些规定',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学籍管理',
    question: '最长修业年限是几年',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '奖学金怎么评',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '国家奖学金申请条件',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '励志奖学金申请条件',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '助学金怎么申请',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '家庭经济困难如何认定',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '勤工助学怎么申请',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '学费交不起怎么办',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '应征入伍有哪些资助',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '奖助评优',
    question: '孤儿学生有哪些资助',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '学业考试',
    question: '考试违纪怎么处理',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '毕业学位',
    question: '学位授予有哪些条件',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '校历如何安排',
    feature: AiQuickPromptFeature.policy,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '今天下午有课吗',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '本周哪天空闲',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '下周一有课吗',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '找两小时空闲',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '明天第一节有课吗',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '这周末有课吗',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '今天晚上有课吗',
    feature: AiQuickPromptFeature.schedule,
  ),
  AiQuickPrompt(
    category: '校园日程',
    question: '下周哪天没课',
    feature: AiQuickPromptFeature.schedule,
  ),
];

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final value = bytes.map(hex).join();
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
      '${value.substring(12, 16)}-${value.substring(16, 20)}-'
      '${value.substring(20)}';
}
