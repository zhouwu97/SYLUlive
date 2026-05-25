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

  /// 处理题目数据
  Future<String?> processQuestion(Map<String, dynamic> questionData) async {
    try {
      final customKey = await _secureStorage.read(key: _customApiKeyStorageKey);

      // 提取题干信息用于 AI 计算 (这里假设通过解析 questionData 拿到文本)
      // 实际情况下需要根据雨课堂具体返回的 JSON 结构进行解析
      final questionType = questionData['type']?.toString() ?? '未知题型';
      final contentText = questionData['content']?.toString() ?? questionData.toString();

      if (customKey != null && customKey.isNotEmpty) {
        debugPrint('发现自定义 API Key，采用分支 A：本地直连大模型');
        return await _askAiDirectly(customKey, questionType, contentText);
      } else {
        debugPrint('未配置自定义 API Key，采用分支 B：请求 Go 后端扣费');
        return await _askBackend(questionType, questionData, contentText);
      }
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
  Future<String?> _askAiDirectly(String apiKey, String qType, String content) async {
    final prompt = '你是一个专业的大学辅助答题助手。\n请直接输出正确选项的字母或简短答案，不要任何解析。\n题型：$qType\n题目内容：$content';
    
    try {
      final response = await _dio.post(
        'https://api.deepseek.com/v1/chat/completions',
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': 'deepseek-chat',
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
  Future<String?> _askBackend(String qType, Map<String, dynamic> rawContent, String contentText) async {
    final token = await _secureStorage.read(key: StorageKeys.authToken);
    if (token == null || token.isEmpty) {
      return '未登录，无法使用积分池';
    }

    try {
      final response = await _dio.post(
        '${ApiConstants.baseUrl}/question/solve',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'question_type': qType,
          'raw_content': rawContent,
          'content_text': contentText,
        },
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        return response.data['answer']?.toString();
      } else {
        return response.data['error']?.toString() ?? '未知错误';
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        return '积分不足，请充值或配置自定义 Key';
      }
      if (e.response?.data != null && e.response?.data['error'] != null) {
        return e.response?.data['error'].toString();
      }
      return '请求后端失败: ${e.message}';
    } catch (e) {
      return '系统错误: $e';
    }
  }
}
