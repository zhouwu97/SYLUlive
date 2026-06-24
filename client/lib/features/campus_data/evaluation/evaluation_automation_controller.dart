library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'evaluation_models.dart';
import 'evaluation_automation_models.dart';
import 'evaluation_page_detector.dart';
import 'evaluation_webview_controller.dart';
import 'evaluation_scripts/evaluation_list_script.dart';
import 'evaluation_scripts/evaluation_navigation_script.dart';
import 'evaluation_scripts/evaluation_save_script.dart';

/// Orchestrates the automated batch evaluation flow.
class EvaluationAutomationController extends ChangeNotifier {
  final EvaluationWebViewController webViewController;

  EvaluationAutomationProgress _progress = const EvaluationAutomationProgress();
  EvaluationAutomationProgress get progress => _progress;

  int _currentToken = 0;
  bool _disposed = false;
  final Set<String> _processedFingerprints = {};
  
  // Anti-loop limits
  static const int _maxRetriesPerItem = 1;
  static const int _maxTotalItems = 100; // 已放开上限，支持全部自动完成
  
  int _consecutiveIdenticalFingerprint = 0;
  String _lastSeenFingerprint = '';
  bool _submitMode = false;

  EvaluationAutomationController({required this.webViewController});

  InAppWebViewController? get _rawCtrl =>
      // We need a way to access the raw InAppWebViewController. 
      // Instead of coupling tightly, we'll expose a getter or pass it, but since 
      // we need to run JS, we must either expose it on EvaluationWebViewController
      // or find another way. Let's assume EvaluationWebViewController has an internal way
      // or we can just add `InAppWebViewController? get webView` to it.
      null; // WILL FIX THIS BY ADDING IT TO EvaluationWebViewController

  /// Attempt to fill and save the current single item immediately.
  Future<void> fillAndSaveCurrent() async {
    if (_progress.state != EvaluationAutomationState.idle &&
        _progress.state != EvaluationAutomationState.completed &&
        _progress.state != EvaluationAutomationState.failed &&
        _progress.state != EvaluationAutomationState.stopped) {
      return; // Already running
    }

    _startOp(EvaluationAutomationState.filling);
    final token = _currentToken;

    try {
      await _runSingleItemFlow(token);
      if (_disposed || token != _currentToken) return;

      _updateProgress(
        state: EvaluationAutomationState.completed,
        message: '已填写并保存当前项',
      );
    } catch (e) {
      if (_disposed || token != _currentToken) return;
      _handleFailure(e.toString());
    }
  }

  /// Start the full batch process.
  Future<void> startBatch({bool submitMode = false}) async {
    if (_progress.state != EvaluationAutomationState.idle &&
        _progress.state != EvaluationAutomationState.completed &&
        _progress.state != EvaluationAutomationState.failed &&
        _progress.state != EvaluationAutomationState.stopped) {
      return; // Already running
    }

    _processedFingerprints.clear();
    _consecutiveIdenticalFingerprint = 0;
    _lastSeenFingerprint = '';
    _submitMode = submitMode;
    
    _startOp(EvaluationAutomationState.probing);
    final token = _currentToken;

    try {
      await _batchLoop(token);
    } catch (e) {
      if (_disposed || token != _currentToken) return;
      _handleFailure(e.toString());
    }
  }

  void pauseBatch() {
    if (_progress.state == EvaluationAutomationState.paused ||
        _progress.state == EvaluationAutomationState.idle) {
      return;
    }
    _updateProgress(pauseRequested: true, message: '请求暂停，将在当前项保存后生效...');
  }

  Future<void> resumeBatch() async {
    if (_progress.state != EvaluationAutomationState.paused) return;

    _updateProgress(pauseRequested: false, state: EvaluationAutomationState.switchingNext, message: '继续处理...');
    final token = ++_currentToken;

    try {
      await _batchLoop(token);
    } catch (e) {
      if (_disposed || token != _currentToken) return;
      _handleFailure(e.toString());
    }
  }

