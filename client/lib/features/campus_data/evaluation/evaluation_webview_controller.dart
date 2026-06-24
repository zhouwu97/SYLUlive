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
      _currentPageType = _detector.classify(_lastProbe!);

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
          '[Evaluation] fill: ${_lastFillResult!.completedGroups}/'
          '${_lastFillResult!.totalGroups} groups, '
          '${_lastFillResult!.unresolvedGroups.length} unresolved, '
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
    int deletedCount = 0;

    for (final origin in EvaluationUrls.cookieDomains) {
      try {
        final cookies = await manager.getCookies(url: WebUri(origin));
        for (final cookie in cookies) {
          try {
            await manager.deleteCookie(
              url: WebUri(origin),
              name: cookie.name,
              domain: cookie.domain,
              path: cookie.path,
            );
            deletedCount++;
          } catch (_) {
            // Individual cookie deletion failed — try without domain/path
            try {
              await manager.deleteCookie(
                url: WebUri(origin),
                name: cookie.name,
              );
              deletedCount++;
            } catch (_) {
              /* skip */
            }
          }
        }
      } catch (_) {
        /* domain may not have cookies */
      }
    }

    if (kDebugMode) {
      debugPrint('[Evaluation] Cleared $deletedCount cookies from教务 domains');
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
      buf.writeln('URL: ${_lastProbe!.url}');
      buf.writeln('标题: ${_lastProbe!.title}');
      buf.writeln(
        '单选项: ${_lastProbe!.radioCount} (${_lastProbe!.radioGroups.length} 组)',
      );
      buf.writeln('文本框: ${_lastProbe!.textareaCount}');
      buf.writeln('表单数: ${_lastProbe!.forms.length}');
      buf.writeln('按钮数: ${_lastProbe!.buttons.length}');
    }
    if (_lastFillResult != null) {
      buf.writeln('---');
      buf.writeln(
        '填写结果: ${_lastFillResult!.completedGroups}/${_lastFillResult!.totalGroups}',
      );
      if (_lastFillResult!.hasUnresolved) {
        buf.writeln('未识别组: ${_lastFillResult!.unresolvedGroups.length}');
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
