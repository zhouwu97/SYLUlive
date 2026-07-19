import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../models/ai_capabilities.dart';
import '../models/ai_chat_message.dart';
import '../models/ai_quota.dart';
import '../models/ai_run_event.dart';
import '../models/ai_source.dart';
import '../services/ai_assistant_service.dart';

enum AiConnectionState { idle, connecting, streaming, completed, failed }

enum AiSubmitResult { accepted, blank, tooLong, unavailable, quotaExceeded }

String normalizeAiMessage(String value) {
  return value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
}

int aiVisibleCharacterCount(String value) =>
    normalizeAiMessage(value).characters.length;

class AiAssistantProvider extends ChangeNotifier {
  final AiAssistantService _service;

  AiAssistantProvider(
    this._service, {
    AiCapabilities? initialCapabilities,
  })  : _capabilities = initialCapabilities,
        _quota = initialCapabilities?.quota;

  AiCapabilities? _capabilities;
  AiQuota? _quota;
  final List<AiChatMessage> _messages = [];
  AiRunEvent? _currentRun;
  AiConnectionState _connectionState = AiConnectionState.idle;
  String _streamedText = '';
  List<AiSource> _sources = [];
  String? _error;
  bool _loading = false;

  AiCapabilities? get capabilities => _capabilities;
  AiQuota? get quota => _quota;
  List<AiChatMessage> get messages => List.unmodifiable(_messages);
  AiRunEvent? get currentRun => _currentRun;
  AiConnectionState get connectionState => _connectionState;
  String get streamedText => _streamedText;
  List<AiSource> get sources => List.unmodifiable(_sources);
  String? get error => _error;
  bool get loading => _loading;
  bool get isRunning =>
      _connectionState == AiConnectionState.connecting ||
      _connectionState == AiConnectionState.streaming;
  String get friendlyRunStatus {
    final raw = (_currentRun?.status ?? '').toLowerCase();
    if (raw.contains('schedule') || raw.contains('course')) {
      return '正在查看已保存的课表…';
    }
    if (raw.contains('rag') ||
        raw.contains('retriev') ||
        raw.contains('policy') ||
        raw.contains('vector')) {
      return '正在查找学校资料…';
    }
    return '正在整理回答…';
  }

  List<String> get quickPrompts {
    final prompts = <String>[];
    if (_capabilities?.features.policyRag == true) {
      prompts.addAll(const ['补考成绩怎么算', '重修有什么规定', '奖学金怎么评', '校历如何安排']);
    }
    if (_capabilities?.features.scheduleWindows == true) {
      prompts.addAll(const ['今天下午有课吗', '本周哪天空闲', '下周一有课吗', '找两小时空闲']);
    }
    return prompts;
  }

  Future<void> refreshCapabilities() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _service.getCapabilities();
      _capabilities = result;
      _quota = result.quota;
    } catch (_) {
      _error = '暂时无法读取 AI 服务状态';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  AiSubmitResult submit(String rawMessage) {
    final message = normalizeAiMessage(rawMessage);
    if (message.isEmpty) return AiSubmitResult.blank;
    final maxChars = _capabilities?.maxMessageChars ?? 20;
    if (message.characters.length > maxChars) return AiSubmitResult.tooLong;
    if ((_quota?.remaining ?? 0) <= 0) return AiSubmitResult.quotaExceeded;
    if (_capabilities?.chatEnabled != true) {
      _error = '基础设施测试中，暂未开放真实问答';
      notifyListeners();
      return AiSubmitResult.unavailable;
    }

    // P1 接入 create-run/SSE 后由此处进入真实发送；P0 不构造假消息。
    _error = '问答通道尚未开放';
    notifyListeners();
    return AiSubmitResult.unavailable;
  }

  /// 预留给 P1 的 SSE 事件入口；所有流式状态集中在 Provider，页面不自行拼接。
  void applyRunEvent(AiRunEvent event) {
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
        break;
      case AiRunEventType.sources:
        _sources = List<AiSource>.unmodifiable(event.sources);
        break;
      case AiRunEventType.completed:
        _connectionState = AiConnectionState.completed;
        if (event.quota != null) _quota = event.quota;
        break;
      case AiRunEventType.failed:
        _connectionState = AiConnectionState.failed;
        _error = event.text.isEmpty ? '回答生成失败，请稍后重试' : event.text;
        break;
    }
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}
