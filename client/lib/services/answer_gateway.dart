import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../config/api_constants.dart';

/// 智能分流网关
/// 负责根据用户是否配置了自定义 API Key，将答题请求分流到本地直连或 Go 后端
class AnswerGateway {
  final Dio _dio = Dio();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _customApiKeyStorageKey = 'custom_api_key';

  String _cleanAiAnswer(String answer) {
    int startIdx = answer.indexOf('<think>');
    int endIdx = answer.indexOf('</think>');
    if (startIdx != -1 && endIdx != -1 && endIdx > startIdx) {
      answer = answer.substring(0, startIdx) + answer.substring(endIdx + '</think>'.length);
    }
    // 有时候 AI 可能会给出类似于 "答案是：D" 或 "选项: D" 的废话
    // 前端自动点击只做简单的 includes 匹配，所以只要保留核心内容即可
    return answer.trim();
  }

  /// 处理题目数据
  Future<String?> processQuestion(Map<String, dynamic> questionData, {void Function(String)? onProgress}) async {
    try {
      final customProvider = await _secureStorage.read(key: 'custom_ai_provider') ?? 'default';
      final customKey = await _secureStorage.read(key: _customApiKeyStorageKey);

      onProgress?.call('正在解析雨课堂题目结构...');
      final questionType = questionData['type']?.toString() ?? '未知题型';
      final contentText = questionData['content']?.toString() ?? questionData.toString();

      String? rawAnswer;
      if (customProvider != 'default' && customKey != null && customKey.isNotEmpty) {
        debugPrint('发现自定义 API Key，采用分支 A：本地直连大模型');
        onProgress?.call('正在连接本地配置的大模型进行推理...');
        rawAnswer = await _askAiDirectly(customKey, questionType, contentText, onProgress);
      } else {
        debugPrint('未配置自定义 API Key，采用分支 B：请求 Go 后端扣费');
        onProgress?.call('正在连接云端积分池大模型进行推理...');
        rawAnswer = await _askBackend(questionType, questionData, contentText, onProgress);
      }
      
      if (rawAnswer != null && !rawAnswer.startsWith('错误') && !rawAnswer.startsWith('请求后端失败') && !rawAnswer.startsWith('系统错误') && !rawAnswer.startsWith('请求超时')) {
        return _cleanAiAnswer(rawAnswer);
      }
      return rawAnswer;
    } catch (e) {
      debugPrint('网关处理失败: $e');
      return '错误: $e';
    }
  }

  // 接收从后端或 DeepSeek 拿到的最终答案
  Future<void> executeAnswer(InAppWebViewController controller, String aiAnswer) async {
    // 读取用户的模式偏好，默认 fallback 为半自动 'semi'
    String autoMode = await _secureStorage.read(key: 'auto_submit_mode') ?? 'semi';
    
    // 扣动扳机：将答案和模式注入给前端网页
    // 注意转义处理，防止答案内容含有引号等破坏 js 语法
    String escapedAnswer = aiAnswer.replaceAll("'", "\\'").replaceAll('\n', ' ');
    String jsCommand = "if(window.doAutoAnswer) window.doAutoAnswer('$escapedAnswer', '$autoMode');";
    
    await controller.evaluateJavascript(source: jsCommand);
  }

  /// 分支 A：用户自带 Key，本地直连大模型，不消耗积分
  Future<String?> _askAiDirectly(String apiKey, String qType, String content, void Function(String)? onProgress) async {
    final prompt = '你是一个专业的大学辅助答题助手。\n【重点警告】如果是选择题，千万不要只输出 ABCD 字母（因为题目字母顺序通常会随机打乱）！你必须直接输出正确选项的【完整文字内容】！多道题请标号输出文本。绝对不要包含任何解析或废话。\n题型：$qType\n题目内容：$content';
    
    final baseUrl = await _secureStorage.read(key: 'custom_base_url') ?? 'https://api.deepseek.com/v1';
    final modelName = await _secureStorage.read(key: 'custom_model_name') ?? 'deepseek-chat';
    
    final endpoint = baseUrl.endsWith('/') ? '${baseUrl}chat/completions' : '$baseUrl/chat/completions';

    try {
      onProgress?.call('已连接模型 $modelName，等待返回...');
      final response = await _dio.post(
        endpoint,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': modelName,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.1,
        },
      );

      if (response.statusCode == 200) {
        final choices = response.data['choices'] as List;
        if (choices.isNotEmpty) {
          return choices[0]['message']['content'].toString().trim();
        }
      }
      return 'AI 响应格式异常';
    } catch (e) {
      return '直连 AI 失败: $e';
    }
  }

  /// 分支 B：使用懒人积分池，请求 Go 后端
  Future<String?> _askBackend(String qType, Map<String, dynamic> rawContent, String contentText, void Function(String)? onProgress) async {
    final token = await _secureStorage.read(key: StorageKeys.authToken);
    if (token == null || token.isEmpty) {
      return '未登录，无法使用积分池';
    }

    if (contentText.length > 3000) {
      contentText = contentText.substring(0, 3000) + '...[截断]';
    }

    int maxRetries = 2;
    int retryCount = 0;

    while (retryCount <= maxRetries) {
      try {
        if (retryCount > 0) {
          onProgress?.call('服务器AI正在深度思考中，正在继续等待 ($retryCount/$maxRetries)...');
          await Future.delayed(const Duration(seconds: 2));
        } else {
          onProgress?.call('请求已发送到云端，等待AI回答...');
        }
        
        final rootUrl = ApiConstants.baseUrl.replaceAll('/api', '');
        final endpoint = '$rootUrl/api/v1/question/solve';
        
        final response = await _dio.post(
          endpoint,
          options: Options(
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          ),
          data: {
            'question_type': qType,
            'raw_content': rawContent.toString().length > 1000 ? {"msg": "too large"} : rawContent,
            'content_text': contentText,
          },
        );

        if (response.statusCode == 200 && response.data != null && response.data is Map && response.data['success'] == true) {
          return response.data['answer']?.toString();
        } else {
          if (response.data is Map) {
            return response.data['error']?.toString() ?? '未知错误';
          }
          return '服务器返回异常: ${response.statusCode}';
        }
      } on DioException catch (e) {
        final statusCode = e.response?.statusCode;
        // 如果是网关超时，说明后端AI还在转圈圈，我们重试去接结果
        if (statusCode == 504 || statusCode == 502 || statusCode == 524) {
          retryCount++;
          if (retryCount <= maxRetries) continue;
        }

        if (statusCode == 403) {
          return '积分不足，请充值或配置自定义 Key';
        }
        
        if (e.response?.data != null && e.response!.data is Map) {
          final errMap = e.response!.data as Map;
          if (errMap['error'] != null) {
            return errMap['error'].toString();
          }
        }
        return '请求后端失败: ${e.message} (Status: $statusCode)';
      } catch (e) {
        return '系统错误: $e';
      }
    }
    return '请求超时，请稍后再试';
  }
}
