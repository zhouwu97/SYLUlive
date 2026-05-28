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

  // 悬浮控制台状态
  bool _isIntercepted = false;
  String _statusText = '等待试卷数据...';
  String _answerText = '等待操作...';
  bool _isMin = false;
  Offset _dashboardPos = const Offset(0, 40); // 默认位置
  final TextEditingController _rangeCtrl = TextEditingController();
  String? _lastUploadRange;

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

    return Stack(
      children: [
        InAppWebView(
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

        // 拦截成功通知信道
        controller.addJavaScriptHandler(
          handlerName: 'YuketangIntercepted',
          callback: (args) {
            if (mounted) {
              setState(() {
                _isIntercepted = true;
                _statusText = '🎯 拦截成功！请设置范围并上传';
              });
            }
          }
        );

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
      },
      onLoadStop: (controller, url) async {
        debugPrint('页面加载完成: $url');
      },
    ),
    
    // 原生悬浮控制台
    Positioned(
      left: _dashboardPos.dx,
      top: _dashboardPos.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _dashboardPos += details.delta;
            // 简单边界限制
            if (_dashboardPos.dx < 0) _dashboardPos = Offset(0, _dashboardPos.dy);
            if (_dashboardPos.dy < 0) _dashboardPos = Offset(_dashboardPos.dx, 0);
            final double maxX = MediaQuery.of(context).size.width - 200;
            final double maxY = MediaQuery.of(context).size.height - 100;
            if (_dashboardPos.dx > maxX) _dashboardPos = Offset(maxX, _dashboardPos.dy);
            if (_dashboardPos.dy > maxY) _dashboardPos = Offset(_dashboardPos.dx, maxY);
          });
        },
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(20, 20, 25, 0.95),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 20,
                offset: Offset(0, 10),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽栏
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.1))),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('🤖 AI 外挂控制台', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 14)),
                    GestureDetector(
                      onTap: () => setState(() => _isMin = !_isMin),
                      child: Text(_isMin ? '展开 ⬜' : '最小化 _', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    )
                  ],
                ),
              ),
              if (!_isMin)
                Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('状态: $_statusText', style: const TextStyle(color: Colors.blueAccent, fontSize: 12)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _rangeCtrl,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: '范围如 1-10, 留空全做',
                                hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                                filled: true,
                                fillColor: Colors.black45,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(color: Colors.grey),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(color: Colors.green),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                            onPressed: _handleUpload,
                            child: const Text('上传获取', style: TextStyle(fontWeight: FontWeight.bold)),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        width: double.infinity,
                        child: SingleChildScrollView(
                          child: Text(_answerText, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6)),
                        ),
                      )
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  ],
);
  }

  Future<void> _handleUpload() async {
    if (!_isIntercepted) {
      setState(() => _statusText = '错误 - 未拦截到试卷数据！');
      return;
    }
    
    final rangeStr = _rangeCtrl.text.trim();
    if (_lastUploadRange != null && _lastUploadRange == rangeStr) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('提示'),
          content: const Text('您刚才已经上传过相同的范围了，确定要重新让 AI 做一遍吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
          ],
        ),
      );
      if (confirm != true) return;
    }
    _lastUploadRange = rangeStr;

    setState(() {
      _statusText = '正在智能裁剪数据并处理...';
      _answerText = '🚀 AI 正在深度思考中，请稍候...';
    });

    try {
      final result = await webViewController?.evaluateJavascript(source: "window.AiHelper && window.AiHelper.sliceExamData('$rangeStr');");
      if (result == null || result == 'null') {
        setState(() => _statusText = '错误：无法获取裁剪后的试卷数据');
        return;
      }
      
      final String jsonString = result as String;
      final Map<String, dynamic> data = jsonDecode(jsonString);
      
      final answer = await _answerGateway.processQuestion(
        data,
        onProgress: (status) {
          if (mounted) setState(() => _statusText = status);
        },
      );
      
      if (mounted) {
        if (answer != null && !answer.startsWith('错误:') && !answer.startsWith('请求后端失败')) {
          setState(() {
            _statusText = '✅ 答案已就绪！';
            _answerText = answer;
          });
          final safeAnswer = answer.replaceAll("'", "\\'").replaceAll("\n", "\\n");
          await webViewController?.evaluateJavascript(source: "window.AiHelper && window.AiHelper.doAutoAnswer('$safeAnswer', 'full');");
        } else {
          setState(() {
            _statusText = '错误';
            _answerText = answer ?? '未知错误';
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _statusText = '执行失败: $e');
    }
  }


}
