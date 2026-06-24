/// Controller for InAppWebView lifecycle: probing, filling, navigation, cleanup.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'evaluation_constants.dart';
import 'evaluation_models.dart';
import 'evaluation_page_detector.dart';
import 'evaluation_script_builder.dart';

typedef EvaluationStateCallback = void Function(EvaluationPageType pageType);
typedef EvaluationFillCallback = void Function(EvaluationFillResult result);
typedef EvaluationErrorCallback = void Function(String message);

/// Manages the InAppWebView and all JS interactions for the evaluation flow.
class EvaluationWebViewController {
  InAppWebViewController? _webViewController;
  final EvaluationPageDetector _detector = const EvaluationPageDetector();

  EvaluationPageType _currentPageType = EvaluationPageType.loading;
  EvaluationPageType get currentPageType => _currentPageType;

  EvaluationProbeResult? _lastProbe;
  EvaluationProbeResult? get lastProbe => _lastProbe;

  EvaluationFillResult? _lastFillResult;
  EvaluationFillResult? get lastFillResult => _lastFillResult;

  bool _isFilling = false;
  bool get isFilling => _isFilling;

  bool _isProbing = false;
  bool get isProbing => _isProbing;

  EvaluationStateCallback? onPageTypeChanged;
  EvaluationFillCallback? onFillCompleted;
  EvaluationErrorCallback? onError;

  String? _lastHttpError;
  String? get lastHttpError => _lastHttpError;

  bool _disposed = false;

  InAppWebViewController? get webView => _webViewController;

  void attach(InAppWebViewController controller) {
    _webViewController = controller;
  }

  void detach() {
    _webViewController = null;
  }

