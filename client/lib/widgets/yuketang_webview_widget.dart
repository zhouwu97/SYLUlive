import 'dart:convert';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/script_service.dart';
import '../services/answer_gateway.dart';

class YuketangWebViewWidget extends StatefulWidget {
  final String url;
  
  const YuketangWebViewWidget({
    Key? key,
    required this.url,
  }) : super(key: key);

  @override
  State<YuketangWebViewWidget> createState() => YuketangWebViewWidgetState();
}

class YuketangWebViewWidgetState extends State<YuketangWebViewWidget> {
  InAppWebViewController? webViewController;
  final ScriptService _scriptService = ScriptService();
  final AnswerGateway _answerGateway = AnswerGateway();
  String? _lastInterceptedExamData;
  String? _injectScript;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initScript();
  }

  Future<void> _initScript() async {
    _injectScript = await _scriptService.getInjectScript();
    if (mounted) {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }

    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      ),
      initialUserScripts: _injectScript != null && _injectScript!.isNotEmpty
          ? UnmodifiableListView<UserScript>([
              UserScript(
                source: _injectScript!,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
            ])
          : null,
      onWebViewCreated: (controller) {
        webViewController = controller;

        // 注册全量快照备份信道
        controller.addJavaScriptHandler(
          handlerName: 'YuketangBackup',
          callback: (args) async {
            if (args.isNotEmpty) {
              // 内存暂存
              _lastInterceptedExamData = args[0] as String;
              debugPrint('已在本地建立全量试卷快照备用');
            }
          }
        );

        // 注册手动上传信道
        controller.addJavaScriptHandler(
          handlerName: 'YuketangManualUpload',
          callback: (args) async {
            if (args.isNotEmpty) {
              final String jsonString = args[0] as String;
              try {
                final Map<String, dynamic> data = jsonDecode(jsonString);
                
                await controller.evaluateJavascript(source: "window.updateAiStatus && window.updateAiStatus('已接收到请求，开始处理...');");
                
                final answer = await _answerGateway.processQuestion(
                  data,
                  onProgress: (status) async {
                    if (mounted) {
                      final safeStatus = status.replaceAll("'", "\\'").replaceAll("\n", " ");
                      await controller.evaluateJavascript(source: "window.updateAiStatus && window.updateAiStatus('$safeStatus');");
                    }
                  },
                );
                
                if (mounted) {
                  if (answer != null && !answer.startsWith('错误:') && !answer.startsWith('请求后端失败')) {
                    await _answerGateway.executeAnswer(controller, answer);
                  } else {
                    final safeError = answer?.replaceAll("'", "\\'").replaceAll("\n", " ") ?? '未知错误';
                    await controller.evaluateJavascript(source: "window.updateAiStatus && window.updateAiStatus('错误: $safeError');");
                  }
                }
              } catch (e) {
                debugPrint('解析手动上传数据失败: $e');
              }
            }
          },
        );
      },
      onLoadStop: (controller, url) async {
        debugPrint('页面加载完成: $url');
      },
    );
  }


}
