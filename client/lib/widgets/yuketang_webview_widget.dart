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
  
  // 新的按块/单题模式状态
  bool _isLoadingTotal = false;
  int _totalQuestions = 0;
  bool _isBlockMode = true;
  String? _selectedBlock;
  int? _selectedSingle;

  // 防重发与防刷分拦截记忆
  final Set<int> _uploadedIndices = {};
  bool _uploadedAll = false;
  DateTime? _lastUploadTime;

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
                _statusText = '🎯 拦截成功！正在分析试卷...';
                _isLoadingTotal = true;
              });
              _fetchTotalQuestions(controller);
            }
          }
        );

        // 直播课实时发题通知信道
        controller.addJavaScriptHandler(
          handlerName: 'YuketangLiveProblem',
          callback: (args) {
            if (mounted && args.isNotEmpty) {
              String probId = args[0].toString();
              setState(() {
                _isIntercepted = true;
                _isBlockMode = false; // 强行切到单题模式
                _statusText = '🚨 老师刚发布了一道直播题！';
                
                // 如果 _totalQuestions == 0，可能需要重新计算一遍
                if (_totalQuestions == 0) {
                  _isLoadingTotal = true;
                  _fetchTotalQuestions(controller);
                } else {
                  // 这里我们粗略地认为最新的一题是最后一题，或者只是提示用户。
                  // 最完美的是前端根据 probId 去选择对应的序号，但现在我们就提示用户手动点上传。
                  _selectedSingle = _totalQuestions; 
                }
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
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: _isLoadingTotal
                                  ? const SizedBox(
                                      height: 40,
                                      child: Row(
                                        children: [
                                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent)),
                                          SizedBox(width: 8),
                                          Text('正在分析试卷结构...', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                        ],
                                      ),
                                    )
                                  : _totalQuestions == 0
                                      ? const SizedBox(height: 40, child: Align(alignment: Alignment.centerLeft, child: Text('未能获取到题目', style: TextStyle(color: Colors.red))))
                                      : SizedBox(
                                          height: 40,
                                          child: Row(
                                            children: [
                                              // 模式切换
                                              ToggleButtons(
                                                constraints: const BoxConstraints(minHeight: 36, minWidth: 40),
                                                isSelected: [_isBlockMode, !_isBlockMode],
                                                onPressed: (idx) => setState(() => _isBlockMode = idx == 0),
                                                borderRadius: BorderRadius.circular(6),
                                                selectedColor: Colors.white,
                                                color: Colors.white54, // 修复“单题”文字不可见问题
                                                borderColor: Colors.grey.withOpacity(0.3),
                                                selectedBorderColor: Colors.blueAccent,
                                                fillColor: Colors.blueAccent.withOpacity(0.5),
                                                children: const [
                                                  Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('5题连抽', style: TextStyle(fontSize: 12))),
                                                  Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('单题', style: TextStyle(fontSize: 12))),
                                                ],
                                              ),
                                              const SizedBox(width: 8),
                                              // 下拉选择
                                              Expanded(
                                                child: Container(
                                                  height: 36,
                                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black45,
                                                    borderRadius: BorderRadius.circular(6),
                                                    border: Border.all(color: Colors.grey.withOpacity(0.5)),
                                                  ),
                                                  child: DropdownButtonHideUnderline(
                                                    child: _isBlockMode
                                                        ? DropdownButton<String>(
                                                            value: _selectedBlock,
                                                            isExpanded: true,
                                                            dropdownColor: Colors.grey[850],
                                                            style: const TextStyle(color: Colors.white, fontSize: 13),
                                                            onChanged: (val) => setState(() => _selectedBlock = val),
                                                            items: _generateBlocks(_totalQuestions).map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(),
                                                          )
                                                        : DropdownButton<int>(
                                                            value: _selectedSingle,
                                                            isExpanded: true,
                                                            dropdownColor: Colors.grey[850],
                                                            style: const TextStyle(color: Colors.white, fontSize: 13),
                                                            onChanged: (val) => setState(() => _selectedSingle = val),
                                                            items: List.generate(_totalQuestions, (i) => i + 1).map((n) => DropdownMenuItem(value: n, child: Text('第 $n 题'))).toList(),
                                                          ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              minimumSize: const Size(60, 40),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                            onPressed: _isLoadingTotal || _totalQuestions == 0 ? null : _handleUpload,
                            child: const Text('上传', style: TextStyle(fontWeight: FontWeight.bold)),
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

  List<String> _generateBlocks(int total) {
    List<String> blocks = [];
    for (int i = 1; i <= total; i += 5) {
      int end = i + 4;
      if (end > total) end = total;
      if (i == end) {
        blocks.add("$i");
      } else {
        blocks.add("$i-$end");
      }
    }
    return blocks;
  }

  Future<void> _fetchTotalQuestions(InAppWebViewController controller) async {
    try {
      final res = await controller.evaluateJavascript(source: "window.AiHelper ? window.AiHelper.getTotalQuestions() : 0;");
      int total = 0;
      if (res is int) total = res;
      if (res is String) total = int.tryParse(res) ?? 0;
      
      if (mounted) {
        setState(() {
          _totalQuestions = total;
          _isLoadingTotal = false;
          _statusText = '🎯 拦截成功！共检测到 $total 道题';
          
          if (total > 0) {
            _selectedBlock = _generateBlocks(total).first;
            _selectedSingle = 1;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingTotal = false;
          _statusText = '⚠️ 分析失败，请重试';
        });
      }
    }
  }

  Set<int> _parseRange(String str) {
    Set<int> indices = {};
    if (str.trim().isEmpty) return indices;
    
    final parts = str.split(RegExp(r'[,，\s]+'));
    for (var part in parts) {
      if (part.isEmpty) continue;
      if (part.contains('-') || part.contains('~')) {
        final bounds = part.split(RegExp(r'[-~]'));
        if (bounds.length == 2) {
          final start = int.tryParse(bounds[0]);
          final end = int.tryParse(bounds[1]);
          if (start != null && end != null) {
            final min = start < end ? start : end;
            final max = start > end ? start : end;
            for (var i = min; i <= max; i++) {
              indices.add(i);
            }
          }
        }
      } else {
        final num = int.tryParse(part);
        if (num != null) indices.add(num);
      }
    }
    return indices;
  }

  Future<void> _handleUpload() async {
    if (!_isIntercepted) {
      setState(() => _statusText = '错误 - 未拦截到试卷数据！');
      return;
    }
    
    final now = DateTime.now();
    // 如果距离上次上传超过 30 分钟，自动清空记忆（防止换号被拦截）
    if (_lastUploadTime != null && now.difference(_lastUploadTime!).inMinutes >= 30) {
      _uploadedIndices.clear();
      _uploadedAll = false;
    }
    
    String rangeStr = _isBlockMode ? (_selectedBlock ?? '') : (_selectedSingle?.toString() ?? '');
    if (rangeStr.isEmpty) return;
    
    final requestedIndices = _parseRange(rangeStr);
    
    bool isDuplicate = false;
    if (rangeStr.isEmpty) {
      if (_uploadedAll) isDuplicate = true;
    } else if (requestedIndices.isNotEmpty) {
      // 只有当请求的所有题号都在已处理集合中时，才算作重复请求
      isDuplicate = requestedIndices.every((idx) => _uploadedIndices.contains(idx));
    }
    
    if (isDuplicate) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('提示'),
          content: const Text('您当前请求的题目范围刚刚已经处理过了。\n确定要重新让 AI 做一遍吗？（会重复消耗积分）'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
          ],
        ),
      );
      if (confirm != true) return;
    }
    
    // 记录本次请求的范围和时间
    _lastUploadTime = now;
    if (rangeStr.isEmpty) {
      _uploadedAll = true;
    } else {
      _uploadedIndices.addAll(requestedIndices);
    }

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
      final dynamic decoded = jsonDecode(jsonString);
      
      Map<String, dynamic> data;
      if (decoded is List) {
        data = {
          'type': '批量题目',
          'content': jsonString,
        };
      } else if (decoded is Map) {
        data = Map<String, dynamic>.from(decoded);
      } else {
        data = {'type': '未知', 'content': jsonString};
      }
      
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