  /// Run the probe script and classify the page.
  Future<EvaluationPageType> probePage() async {
    final ctrl = _webViewController;
    if (ctrl == null) return EvaluationPageType.loading;
    if (_isProbing || _disposed) return _currentPageType;

    _isProbing = true;
    try {
      final raw = await ctrl.evaluateJavascript(source: buildProbeScript());
      _lastProbe = _parseProbeResult(raw);
      _currentPageType = _detector.classify(_lastProbe!, _lastHttpError);

      if (_currentPageType == EvaluationPageType.evaluationForm) {
        _lastHttpError = null; // Clear old HTTP error if form is valid
      }

      if (kDebugMode) {
        debugPrint(
          '[Evaluation] probe: ${_lastProbe!.debugSummary} → $_currentPageType',
        );
      }

      onPageTypeChanged?.call(_currentPageType);
      return _currentPageType;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Evaluation] probe error: $e');
      }
      _currentPageType = EvaluationPageType.unknown;
      _lastProbe = _emptyProbe('Dart probe exception: $e');
      onPageTypeChanged?.call(_currentPageType);
      return _currentPageType;
    } finally {
      _isProbing = false;
    }
  }

  /// Execute the fill script.
  Future<EvaluationFillResult?> fill() async {
    final ctrl = _webViewController;
    if (ctrl == null) return null;
    if (_isFilling || _disposed) return _lastFillResult;

    if (_currentPageType != EvaluationPageType.evaluationForm) {
      onError?.call('请先在网页中选择一门待评价课程。');
      return null;
    }

    _isFilling = true;
    try {
      final raw = await ctrl.evaluateJavascript(source: buildFillScript());
      _lastFillResult = _parseFillResult(raw);

      if (kDebugMode) {
        debugPrint(
          '[Evaluation] fill: radio ${_lastFillResult!.radioCompletedGroups}/${_lastFillResult!.radioTotalGroups}, '
          'score ${_lastFillResult!.scoreInputCompletedCount}/${_lastFillResult!.scoreInputCount}, '
          '${_lastFillResult!.unresolvedRadioGroups.length + _lastFillResult!.unresolvedScoreInputs.length} unresolved, '
          '${_lastFillResult!.warnings.length} warnings',
        );
      }

      onFillCompleted?.call(_lastFillResult!);
      return _lastFillResult;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Evaluation] fill error: $e');
      }
      _lastFillResult = EvaluationFillResult.error('填写脚本执行失败: $e');
      onFillCompleted?.call(_lastFillResult!);
      return _lastFillResult;
    } finally {
      _isFilling = false;
    }
  }

  Future<void> reload() async {
    _lastHttpError = null;
    final ctrl = _webViewController;
    if (ctrl == null) return;
    _currentPageType = EvaluationPageType.loading;
    _lastProbe = null;
    _lastFillResult = null;
    onPageTypeChanged?.call(_currentPageType);
    await ctrl.reload();
  }

  Future<void> goToIndex() async {
    _lastHttpError = null;
    final ctrl = _webViewController;
    if (ctrl == null) return;
    _currentPageType = EvaluationPageType.loading;
    _lastProbe = null;
    _lastFillResult = null;
    onPageTypeChanged?.call(_currentPageType);
    await ctrl.loadUrl(
      urlRequest: URLRequest(url: WebUri(EvaluationUrls.evaluationIndex)),
    );
  }

  /// Notify controller of an HTTP error from the WebView layer.
  void onHttpError(int? statusCode) {
    _lastHttpError = statusCode != null ? 'HTTP $statusCode' : null;
  }

  /// Clear cookies for教务-related domains using per-cookie domain/path.
  Future<void> clearCookies() async {
    final manager = CookieManager.instance();
    await manager.deleteAllCookies();

    try {
      final webStorageManager = WebStorageManager.instance();
      await webStorageManager.deleteAllData();
    } catch (_) {}

    if (kDebugMode) {
      debugPrint('[Evaluation] Cleared all cookies and web storage');
    }
  }

  /// Build sanitized diagnostic message.
  String buildDiagnosticMessage() {
    final buf = StringBuffer();
    buf.writeln('页面类型: ${EvaluationPageDetector.label(_currentPageType)}');
    if (_lastHttpError != null) {
      buf.writeln('HTTP 错误: $_lastHttpError');
    }
    if (_lastProbe != null) {
      final probe = _lastProbe!;
      buf.writeln('URL: ${probe.url}');
      buf.writeln('标题: ${probe.title}');
      buf.writeln(
        '单选项: ${probe.radioCount} (${probe.radioGroups.length} 组)',
      );
      if (probe.scoreInputs.isNotEmpty) {
        final reliableScores = probe.scoreInputs.where((i) => i.isReliableScore).toList();
        buf.writeln('  [Score] Count: ${probe.scoreInputs.length}, Reliable: ${reliableScores.length}');
        for (int i = 0; i < probe.scoreInputs.length; i++) {
          final inp = probe.scoreInputs[i];
          final skipMsg = inp.skipReason != null ? ', skip=${inp.skipReason}' : '';
          final rangeMsg = inp.minScore != null ? ', range=${inp.minScore}..${inp.maxScore}' : '';
          final phMsg = (inp.placeholder?.isNotEmpty == true) ? ', ph="${inp.placeholder}"' : '';
          buf.writeln('    #${i + 1}: type=${inp.type}$phMsg$rangeMsg$skipMsg');
        }
      }
      buf.writeln('建议文本框: ${probe.optionalCommentCount}');
      buf.writeln('表单数: ${probe.forms.length}');
      buf.writeln('按钮数: ${probe.buttons.length}');
      if (probe.hasAccessDeniedText) {
        buf.writeln('命中访问受限规则: HTML标题或错误容器包含无权限');
      }
    }
    if (_lastFillResult != null) {
      buf.writeln('---');
      buf.writeln(
        '填写结果: 单选 ${_lastFillResult!.radioCompletedGroups}/${_lastFillResult!.radioTotalGroups}, '
        '评分输入框 ${_lastFillResult!.scoreInputCompletedCount}/${_lastFillResult!.scoreInputCount}',
      );
      if (_lastFillResult!.hasUnresolved) {
        buf.writeln(
          '未识别项: 单选 ${_lastFillResult!.unresolvedRadioGroups.length}, '
          '评分输入框 ${_lastFillResult!.unresolvedScoreInputs.length}',
        );
      }
    }
    return buf.toString();
  }

  bool shouldAllowNavigation(WebUri? uri) {
    if (uri == null) return false;
    final scheme = uri.scheme;
    // Allow only http/https in WebView; other schemes go to system
    if (scheme != 'http' && scheme != 'https') return false;
    final host = uri.host;
    if (host.isEmpty) return false;
    return EvaluationDomainAllowlist.isAllowed(host);
  }

  /// Returns true if this uri should be opened in system browser.
  bool shouldOpenExternally(WebUri? uri) {
    if (uri == null) return false;
    final scheme = uri.scheme;
    // Non http/https schemes (tel:, mailto:, intent:, etc.)
    if (scheme != 'http' && scheme != 'https') return true;
    // Http(s) but not in allowlist
    return !EvaluationDomainAllowlist.isAllowed(uri.host);
  }

  void dispose() {
    _disposed = true;
    _webViewController = null;
    onPageTypeChanged = null;
    onFillCompleted = null;
    onError = null;
  }

  // ── Private ──

  EvaluationProbeResult _emptyProbe(String error) => EvaluationProbeResult(
    url: '',
    title: '',
    pageTextSample: '',
    radioCount: 0,
    radioOptions: [],
    textareaCount: 0,
    forms: [],
    buttons: [],
    possibleCourseRows: [],
    hasLoginForm: false,
    hasEvaluationForm: false,
    error: error,
  );

  EvaluationProbeResult _parseProbeResult(dynamic raw) {
    if (raw == null) return _emptyProbe('Probe returned null');
    if (raw is String) {
      try {
        return EvaluationProbeResult.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (e) {
        return _emptyProbe('JSON parse error: $e');
      }
    }
    if (raw is Map) {
      return EvaluationProbeResult.fromJson(Map<String, dynamic>.from(raw));
    }
    return _emptyProbe('Unexpected probe type: ${raw.runtimeType}');
  }

  EvaluationFillResult _parseFillResult(dynamic raw) {
    if (raw == null) return EvaluationFillResult.error('Fill returned null');
    if (raw is String) {
      try {
        return EvaluationFillResult.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (e) {
        return EvaluationFillResult.error('Fill JSON parse error: $e');
      }
    }
    if (raw is Map) {
      return EvaluationFillResult.fromJson(Map<String, dynamic>.from(raw));
    }
    return EvaluationFillResult.error(
      'Unexpected fill type: ${raw.runtimeType}',
    );
  }
}