  void stopBatch() {
    _currentToken++; // Invalidate current tokens
    _updateProgress(
      state: EvaluationAutomationState.stopped,
      message: '已手动停止',
      pauseRequested: false,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _currentToken++;
    super.dispose();
  }

  // ── Private ──

  void _startOp(EvaluationAutomationState state) {
    _currentToken++;
    _updateProgress(
      state: state,
      completedCount: _processedFingerprints.length,
      message: '开始处理...',
      error: null,
      clearError: true,
      pauseRequested: false,
    );
  }

  void _updateProgress({
    EvaluationAutomationState? state,
    int? completedCount,
    int? totalCount,
    String? currentItemLabel,
    String? message,
    bool? pauseRequested,
    String? error,
    bool clearError = false,
  }) {
    if (_disposed) return;
    _progress = _progress.copyWith(
      state: state,
      completedCount: completedCount,
      totalCount: totalCount,
      currentItemLabel: currentItemLabel,
      message: message,
      pauseRequested: pauseRequested,
      error: error,
      clearError: clearError,
    );
    notifyListeners();
    _logStateTransition();
  }

  EvaluationAutomationState _lastLoggedState = EvaluationAutomationState.idle;
  void _logStateTransition() {
    if (_progress.state != _lastLoggedState) {
      if (kDebugMode) {
        debugPrint('[EvaluationFlow] ${_lastLoggedState.name} -> ${_progress.state.name} (${_progress.message ?? ''})');
      }
      _lastLoggedState = _progress.state;
    }
  }

  void _handleFailure(String errorStr) {
    _updateProgress(
      state: EvaluationAutomationState.failed,
      error: errorStr,
      message: '操作异常中断',
    );
    if (kDebugMode) {
      debugPrint('[EvaluationFlow] Failed: $errorStr');
    }
  }

  // --- Core Flow ---

  Future<void> _batchLoop(int token) async {
    while (!_disposed && token == _currentToken) {
      if (_progress.pauseRequested) {
        _updateProgress(state: EvaluationAutomationState.paused, message: '已暂停');
        return;
      }

      if (_progress.completedCount >= _maxTotalItems) {
        _updateProgress(state: EvaluationAutomationState.completed, message: '已达到最大处理上限 ($_maxTotalItems)');
        return;
      }

      // Find next item
      _updateProgress(state: EvaluationAutomationState.switchingNext, message: '正在查找待评项...');
      final nextItem = await _findAndSelectNextPendingItem(token);
      if (nextItem == null) {
        // No more items
        _updateProgress(state: EvaluationAutomationState.completed, message: '所有可用待评项已处理完成');
        return;
      }

      // Wait for the form to load after selection
      _updateProgress(state: EvaluationAutomationState.waitingForForm, message: '等待表单加载...');
      final formReady = await _waitForForm(token, nextItem.fingerprint);
      if (!formReady) {
        throw Exception('表单加载超时或指纹不匹配');
      }

      // Execute Single Flow
      await _runSingleItemFlow(token, expectedFingerprint: nextItem.fingerprint);
      
      if (_disposed || token != _currentToken) return;

      _processedFingerprints.add(nextItem.fingerprint);
      _updateProgress(completedCount: _processedFingerprints.length);
    }
  }

  Future<void> _runSingleItemFlow(int token, {String? expectedFingerprint}) async {
    // 1. Probe
    _updateProgress(state: EvaluationAutomationState.probing, message: '正在解析页面...');
    final pageType = await webViewController.probePage();
    if (_disposed || token != _currentToken) return;

    if (pageType != EvaluationPageType.evaluationForm) {
      throw Exception('当前页面不是评价表单，无法执行填写');
    }

    // 2. Snapshot Pre-Save
    final ctrl = webViewController.webView;
    if (ctrl == null) throw Exception('WebView 未就绪');

    final preSaveRaw = await ctrl.evaluateJavascript(source: buildSaveSnapshotScript());
    final preSave = EvaluationSaveSnapshot.fromJson(jsonDecode(preSaveRaw as String) as Map<String, dynamic>);
    
    final fingerprint = expectedFingerprint ?? preSave.currentFingerprint;
    
    // Cycle detection
    if (fingerprint == _lastSeenFingerprint) {
      _consecutiveIdenticalFingerprint++;
      if (_consecutiveIdenticalFingerprint >= 2) {
        throw Exception('防死循环保护触发：相同指纹连续出现 2 次 [$fingerprint]');
      }
    } else {
      _lastSeenFingerprint = fingerprint;
      _consecutiveIdenticalFingerprint = 0;
    }

    _updateProgress(currentItemLabel: fingerprint.isEmpty ? '当前课程' : fingerprint);

    // 3. Fill
    _updateProgress(state: EvaluationAutomationState.filling, message: '正在填写分值...');
    final fillRes = await webViewController.fill();
    if (_disposed || token != _currentToken) return;
    
    if (fillRes == null || fillRes.error != null) {
      throw Exception(fillRes?.error ?? '填写失败');
    }

    if (kDebugMode) {
      debugPrint('[EvaluationFlow] filled ${fillRes.scoreInputCompletedCount}/${fillRes.scoreInputCount}');
    }

    // 4. Save
    _updateProgress(state: EvaluationAutomationState.saving, message: _submitMode ? '正在提交...' : '正在保存...');
    final rawSave = await ctrl.evaluateJavascript(source: _submitMode ? buildSubmitCurrentScript() : buildSaveCurrentScript());
    final saveRes = jsonDecode(rawSave as String) as Map<String, dynamic>;
    if (saveRes['error'] != null) {
      throw Exception('保存请求失败: ${saveRes['error']}');
    }

    // 5. Wait for Save Success
    _updateProgress(state: EvaluationAutomationState.waitingForSave, message: '等待保存成功确认...');
    final success = await _pollForSaveSuccess(token, ctrl, preSave);
    if (!success) {
      throw Exception('保存超时或未检测到成功标志');
    }

    if (kDebugMode) {
      debugPrint('[EvaluationFlow] save success');
    }
  }

  Future<bool> _pollForSaveSuccess(int token, InAppWebViewController ctrl, EvaluationSaveSnapshot preSave) async {
    const pollInterval = Duration(milliseconds: 250);
    const maxDuration = Duration(seconds: 10);
    final startTime = DateTime.now();

    while (DateTime.now().difference(startTime) < maxDuration) {
      if (_disposed || token != _currentToken) return false;

      final raw = await ctrl.evaluateJavascript(source: buildSaveSnapshotScript());
      if (raw != null) {
        final current = EvaluationSaveSnapshot.fromJson(jsonDecode(raw as String) as Map<String, dynamic>);
        
        // Success Conditions
        if (current.successMarkerCount > preSave.successMarkerCount) return true;
        if (current.savedCount > preSave.savedCount) return true;
        if (current.rowStatus != null && current.rowStatus != preSave.rowStatus && 
            (current.rowStatus!.contains('已评') || current.rowStatus!.contains('保存') || current.rowStatus!.contains('提交'))) {
          return true;
        }
      }

      await Future.delayed(pollInterval);
    }

    return false; // Timeout
  }

  Future<EvaluationListItem?> _findAndSelectNextPendingItem(int token) async {
    final ctrl = webViewController.webView;
    if (ctrl == null) return null;

    const maxPagesToSearch = 10;
    int pagesSearched = 0;

    while (pagesSearched < maxPagesToSearch) {
      if (_disposed || token != _currentToken) return null;

      final rawList = await ctrl.evaluateJavascript(source: buildGetEvaluationListScript());
      if (rawList == null) return null;

      final Map<String, dynamic> listData = jsonDecode(rawList as String) as Map<String, dynamic>;
      if (listData['error'] != null) {
        if (kDebugMode) debugPrint('[EvaluationFlow] list error: ${listData['error']}');
        return null;
      }

      final itemsRaw = listData['items'] as List<dynamic>? ?? [];
      final items = itemsRaw.map((e) => EvaluationListItem.fromJson(e as Map<String, dynamic>)).toList();

      for (final item in items) {
        final isTarget = _submitMode 
            ? item.status == EvaluationItemStatus.saved
            : item.status == EvaluationItemStatus.pending;

        if (isTarget && !_processedFingerprints.contains(item.fingerprint)) {
          // Select it
          final rawSel = await ctrl.evaluateJavascript(source: buildSelectNextPendingScript(item.rowId));
          final selData = jsonDecode(rawSel as String) as Map<String, dynamic>;
          if (selData['error'] == null) {
            return item;
          }
        }
      }

      // No pending found on this page. Try next page.
      final nextResRaw = await ctrl.evaluateJavascript(source: buildGoToNextPageScript());
      if (nextResRaw == null) return null;
      final nextRes = jsonDecode(nextResRaw as String) as Map<String, dynamic>;
      if (nextRes['error'] != null) {
        // No more pages
        return null;
      }

      // Wait a moment for page load
      await Future.delayed(const Duration(milliseconds: 1000));
      pagesSearched++;
    }

    return null;
  }

  Future<bool> _waitForForm(int token, String expectedFingerprint) async {
    const pollInterval = Duration(milliseconds: 250);
    const maxDuration = Duration(seconds: 10);
    final startTime = DateTime.now();
    final ctrl = webViewController.webView;
    if (ctrl == null) return false;

    while (DateTime.now().difference(startTime) < maxDuration) {
      if (_disposed || token != _currentToken) return false;

      // 1. Must be evaluation form page
      await webViewController.probePage();
      if (webViewController.currentPageType == EvaluationPageType.evaluationForm) {
        // 2. Must match new fingerprint
        final raw = await ctrl.evaluateJavascript(source: buildSaveSnapshotScript());
        if (raw != null) {
          final current = EvaluationSaveSnapshot.fromJson(jsonDecode(raw as String) as Map<String, dynamic>);
          if (current.currentFingerprint == expectedFingerprint) {
            return true;
          }
        }
      }

      await Future.delayed(pollInterval);
    }
    return false;
  }
}
