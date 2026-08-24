import 'dart:async';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../models/ai_capabilities.dart';
import '../models/ai_chat_message.dart';
import '../models/ai_agent_activity.dart';
import '../models/ai_agent_activity_reducer.dart';
import '../models/ai_conversation.dart';
import '../models/ai_personal_data_evidence.dart';
import '../models/ai_quick_prompt.dart';
import '../models/ai_quota.dart';
import '../models/ai_run.dart';
import '../models/ai_run_event.dart';
import '../models/ai_run_feedback.dart';
import '../models/ai_source.dart';
import '../models/agent_context.dart';
import '../models/user_calendar.dart';
import '../services/ai_assistant_service.dart';
import '../utils/ai_citation_mapper.dart';

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
  final AgentLaunchContext? _launchContext;
  final AiCapabilities? _initialCapabilities;

  AiAssistantProvider(
    this._service, {
    AiCapabilities? initialCapabilities,
    Future<void> Function()? deviceToolSync,
    Random? random,
    AgentLaunchContext? launchContext,
  })  : _capabilities = initialCapabilities,
        _quota = initialCapabilities?.quota,
        _initialCapabilities = initialCapabilities,
        _deviceToolSync = deviceToolSync,
        _launchContext = launchContext,
        _random = random ?? Random() {
    _syncQuickPrompts();
  }

  AiCapabilities? _capabilities;
  AiQuota? _quota;
  final List<AiChatMessage> _messages = [];
  final List<AiRunEvent> _agentActivityEvents = [];
  final List<AiConversation> _conversations = [];
  AiRunEvent? _currentRun;
  AiRunEvent? _agentEvent;
  String? _activeSubmissionRequestId;
  bool _agentFlowCompleted = false;
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
  final Set<String> _sentRunSignals = <String>{};
  bool _loading = false;
  bool _loadingConversations = false;
  bool _disposed = false;
  int _streamGeneration = 0;
  StreamSubscription<AiRunEvent>? _eventSubscription;
  Completer<void>? _eventStreamDone;
  int? _sessionAccountId;
  int _authSessionGeneration = 0;
  int _accountRequestGeneration = 0;
  int _capabilitiesRequestVersion = 0;
  int _conversationListRequestVersion = 0;
  int _conversationOpenRequestVersion = 0;
  int _bootstrapRequestVersion = 0;
  bool _hasSessionContext = false;
  List<AiQuickPrompt> _quickPrompts = const [];
  String _quickPromptPoolKey = '';

  AiCapabilities? get capabilities => _capabilities;
  AiQuota? get quota => _quota;
  List<AiChatMessage> get messages => List.unmodifiable(_messages);
  List<AiConversation> get conversations => List.unmodifiable(_conversations);
  AiRunEvent? get currentRun => _currentRun;
  AiRunEvent? get agentEvent => _agentEvent;
  List<AiAgentActivity> get agentActivities =>
      AiAgentActivityReducer.reduce(_agentActivityEvents,
          completed: _agentFlowCompleted);
  String? get activeSubmissionRequestId => _activeSubmissionRequestId;
  bool get agentFlowCompleted => _agentFlowCompleted;
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
  bool get canUseExistingData => _lastFailedSubmission != null && !isRunning;
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
      case AiRunEventType.agentActivity:
        return _currentRun?.text.trim().isNotEmpty == true
            ? _currentRun!.text.trim()
            : '正在处理当前问题…';
      case AiRunEventType.goalUpdated:
        return '正在理解你的目标…';
      case AiRunEventType.contextResolved:
        return '正在核对当前页面和授权上下文…';
      case AiRunEventType.planRevised:
        return '正在根据最新结果调整计划…';
      case AiRunEventType.approvalRequired:
        return '安排已拟好，等待你的确认';
      case AiRunEventType.actionCommitted:
        return '安排已添加';
      case AiRunEventType.actionFailed:
        return '安排未能添加';
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

  /// 绑定服务器校园 Agent 的账号上下文。
  ///
  /// 账号或 Auth session epoch 变化时立即清理历史、当前 Run、
  /// 授权卡和 SSE；所有已发出请求都通过 capture 丢弃迟到结果。
  void resetForAccountChange({
    required int? accountId,
    required int sessionGeneration,
  }) {
    final normalizedAccountId =
        accountId != null && accountId > 0 ? accountId : null;
    if (_hasSessionContext &&
        _sessionAccountId == normalizedAccountId &&
        _authSessionGeneration == sessionGeneration) {
      return;
    }

    final firstBinding = !_hasSessionContext;
    _hasSessionContext = true;
    _sessionAccountId = normalizedAccountId;
    _authSessionGeneration = sessionGeneration;
    _accountRequestGeneration++;
    _capabilitiesRequestVersion++;
    _conversationListRequestVersion++;
    _conversationOpenRequestVersion++;
    _bootstrapRequestVersion++;
    _bootstrapFuture = null;
    _streamGeneration++;
    unawaited(_cancelActiveEventStream());

    _capabilities = firstBinding && normalizedAccountId != null
        ? _initialCapabilities
        : null;
    _quota = _capabilities?.quota;
    _messages.clear();
    _conversations.clear();
    _conversationId = null;
    _resetRunState();
    _loading = false;
    _loadingConversations = false;
    _syncQuickPrompts();
    _notify();
  }

  /// 更新服务器校园 Agent 推送到消息中的日历草稿状态。
  /// 执行仍由 Action Draft API 完成，这里只同步当前消息卡片。
  void replaceCalendarActionDraft(UserCalendarActionDraft updated) {
    var changed = false;
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      if (!message.calendarActionDrafts.any((item) => item.id == updated.id)) {
        continue;
      }
      _messages[index] = message.copyWith(
        calendarActionDrafts: message.calendarActionDrafts
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false),
      );
      changed = true;
    }
    if (changed) _notify();
  }

  void refreshQuickPrompts() {
    _selectQuickPrompts(avoidCurrent: true);
    _notify();
  }

  Future<void>? _bootstrapFuture;

  Future<void> retryBootstrap() {
    final running = _bootstrapFuture;
    if (running != null) return running;
    late final Future<void> next;
    next = _retryBootstrapInternal().whenComplete(() {
      if (identical(_bootstrapFuture, next)) _bootstrapFuture = null;
    });
    _bootstrapFuture = next;
    return next;
  }

  Future<void> _retryBootstrapInternal() async {
    final sessionRequest = _captureSessionRequest();
    final requestVersion = ++_bootstrapRequestVersion;
    _error = null;
    _loading = true;
    _notify();

    try {
      await refreshCapabilities(silent: true);
      if (!_ownsSessionRequest(sessionRequest) ||
          requestVersion != _bootstrapRequestVersion) {
        return;
      }
      await loadConversations();
    } finally {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _bootstrapRequestVersion) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> initialize() async {
    await retryBootstrap();
  }

  Future<void> refreshCapabilities({bool silent = false}) async {
    final sessionRequest = _captureSessionRequest();
    final requestVersion = ++_capabilitiesRequestVersion;
    if (!silent) {
      _loading = true;
      _error = null;
      _notify();
    }
    try {
      final result = await _service.getCapabilities();
      if (!_ownsSessionRequest(sessionRequest) ||
          requestVersion != _capabilitiesRequestVersion) {
        return;
      }
      _capabilities = result;
      _quota = result.quota;
      _syncQuickPrompts();
    } catch (_) {
      if (!silent &&
          _ownsSessionRequest(sessionRequest) &&
          requestVersion == _capabilitiesRequestVersion) {
        _error = '暂时无法读取 AI 服务状态';
      }
    } finally {
      if (!silent &&
          _ownsSessionRequest(sessionRequest) &&
          requestVersion == _capabilitiesRequestVersion) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> loadConversations() async {
    final sessionRequest = _captureSessionRequest();
    final requestVersion = ++_conversationListRequestVersion;
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
      if (!_ownsSessionRequest(sessionRequest) ||
          requestVersion != _conversationListRequestVersion) {
        return;
      }
      _conversations
        ..clear()
        ..addAll(result);
    } on AiAssistantServiceException catch (error) {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _conversationListRequestVersion) {
        _error = error.message;
      }
    } catch (_) {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _conversationListRequestVersion) {
        _error = '读取历史会话失败，请稍后重试';
      }
    } finally {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _conversationListRequestVersion) {
        _loadingConversations = false;
        _notify();
      }
    }
  }

  Future<void> startNewConversation() async {
    if (isRunning) return;
    _streamGeneration++;
    _conversationOpenRequestVersion++;
    await _cancelActiveEventStream();
    _conversationId = null;
    _messages.clear();
    _resetRunState();
    _selectQuickPrompts(avoidCurrent: true);
    _notify();
  }

  Future<void> openConversation(String id) async {
    if (isRunning || id == _conversationId) return;
    final sessionRequest = _captureSessionRequest();
    final requestVersion = ++_conversationOpenRequestVersion;
    _loading = true;
    _error = null;
    _notify();
    try {
      final details = await _service.getConversation(id);
      if (!_ownsSessionRequest(sessionRequest) ||
          requestVersion != _conversationOpenRequestVersion) {
        return;
      }
      _streamGeneration++;
      await _cancelActiveEventStream();
      if (!_ownsSessionRequest(sessionRequest) ||
          requestVersion != _conversationOpenRequestVersion) {
        return;
      }
      _conversationId = id;
      _messages
        ..clear()
        ..addAll(details.messages.map(_fromHistory));
      _resetRunState();
      _moveConversationToFront(details.conversation);
      await _restoreSources(
        details.messages,
        sessionRequest: sessionRequest,
        conversationRequestVersion: requestVersion,
      );
    } on AiAssistantServiceException catch (error) {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _conversationOpenRequestVersion) {
        _error = error.message;
      }
    } catch (_) {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _conversationOpenRequestVersion) {
        _error = '会话加载失败，请稍后重试';
      }
    } finally {
      if (_ownsSessionRequest(sessionRequest) &&
          requestVersion == _conversationOpenRequestVersion) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> deleteConversation(String id) async {
    final sessionRequest = _captureSessionRequest();
    try {
      await _service.deleteConversation(id);
      if (!_ownsSessionRequest(sessionRequest)) return;
      _conversations.removeWhere((item) => item.id == id);
      if (_conversationId == id) await startNewConversation();
      _notify();
    } on AiAssistantServiceException catch (error) {
      if (!_ownsSessionRequest(sessionRequest)) return;
      _error = error.message;
      _notify();
      rethrow;
    } catch (_) {
      if (!_ownsSessionRequest(sessionRequest)) return;
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
    final sessionRequest = _captureSessionRequest();
    _recordUserIntentSignals(submission.message);
    _error = null;
    _lastFailedSubmission = null;
    _streamedText = '';
    _sources = [];
    _personalDataEvidence.clear();
    _lastEventSeq = 0;
    _activeSubmissionRequestId = submission.requestId;
    _agentEvent = null;
    _agentFlowCompleted = false;
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

    unawaited(_submitAsync(submission, sessionRequest));
    return AiSubmitResult.accepted;
  }

  Future<void> _submitAsync(
    AiPendingSubmission submission,
    _AiSessionRequest sessionRequest,
  ) async {
    try {
      final creation = await _service.createRun(
        conversationId: submission.conversationId,
        clientRequestId: submission.requestId,
        message: submission.message,
        launchContext: _launchContext,
      );
      if (!_ownsSessionRequest(sessionRequest)) return;
      _run = creation.run;
      _conversationId = creation.run.conversationId;
      _replaceUserStatus(submission.requestId, AiMessageStatus.completed);
      unawaited(
          _consumeEvents(creation.run.id, generation: ++_streamGeneration));
    } on AiAssistantServiceException catch (exception) {
      if (_ownsSessionRequest(sessionRequest)) {
        _handleSubmitFailure(submission, exception);
      }
    } catch (_) {
      if (_ownsSessionRequest(sessionRequest)) {
        _handleSubmitFailure(
          submission,
          const AiAssistantServiceException(
            '请求发送失败，请检查网络后重试',
            retryable: true,
          ),
        );
      }
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

  /// 刷新失败时，用户明确选择继续使用已有数据；这是新的 Run，
  /// 通过自然语言约束服务端采用 allow_stale，而不是静默复用失败 Run。
  AiSubmitResult useExistingData() {
    final submission = _lastFailedSubmission;
    if (submission == null) return AiSubmitResult.blank;
    final blocked = _submissionBlocker();
    if (blocked != null) return blocked;
    final message = normalizeAiMessage(
      '${submission.message}。请按已有校园数据分析，不要刷新最新数据。',
    );
    final maxChars =
        _capabilities?.maxMessageChars ?? AiCapabilities.defaultMessageChars;
    if (message.characters.length > maxChars) return AiSubmitResult.tooLong;
    _messages.removeWhere(
      (item) =>
          item.role == AiMessageRole.user &&
          item.requestId == submission.requestId,
    );
    return _startSubmission(AiPendingSubmission(
      requestId: _uuidV4(),
      conversationId: submission.conversationId,
      message: message,
    ));
  }

  Future<void> cancel() async {
    final sessionRequest = _captureSessionRequest();
    final runId = _run?.id;
    if (runId == null || !isRunning) return;
    try {
      await _service.cancelRun(runId);
      if (!_ownsSessionRequest(sessionRequest)) return;
      _connectionState = AiConnectionState.cancelled;
      _error = '已取消本次回答';
      _streamGeneration++;
      unawaited(_recordRunSignalOnce(runId, 'run.abandoned'));
      _notify();
      unawaited(refreshCapabilities(silent: true));
    } on AiAssistantServiceException catch (exception) {
      if (!_ownsSessionRequest(sessionRequest)) return;
      _error = exception.message;
      _notify();
    } catch (_) {
      if (!_ownsSessionRequest(sessionRequest)) return;
      _error = '取消回答失败，请稍后重试';
      _notify();
    }
  }

  Future<bool> submitConsent(bool granted) async {
    final sessionRequest = _captureSessionRequest();
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
      if (!_ownsSessionRequest(sessionRequest)) return false;
      if (identical(_pendingConsent, consent)) _pendingConsent = null;
      return true;
    } on AiAssistantServiceException catch (exception) {
      if (!_ownsSessionRequest(sessionRequest)) return false;
      _error = exception.message;
      return false;
    } catch (_) {
      if (!_ownsSessionRequest(sessionRequest)) return false;
      _error = '提交本次授权失败，请稍后重试';
      return false;
    } finally {
      if (_ownsSessionRequest(sessionRequest)) {
        _submittingConsent = false;
        _notify();
      }
    }
  }

  Future<void> reconnect() async {
    final runId = _run?.id;
    if (runId == null || isRunning) return;
    _error = null;
    _connectionState = AiConnectionState.connecting;
    _notify();
    await _cancelActiveEventStream();
    await _consumeEvents(runId,
        generation: ++_streamGeneration, allowReconnect: false);
  }

  Future<void> _consumeEvents(
    String runId, {
    required int generation,
    bool allowReconnect = true,
  }) async {
    try {
      await _cancelActiveEventStream();
      if (_disposed || generation != _streamGeneration) return;

      final done = Completer<void>();
      late final StreamSubscription<AiRunEvent> subscription;
      void completeStream() {
        if (!done.isCompleted) done.complete();
      }

      subscription =
          _service.streamRunEvents(runId, lastEventId: _lastEventSeq).listen(
        (event) {
          if (_disposed || generation != _streamGeneration) {
            unawaited(subscription.cancel());
            completeStream();
            return;
          }
          applyRunEvent(event);
          if (_isTerminal(event.type)) {
            unawaited(subscription.cancel());
            completeStream();
          }
        },
        onError: (Object _, StackTrace __) => completeStream(),
        onDone: completeStream,
        cancelOnError: false,
      );
      _eventSubscription = subscription;
      _eventStreamDone = done;
      await done.future;

      if (identical(_eventSubscription, subscription)) {
        _eventSubscription = null;
        _eventStreamDone = null;
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

  Future<void> _cancelActiveEventStream() async {
    final subscription = _eventSubscription;
    final done = _eventStreamDone;
    _eventSubscription = null;
    _eventStreamDone = null;
    if (done != null && !done.isCompleted) done.complete();
    await subscription?.cancel();
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
        final hasCitationMarkers = hasAiCitationMarkers(_streamedText);
        _upsertAssistant(
          _streamedText,
          AiMessageStatus.completed,
          sources: _sources,
          sourceRecoveryState: _sources.isEmpty
              ? hasCitationMarkers
                  ? AiSourceRecoveryState.loading
                  : AiSourceRecoveryState.notNeeded
              : AiSourceRecoveryState.loaded,
        );
        if (_sources.isEmpty) await _resolveSourcesForRun(runId);
        if (_disposed || generation != _streamGeneration) return;
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
        if (run.state == 'waiting_device' || run.state == 'waiting_edu') {
          _agentEvent = AiRunEvent(
            runId: run.id,
            type: run.state == 'waiting_device'
                ? AiRunEventType.deviceWaiting
                : AiRunEventType.eduFetching,
            status: run.state,
            datasets: _agentEvent?.datasets ?? const [],
          );
          _agentFlowCompleted = false;
        }
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
      if (!_disposed && generation == _streamGeneration) {
        _connectionState = AiConnectionState.failed;
        _error = '连接已中断，可点击重新连接继续回放';
        _notify();
      }
    }
  }

  /// SSE 回放可能重复到达，统一按 seq 去重，并用 checkpoint 覆盖增量文本。
  void applyRunEvent(AiRunEvent event) {
    if (event.type != AiRunEventType.heartbeat && event.seq > 0) {
      if (event.seq <= _lastEventSeq) return;
      _lastEventSeq = event.seq;
    }
    _currentRun = event;
    if (_isVisibleAgentActivity(event.type)) {
      unawaited(_recordRunSignalOnce(event.runId, 'run.first_activity'));
    }
    if (_isAgentEvent(event.type)) {
      _agentEvent = event;
      _agentFlowCompleted = false;
      _agentActivityEvents.add(event);
    }
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
        if (aiVisibleCharacterCount(_streamedText) >= 8) {
          unawaited(_recordRunSignalOnce(event.runId, 'answer.first_useful'));
        }
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
        _sources = List<AiSource>.unmodifiable(
          deduplicateAiSources(event.sources),
        );
        _upsertAssistant(_streamedText, AiMessageStatus.streaming,
            sources: _sources,
            sourceRecoveryState: AiSourceRecoveryState.loaded,
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
      case AiRunEventType.agentActivity:
      case AiRunEventType.goalUpdated:
      case AiRunEventType.contextResolved:
      case AiRunEventType.planRevised:
        // 工具开始/执行本身不是授权请求。只有带 scope 的 consent.required
        // 才能进入授权 UI，否则“允许本次”没有可提交的授权范围。
        _pendingConsent = null;
        _connectionState = AiConnectionState.streaming;
        break;
      case AiRunEventType.consentRequired:
        _pendingConsent = event.consentScope.trim().isEmpty ? null : event;
        _connectionState = AiConnectionState.streaming;
        break;
      case AiRunEventType.deviceWaiting:
        _pendingConsent = event.consentScope.trim().isEmpty ? null : event;
        _connectionState = AiConnectionState.streaming;
        _syncDeviceTools();
        break;
      case AiRunEventType.eduFetching:
      case AiRunEventType.toolCompleted:
      case AiRunEventType.approvalRequired:
        _connectionState = AiConnectionState.streaming;
        final actionDraft = event.calendarActionDraft;
        if (actionDraft != null) {
          final existing = _calendarActionDraftsForRun(event.runId);
          if (!existing.any((item) => item.id == actionDraft.id)) {
            _upsertAssistant(
              _streamedText,
              AiMessageStatus.streaming,
              calendarActionDrafts: <UserCalendarActionDraft>[
                ...existing,
                actionDraft
              ],
            );
          }
        }
        break;
      case AiRunEventType.actionCommitted:
      case AiRunEventType.actionFailed:
        _connectionState = AiConnectionState.streaming;
        break;
      case AiRunEventType.completed:
        _connectionState = AiConnectionState.completed;
        _agentFlowCompleted = _agentEvent?.runId == event.runId;
        if (event.quota != null) _quota = event.quota;
        final hasCitationMarkers = hasAiCitationMarkers(_streamedText);
        _upsertAssistant(_streamedText, AiMessageStatus.completed,
            sources: _sources,
            sourceRecoveryState: _sources.isEmpty
                ? hasCitationMarkers
                    ? AiSourceRecoveryState.loading
                    : AiSourceRecoveryState.notNeeded
                : AiSourceRecoveryState.loaded,
            personalDataEvidence: _evidenceForRun(event.runId));
        if (_sources.isEmpty && event.runId.isNotEmpty) {
          unawaited(_resolveSourcesForRun(event.runId));
        }
        unawaited(_finishRun());
        break;
      case AiRunEventType.failed:
        _connectionState = AiConnectionState.failed;
        _error = _friendlyError(event.errorCode);
        if (event.retryable && _activeSubmissionRequestId != null) {
          final requestId = _activeSubmissionRequestId!;
          final userMessage = _messages.lastWhere(
            (item) =>
                item.role == AiMessageRole.user && item.requestId == requestId,
            orElse: () => AiChatMessage(
              id: '',
              requestId: '',
              role: AiMessageRole.user,
              content: '',
              status: AiMessageStatus.failed,
              createdAt: DateTime.now(),
            ),
          );
          if (userMessage.requestId.isNotEmpty &&
              userMessage.content.trim().isNotEmpty) {
            _lastFailedSubmission = AiPendingSubmission(
              requestId: userMessage.requestId,
              conversationId: _conversationId ?? '',
              message: userMessage.content,
            );
          }
        }
        if (_streamedText.isNotEmpty) {
          _upsertAssistant(_streamedText, AiMessageStatus.failed,
              sources: _sources,
              sourceRecoveryState: _sources.isEmpty
                  ? AiSourceRecoveryState.failed
                  : AiSourceRecoveryState.loaded,
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
    final sessionRequest = _captureSessionRequest();
    await refreshCapabilities(silent: true);
    if (!_ownsSessionRequest(sessionRequest)) return;
    await loadConversations();
  }

  Future<void> _restoreSources(
    List<AiConversationMessage> history, {
    required _AiSessionRequest sessionRequest,
    required int conversationRequestVersion,
  }) async {
    // 新 DTO 已直接携带 sources；只有旧历史缺少来源时才逐 Run 请求兼容
    // endpoint，绝不再为每条历史消息 replay 一遍完整 SSE。
    for (final message in history.where(
      (item) => item.role == 'assistant' && item.runId != null,
    )) {
      if (!_ownsSessionRequest(sessionRequest) ||
          conversationRequestVersion != _conversationOpenRequestVersion) {
        return;
      }
      final index = _messages.indexWhere((item) => item.id == message.id);
      if (index < 0) continue;
      final inlineSources = deduplicateAiSources(message.sources);
      if (inlineSources.isNotEmpty) {
        _messages[index] = _messages[index].copyWith(
          sources: inlineSources,
          sourceRecoveryState: AiSourceRecoveryState.loaded,
          personalDataEvidence: message.personalDataEvidence,
        );
        if (message.personalDataEvidence.isNotEmpty) continue;
      }
      await _resolveSourcesForMessage(
        messageId: message.id,
        runId: message.runId!,
        content: message.content,
        sessionRequest: sessionRequest,
      );
    }
  }

  Future<void> retryMessageSources(AiChatMessage message) async {
    final sessionRequest = _captureSessionRequest();
    final runId = message.requestId.trim();
    if (runId.isEmpty) return;
    await _resolveSourcesForMessage(
      messageId: message.id,
      runId: runId,
      content: message.content,
      force: true,
      sessionRequest: sessionRequest,
    );
  }

  Future<void> _resolveSourcesForRun(String runId) async {
    final sessionRequest = _captureSessionRequest();
    final index = _messages.lastIndexWhere(
      (item) => item.role == AiMessageRole.assistant && item.requestId == runId,
    );
    if (index < 0) return;
    final message = _messages[index];
    await _resolveSourcesForMessage(
      messageId: message.id,
      runId: runId,
      content: message.content,
      sessionRequest: sessionRequest,
    );
  }

  Future<void> _resolveSourcesForMessage({
    required String messageId,
    required String runId,
    required String content,
    bool force = false,
    _AiSessionRequest? sessionRequest,
  }) async {
    final request = sessionRequest ?? _captureSessionRequest();
    if (!_ownsSessionRequest(request)) return;
    final index = _messages.indexWhere((item) => item.id == messageId);
    if (index < 0) return;
    final current = _messages[index];
    if (!force &&
        current.sources.isNotEmpty &&
        current.personalDataEvidence.isNotEmpty) {
      return;
    }
    final hasCitationMarkers = hasAiCitationMarkers(content);
    final chunkIds = extractAiChunkIds(content);

    _messages[index] = current.copyWith(
      sourceRecoveryState: AiSourceRecoveryState.loading,
    );
    _notify();

    List<AiSource> resolved = deduplicateAiSources(current.sources);
    List<AiPersonalDataEvidence> personalEvidence =
        List<AiPersonalDataEvidence>.from(current.personalDataEvidence);
    try {
      final runSources = await _service.getRunSources(runId);
      if (!_ownsSessionRequest(request)) return;
      if (runSources.sources.isNotEmpty) {
        resolved = deduplicateAiSources([
          ...resolved,
          ...runSources.sources,
        ]);
      }
      _mergeEvidenceList(personalEvidence, runSources.personalDataEvidence);
    } catch (_) {
      // 旧服务端没有来源聚合接口时，继续按 chunk 读取兼容正文。
    }

    if (resolved.isEmpty && chunkIds.isNotEmpty) {
      resolved = await _loadFallbackSources(chunkIds, request);
    }
    if (!_ownsSessionRequest(request)) return;
    final resolvedChunkIds = resolved
        .expand(
          (source) => source.chunkIds.isNotEmpty
              ? source.chunkIds
              : (source.chunkId > 0 ? [source.chunkId] : const <int>[]),
        )
        .toSet();
    final state = !hasCitationMarkers
        ? AiSourceRecoveryState.notNeeded
        : resolved.isNotEmpty &&
                (chunkIds.isEmpty || chunkIds.every(resolvedChunkIds.contains))
            ? AiSourceRecoveryState.loaded
            : AiSourceRecoveryState.failed;
    final latestIndex = _messages.indexWhere((item) => item.id == messageId);
    if (latestIndex < 0) return;
    _messages[latestIndex] = _messages[latestIndex].copyWith(
      sources: resolved,
      sourceRecoveryState: state,
      personalDataEvidence: personalEvidence,
    );
    _mergePersonalDataEvidence(runId, personalEvidence);
    if (_run?.id == runId) {
      _sources = List<AiSource>.unmodifiable(resolved);
    }
    _notify();
  }

  Future<List<AiSource>> _loadFallbackSources(
    List<int> chunkIds,
    _AiSessionRequest sessionRequest,
  ) async {
    final result = <AiSource>[];
    for (final chunkId in chunkIds) {
      if (!_ownsSessionRequest(sessionRequest)) return const <AiSource>[];
      try {
        final content = await _service.getSourceContent(chunkId);
        if (!_ownsSessionRequest(sessionRequest)) return const <AiSource>[];
        result.add(
          AiSource(
            type: AiSourceType.policy,
            chunkId: chunkId,
            chunkIds: [chunkId],
            documentId: content.documentId,
            title: content.title,
            locators: [
              if (content.sectionTitle.trim().isNotEmpty) content.sectionTitle,
              if (content.locator.trim().isNotEmpty) content.locator,
            ],
          ),
        );
      } catch (_) {
        // 单个 chunk 失败不阻断其它来源；最终由 failed 状态明确告知用户。
      }
    }
    return deduplicateAiSources(result);
  }

  AiChatMessage _fromHistory(AiConversationMessage message) {
    return AiChatMessage(
      id: message.id,
      requestId: message.runId ?? message.id,
      role:
          message.role == 'user' ? AiMessageRole.user : AiMessageRole.assistant,
      content: message.content,
      status: AiMessageStatus.completed,
      sources: deduplicateAiSources(message.sources),
      sourceRecoveryState: message.sources.isNotEmpty
          ? AiSourceRecoveryState.loaded
          : AiSourceRecoveryState.notNeeded,
      personalDataEvidence: message.personalDataEvidence,
      createdAt: message.createdAt ?? DateTime.now(),
    );
  }

  void _upsertAssistant(
    String text,
    AiMessageStatus status, {
    List<AiSource>? sources,
    AiSourceRecoveryState? sourceRecoveryState,
    List<AiPersonalDataEvidence>? personalDataEvidence,
    List<UserCalendarActionDraft>? calendarActionDrafts,
  }) {
    if (text.isEmpty &&
        (sources == null || sources.isEmpty) &&
        (personalDataEvidence == null || personalDataEvidence.isEmpty) &&
        (calendarActionDrafts == null || calendarActionDrafts.isEmpty)) {
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
        sourceRecoveryState: sourceRecoveryState,
        personalDataEvidence: personalDataEvidence,
        calendarActionDrafts: calendarActionDrafts,
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
      sourceRecoveryState:
          sourceRecoveryState ?? AiSourceRecoveryState.notNeeded,
      personalDataEvidence: personalDataEvidence ?? const [],
      calendarActionDrafts: calendarActionDrafts ?? const [],
    ));
  }

  List<UserCalendarActionDraft> _calendarActionDraftsForRun(String runId) {
    for (final message in _messages.reversed) {
      if (message.role == AiMessageRole.assistant &&
          message.requestId == runId) {
        return message.calendarActionDrafts;
      }
    }
    return const <UserCalendarActionDraft>[];
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
    _agentEvent = null;
    _agentActivityEvents.clear();
    _activeSubmissionRequestId = null;
    _agentFlowCompleted = false;
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

  Future<void> submitFeedback(
    AiChatMessage message,
    AiRunFeedback feedback,
  ) async {
    final index = _messages.indexWhere((item) => item.id == message.id);
    if (index < 0 || message.requestId.trim().isEmpty) return;
    final current = _messages[index];
    if (current.feedbackStatus == AiFeedbackStatus.submitting ||
        current.feedbackStatus == AiFeedbackStatus.positive ||
        current.feedbackStatus == AiFeedbackStatus.negative) {
      return;
    }
    _messages[index] = current.copyWith(
      feedbackStatus: AiFeedbackStatus.submitting,
      feedbackError: '',
    );
    _notify();
    try {
      await _service.submitRunFeedback(
        runId: message.requestId,
        feedback: feedback,
      );
      final updatedIndex = _messages.indexWhere((item) => item.id == message.id);
      if (updatedIndex >= 0) {
        _messages[updatedIndex] = _messages[updatedIndex].copyWith(
          feedbackStatus: feedback.rating == AiFeedbackRating.positive
              ? AiFeedbackStatus.positive
              : AiFeedbackStatus.negative,
          feedbackReason: feedback.reason,
          feedbackError: '',
        );
      }
    } on AiAssistantServiceException catch (error) {
      final updatedIndex = _messages.indexWhere((item) => item.id == message.id);
      if (updatedIndex >= 0) {
        _messages[updatedIndex] = _messages[updatedIndex].copyWith(
          feedbackStatus: AiFeedbackStatus.failed,
          feedbackError: error.message,
        );
      }
    } catch (_) {
      final updatedIndex = _messages.indexWhere((item) => item.id == message.id);
      if (updatedIndex >= 0) {
        _messages[updatedIndex] = _messages[updatedIndex].copyWith(
          feedbackStatus: AiFeedbackStatus.failed,
          feedbackError: '提交反馈失败，请重试',
        );
      }
    }
    _notify();
  }

  void _recordUserIntentSignals(String message) {
    final previousAssistant = _messages.lastWhere(
      (item) =>
          item.role == AiMessageRole.assistant &&
          item.requestId.trim().isNotEmpty &&
          item.status == AiMessageStatus.completed,
      orElse: () => const AiChatMessage(
        id: '',
        requestId: '',
        role: AiMessageRole.user,
        content: '',
        status: AiMessageStatus.failed,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    if (previousAssistant.requestId.isEmpty) return;
    final age = DateTime.now().difference(previousAssistant.createdAt);
    if (age.isNegative || age > const Duration(minutes: 3)) return;
    if (_looksLikeCorrection(message)) {
      unawaited(_recordRunSignalOnce(
          previousAssistant.requestId, 'possible_user_correction'));
    }
    if (_looksLikeRephrase(message, previousAssistant.content)) {
      unawaited(_recordRunSignalOnce(
          previousAssistant.requestId, 'run.rephrased'));
    }
  }

  bool _looksLikeCorrection(String message) => RegExp(
        r'(不是|理解错|我说的是|我指的是|不用查|别查|不该访问|你弄错)',
      ).hasMatch(normalizeAiMessage(message));

  bool _looksLikeRephrase(String message, String answer) {
    final input = normalizeAiMessage(message);
    if (input.characters.length < 8 || answer.trim().isEmpty) return false;
    return !_looksLikeCorrection(input) &&
        (input.contains('换个说法') ||
            input.contains('重新') ||
            input.contains('再说') ||
            input.contains('具体一点'));
  }

  Future<void> _recordRunSignalOnce(String runId, String signal) async {
    final normalizedRunId = runId.trim();
    if (normalizedRunId.isEmpty) return;
    final key = '$normalizedRunId:$signal';
    if (!_sentRunSignals.add(key)) return;
    try {
      await _service.recordRunSignal(runId: normalizedRunId, signal: signal);
    } catch (_) {
      // 行为指标是 best effort；失败不影响回答、取消或重连。
    }
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
      features?.supportsAcademicAnalysis == true,
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
          // 这三项是空状态中的固定“快捷能力”，不进入“猜你想问”的轮换池。
          return false;
        case AiQuickPromptFeature.academicAnalysis:
          return false;
        case AiQuickPromptFeature.weekPlan:
          return false;
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

  bool _isAgentEvent(AiRunEventType type) => switch (type) {
        AiRunEventType.toolRequested ||
        AiRunEventType.toolExecuting ||
        AiRunEventType.deviceWaiting ||
        AiRunEventType.deviceClaimed ||
        AiRunEventType.agentActivity ||
        AiRunEventType.goalUpdated ||
        AiRunEventType.contextResolved ||
        AiRunEventType.planRevised ||
        AiRunEventType.approvalRequired ||
        AiRunEventType.actionCommitted ||
        AiRunEventType.actionFailed ||
        AiRunEventType.consentRequired ||
        AiRunEventType.eduFetching ||
        AiRunEventType.toolCompleted ||
        AiRunEventType.failed ||
        AiRunEventType.cancelled =>
          true,
        _ => false,
      };

  bool _isVisibleAgentActivity(AiRunEventType type) => switch (type) {
        AiRunEventType.toolRequested ||
        AiRunEventType.toolExecuting ||
        AiRunEventType.deviceWaiting ||
        AiRunEventType.deviceClaimed ||
        AiRunEventType.agentActivity ||
        AiRunEventType.goalUpdated ||
        AiRunEventType.contextResolved ||
        AiRunEventType.planRevised ||
        AiRunEventType.consentRequired ||
        AiRunEventType.eduFetching ||
        AiRunEventType.toolCompleted => true,
        _ => false,
      };

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
    final known = <String, int>{
      for (var index = 0; index < target.length; index++)
        target[index].datasetKey: index,
    };
    for (final item in incoming) {
      final index = known[item.datasetKey];
      if (index == null) {
        known[item.datasetKey] = target.length;
        target.add(item);
        continue;
      }
      final current = target[index];
      final currentTime = current.fetchedAt;
      final incomingTime = item.fetchedAt;
      final incomingIsBetter = current.isStale && !item.isStale ||
          currentTime == null && incomingTime != null ||
          currentTime != null &&
              incomingTime != null &&
              incomingTime.isAfter(currentTime);
      if (incomingIsBetter) target[index] = item;
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
      case 'provider_request_rejected':
        return '回答服务暂时未接受本次请求，请重试';
      case 'invalid_response':
      case 'unknown_provider_error':
        return '回答结果异常，请重新提问';
      default:
        return '回答生成失败，请稍后重试';
    }
  }

  _AiSessionRequest _captureSessionRequest() => _AiSessionRequest(
        accountId: _sessionAccountId,
        authSessionGeneration: _authSessionGeneration,
        providerGeneration: _accountRequestGeneration,
      );

  bool _ownsSessionRequest(_AiSessionRequest request) {
    return !_disposed &&
        request.accountId == _sessionAccountId &&
        request.authSessionGeneration == _authSessionGeneration &&
        request.providerGeneration == _accountRequestGeneration;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _accountRequestGeneration++;
    _streamGeneration++;
    unawaited(_cancelActiveEventStream());
    super.dispose();
  }
}

class _AiSessionRequest {
  const _AiSessionRequest({
    required this.accountId,
    required this.authSessionGeneration,
    required this.providerGeneration,
  });

  final int? accountId;
  final int authSessionGeneration;
  final int providerGeneration;
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
