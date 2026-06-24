/// Teaching Evaluation Assistant screen.
///
/// Opens the official教务 evaluation page in a WebView, detects the current
/// page type, and provides a "one-click fill" button on evaluation form pages.
/// The user must review selections and click the official submit button.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'evaluation_models.dart';
import 'evaluation_page_detector.dart';
import 'evaluation_webview_controller.dart';

/// Full-screen WebView page for the teaching evaluation assistant.
class EvaluationScreen extends StatefulWidget {
  const EvaluationScreen({super.key});

  @override
  State<EvaluationScreen> createState() => _EvaluationScreenState();
}

class _EvaluationScreenState extends State<EvaluationScreen> {
  final EvaluationWebViewController _evalCtrl = EvaluationWebViewController();

  bool _isPageLoading = true;
  double _loadingProgress = 0;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _evalCtrl.onPageTypeChanged = _onPageTypeChanged;
    _evalCtrl.onFillCompleted = _onFillCompleted;
    _evalCtrl.onError = _onError;
    _evalCtrl.goToIndex();
  }

  @override
  void dispose() {
    _evalCtrl.dispose();
    super.dispose();
  }

  // ── Callbacks ──

  void _onPageTypeChanged(EvaluationPageType type) {
    if (!mounted) return;
    setState(() {
      _statusMessage = EvaluationPageDetector.hint(type);
    });
  }

  void _onFillCompleted(EvaluationFillResult result) {
    if (!mounted) return;
    _showFillResultSheet(result);
  }

  void _onError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ── Actions ──

  Future<void> _handleRefresh() async {
    await _evalCtrl.reload();
    if (mounted) {
      setState(() {
        _isPageLoading = true;
        _loadingProgress = 0;
        _statusMessage = null;
      });
    }
  }

  Future<void> _handleGoToIndex() async {
    await _evalCtrl.goToIndex();
    if (mounted) {
      setState(() {
        _isPageLoading = true;
        _loadingProgress = 0;
        _statusMessage = null;
      });
    }
  }

  Future<void> _handleFill() async {
    if (_evalCtrl.currentPageType != EvaluationPageType.evaluationForm) {
      _onError('请先在网页中选择一门待评价课程。');
      return;
    }
    if (_evalCtrl.isFilling) return;

    // Confirm before fill
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('一键填写'),
        content: const Text(
          '将自动选择每项评价的最高分选项。\n\n'
          '填写完成后不会自动提交，'
          '你需要在官方页面中检查并手动点击提交。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始填写'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {}); // show loading on fill button
    await _evalCtrl.fill();
  }

  Future<void> _handleClearCookies() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除登录状态'),
        content: const Text(
          '将清除教务网站 (jxw.sylu.edu.cn) 的登录 Cookie。'
          '清除后需要重新登录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _evalCtrl.clearCookies();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清除教务登录状态')),
        );
        await _handleRefresh();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除失败: $e')),
        );
      }
    }
  }

  void _showDiagnostics() {
    final message = _evalCtrl.buildDiagnosticMessage();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bug_report_outlined, size: 20),
            SizedBox(width: 8),
            Text('页面诊断'),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            message,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制诊断信息')),
              );
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showFillResultSheet(EvaluationFillResult result) {
    if (!mounted) return;

    final hasError = result.error != null && result.error!.isNotEmpty;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      hasError
                          ? Icons.error_outline
                          : result.hasUnresolved
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_outline,
                      color: hasError
                          ? Colors.red
                          : result.hasUnresolved
                              ? Colors.orange
                              : Colors.green,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        hasError ? '填写异常' : '填写结果',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (hasError) ...[
                  Text(
                    result.error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ] else ...[
                  _resultRow('检测到的评价指标', '${result.totalGroups} 组'),
                  _resultRow('已填写', '${result.completedGroups} 组'),
                  if (result.alreadyCompletedGroups > 0)
                    _resultRow('先前已完成', '${result.alreadyCompletedGroups} 组'),
                  if (result.hasUnresolved)
                    _resultRow('无法识别', '${result.unresolvedGroups.length} 组'),
                  if (result.hasRequiredTextareas) ...[
                    const SizedBox(height: 8),
                    const Row(
                      children: [
                        Icon(Icons.edit_note, size: 18, color: Colors.orange),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '检测到文字评价，请检查并手动填写。',
                            style: TextStyle(color: Colors.orange),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (result.hasWarnings) ...[
                    const SizedBox(height: 12),
                    const Text(
                      '提示',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    ...result.warnings.take(3).map(
                          (w) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '• $w',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                        ),
                    if (result.warnings.length > 3)
                      Text(
                        '还有 ${result.warnings.length - 3} 条提示...',
                        style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                      ),
                  ],
                  // Success message
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 18, color: Colors.blue),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            result.hasUnresolved
                                ? '已填写 ${result.completedGroups} 项，另有 '
                                    '${result.unresolvedGroups.length} 项无法可靠判断，'
                                    '请手动完成。'
                                : '已自动填写 ${result.completedGroups}/${result.totalGroups} 项，'
                                    '请检查后在官方页面中提交。',
                            style: const TextStyle(
                              color: Colors.blue,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回检查'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[700])),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageType = _evalCtrl.currentPageType;
    final canFill =
        pageType == EvaluationPageType.evaluationForm && !_evalCtrl.isFilling;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: const Text('教学评价助手'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          // Refresh
          IconButton(
            onPressed: _evalCtrl.isFilling ? null : _handleRefresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新页面',
          ),
          // Go to evaluation index
          IconButton(
            onPressed: _evalCtrl.isFilling ? null : _handleGoToIndex,
            icon: const Icon(Icons.home_outlined),
            tooltip: '评价首页',
          ),
          // Fill button (only enabled on evaluation form)
          IconButton(
            onPressed: canFill ? _handleFill : null,
            icon: _evalCtrl.isFilling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.auto_fix_high,
                    color: canFill ? null : Colors.grey,
                  ),
            tooltip: '一键填写',
          ),
          // More menu
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'diagnostics':
                  _showDiagnostics();
                  break;
                case 'clear_cookies':
                  _handleClearCookies();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'diagnostics',
                child: Row(
                  children: [
                    Icon(Icons.bug_report_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('页面诊断'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear_cookies',
                child: Row(
                  children: [
                    Icon(Icons.cleaning_services_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('清除登录状态'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Info banner
          _buildInfoBanner(isDark),
          // Status chip
          if (_statusMessage != null) _buildStatusChip(pageType, isDark),
          // Loading progress
          if (_isPageLoading)
            LinearProgressIndicator(
              value: _loadingProgress > 0 && _loadingProgress < 1
                  ? _loadingProgress
                  : null,
              minHeight: 2,
            ),
          // WebView
          Expanded(child: _buildWebView()),
        ],
      ),
    );
  }

  Widget _buildInfoBanner(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: isDark
          ? Colors.blueGrey.withOpacity(0.15)
          : Colors.blue.withOpacity(0.06),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: isDark ? Colors.white60 : Colors.blueGrey),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '评价内容仅在本机自动填写，提交前请确认各项选择。',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(EvaluationPageType pageType, bool isDark) {
    final label = EvaluationPageDetector.label(pageType);
    final hint = _statusMessage ?? '';
    final color = _statusColor(pageType);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _statusColor(EvaluationPageType type) {
    switch (type) {
      case EvaluationPageType.evaluationForm:
        return Colors.green;
      case EvaluationPageType.login:
        return Colors.orange;
      case EvaluationPageType.courseList:
        return Colors.blue;
      case EvaluationPageType.submitted:
        return Colors.green;
      case EvaluationPageType.sessionExpired:
      case EvaluationPageType.accessDenied:
        return Colors.red;
      case EvaluationPageType.loading:
      case EvaluationPageType.unknown:
        return Colors.grey;
    }
  }

  Widget _buildWebView() {
    return InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        useWideViewPort: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        loadWithOverviewMode: true,
        userAgent:
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      ),
      onWebViewCreated: (controller) {
        _evalCtrl.attach(controller);
      },
      onLoadStart: (controller, url) {
        if (mounted) {
          setState(() {
            _isPageLoading = true;
            _loadingProgress = 0;
          });
        }
      },
      onProgressChanged: (controller, progress) {
        if (mounted) {
          setState(() {
            _loadingProgress = progress / 100.0;
          });
        }
      },
      onLoadStop: (controller, url) async {
        if (mounted) {
          setState(() {
            _isPageLoading = false;
            _loadingProgress = 1;
          });
        }
        // Auto-probe after page load
        await _evalCtrl.probePage();
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri == null) return NavigationActionPolicy.CANCEL;

        // Allow if domain is in whitelist
        if (_evalCtrl.shouldAllowNavigation(uri)) {
          return NavigationActionPolicy.ALLOW;
        }

        // Open disallowed URLs in system browser
        try {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {
          // Silently ignore launch failures for non-critical external URLs
        }
        return NavigationActionPolicy.CANCEL;
      },
      onReceivedError: (controller, request, error) {
        if (kDebugMode) {
          debugPrint('[Evaluation] WebView error: ${error.description}');
        }
        if (mounted) {
          setState(() {
            _isPageLoading = false;
            _statusMessage = '加载失败: ${error.description}';
          });
        }
      },
    );
  }
}
