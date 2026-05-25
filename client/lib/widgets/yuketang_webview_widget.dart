import 'dart:convert';
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
  State<YuketangWebViewWidget> createState() => _YuketangWebViewWidgetState();
}

class _YuketangWebViewWidgetState extends State<YuketangWebViewWidget> {
  InAppWebViewController? webViewController;
  final ScriptService _scriptService = ScriptService();
  final AnswerGateway _answerGateway = AnswerGateway();

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        webViewController = controller;

        // 注册通信桥梁 YuketangHelper
        controller.addJavaScriptHandler(
          handlerName: 'YuketangHelper',
          callback: (args) async {
            if (args.isNotEmpty) {
              final String jsonString = args[0] as String;
              try {
                final Map<String, dynamic> data = jsonDecode(jsonString);
                
                // 为了防止频繁调用，可在 Gateway 中做 debounce 保护，或者 UI 弹窗
                _showThinkingDialog();
                
                // 提交给智能网关处理
                final answer = await _answerGateway.processQuestion(data);
                
                if (mounted) {
                  Navigator.of(context).pop(); // 关闭 thinking dialog
                  
                  if (answer != null && !answer.startsWith('错误:') && !answer.startsWith('请求后端失败')) {
                    // 执行 JS 注入答案并根据模式自动点击或提示
                    await _answerGateway.executeAnswer(controller, answer);
                  } else {
                    _showAnswerDialog(answer); // 如果失败，展示弹窗提示错误
                  }
                }
              } catch (e) {
                debugPrint('解析拦截数据失败: $e');
              }
            }
          },
        );
      },
      onLoadStop: (controller, url) async {
        // 加载停止时，强制注入拦截脚本
        final scriptStr = await _scriptService.getInjectScript();
        if (scriptStr != null && scriptStr.isNotEmpty) {
          await controller.evaluateJavascript(source: scriptStr);
          debugPrint('注入脚本执行成功');
        } else {
          debugPrint('未能获取到注入脚本，未注入');
        }
      },
    );
  }

  void _showThinkingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('AI 正在思考...'),
            ],
          ),
        );
      },
    );
  }

  void _showAnswerDialog(String? answer) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('AI 提示'),
          content: Text(
            answer != null && answer.isNotEmpty 
                ? answer 
                : '未能获取到答案，或处理失败',
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('我知道了'),
            )
          ],
        );
      },
    );
  }
}
