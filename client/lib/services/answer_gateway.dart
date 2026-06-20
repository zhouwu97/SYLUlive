import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../config/api_constants.dart';

class AnswerGatewayResult {
  final bool ok;
  final String answer;
  final String message;
  final String source;
  final bool usesOfficialBackend;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int cacheReferenceTokens;
  final int billedAmountCents;
  final int reservedAmountCents;
  final int balanceAfterCents;

  const AnswerGatewayResult({
    required this.ok,
    required this.answer,
    required this.message,
    required this.source,
    required this.usesOfficialBackend,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.cacheReferenceTokens,
    required this.billedAmountCents,
    required this.reservedAmountCents,
    required this.balanceAfterCents,
  });

  factory AnswerGatewayResult.error(String message,
      {required bool usesOfficialBackend}) {
    return AnswerGatewayResult(
      ok: false,
      answer: '',
      message: message,
      source: 'error',
      usesOfficialBackend: usesOfficialBackend,
      promptTokens: 0,
      completionTokens: 0,
      totalTokens: 0,
      cacheReferenceTokens: 0,
      billedAmountCents: 0,
      reservedAmountCents: 0,
      balanceAfterCents: 0,
    );
  }

  bool get isCacheHit => source == 'cache';

  String get summaryText {
    if (!ok) return message;
    final tokenText = isCacheHit && cacheReferenceTokens > 0
        ? '本次 0 tokens / 历史 $cacheReferenceTokens tokens'
        : '$totalTokens tokens';
    final costText = billedAmountCents > 0
        ? '¥${(billedAmountCents / 100).toStringAsFixed(2)}'
        : '¥0.00';
    if (!usesOfficialBackend) {
      return '✅ AI 答案已就绪 · $tokenText';
    }
    return '✅ AI 答案已就绪 · $tokenText · $costText';
  }
}

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
      answer = answer.substring(0, startIdx) +
          answer.substring(endIdx + '</think>'.length);
    }
    return answer.trim();
  }

  Future<AnswerGatewayResult> processQuestion(
    Map<String, dynamic> questionData, {
    void Function(String)? onProgress,
    bool forceRefresh = false,
    bool saveToCache = true,
  }) async {
    try {
      final customProvider =
          await _secureStorage.read(key: 'custom_ai_provider') ?? 'default';
      final customKey = await _secureStorage.read(key: _customApiKeyStorageKey);
      final useOfficialBackend =
          customProvider == 'default' || customKey == null || customKey.isEmpty;

      onProgress?.call('正在解析雨课堂题目结构...');
      String questionType = questionData['type']?.toString() ?? '未知题型';
      final contentText =
          questionData['content']?.toString() ?? questionData.toString();

      AnswerGatewayResult result;
      if (!useOfficialBackend) {
        debugPrint('发现自定义 API Key，采用分支 A：本地直连大模型');
        onProgress?.call('AI答题中...');
        result = await _askAiDirectly(
            customKey, questionType, contentText, onProgress);
      } else {
        debugPrint('未配置自定义 API Key，采用分支 B：请求 Go 后端余额扣费');
        onProgress?.call(forceRefresh ? '正在重新发起 AI 作答...' : 'AI答题中...');
        result = await _askBackend(
          questionType,
          questionData,
          contentText,
          onProgress,
          forceRefresh: forceRefresh,
          saveToCache: saveToCache,
        );
      }

      if (!result.ok) {
        return result;
      }

      return AnswerGatewayResult(
        ok: true,
        answer: _cleanAiAnswer(result.answer),
        message: result.message,
        source: result.source,
        usesOfficialBackend: result.usesOfficialBackend,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        totalTokens: result.totalTokens,
        cacheReferenceTokens: result.cacheReferenceTokens,
        billedAmountCents: result.billedAmountCents,
        reservedAmountCents: result.reservedAmountCents,
        balanceAfterCents: result.balanceAfterCents,
      );
    } catch (e) {
      debugPrint('网关处理失败: $e');
      return AnswerGatewayResult.error('错误: $e', usesOfficialBackend: false);
    }
  }

  Future<void> executeAnswer(
      InAppWebViewController controller, String aiAnswer) async {
    String autoMode =
        await _secureStorage.read(key: 'auto_submit_mode') ?? 'semi';
    String safeAnswer = jsonEncode(aiAnswer);
    String jsCommand =
        "if(window.doAutoAnswer) window.doAutoAnswer($safeAnswer, '$autoMode');";
    await controller.evaluateJavascript(source: jsCommand);
  }

  Future<String?> markQuestionWrong(
      String qType, Map<String, dynamic> rawContent, String contentText) async {
    final token = await _secureStorage.read(key: StorageKeys.authToken);
    if (token == null || token.isEmpty) {
      return '未登录，无法标记错题';
    }

    try {
      final rootUrl = ApiConstants.apiRootFromBaseUrl(ApiConstants.baseUrl);
      final endpoint = '$rootUrl/api/v1/question/mark_wrong';
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
          'raw_content': rawContent,
          'content_text': contentText,
        },
      );
      if (response.statusCode == 200) {
        return response.data['message']?.toString() ?? '已标记错题';
      }
      return '标记错题失败';
    } on DioException catch (e) {
      if (e.response?.data is Map && e.response?.data['error'] != null) {
        return e.response!.data['error'].toString();
      }
      return '标记错题失败: ${e.message}';
    } catch (e) {
      return '标记错题失败: $e';
    }
  }

  Future<String?> confirmCachedAnswer(
    String qType,
    Map<String, dynamic> rawContent,
    String contentText,
    String answer,
  ) async {
    final token = await _secureStorage.read(key: StorageKeys.authToken);
    if (token == null || token.isEmpty) {
      return '未登录，无法写入缓存';
    }

    try {
      final rootUrl = ApiConstants.apiRootFromBaseUrl(ApiConstants.baseUrl);
      final endpoint = '$rootUrl/api/v1/question/confirm_cache';
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
          'raw_content': rawContent,
          'content_text': contentText,
          'answer': answer,
        },
      );
      if (response.statusCode == 200) {
        return response.data['message']?.toString() ?? '已写入缓存';
      }
      return '写入缓存失败';
    } on DioException catch (e) {
      if (e.response?.data is Map && e.response?.data['error'] != null) {
        return e.response!.data['error'].toString();
      }
      return '写入缓存失败: ${e.message}';
    } catch (e) {
      return '写入缓存失败: $e';
    }
  }

  Future<AnswerGatewayResult> _askAiDirectly(
    String apiKey,
    String qType,
    String content,
    void Function(String)? onProgress,
  ) async {
    final prompt =
        '你是一个专业的大学辅助答题助手。\n【重点警告】如果是选择题，请输出正确选项的字母和【完整文字内容】。如果选项是纯图片，或者你无法用文字描述，请务必输出对应选项的字母（如 A、B、C、D）。\n【关键：题号匹配】我传给你的题目 JSON 中可能带有一个 `__originalIndex` 字段。在输出多道题的答案时，你的编号必须严格等于该题目的 `__originalIndex` 的值（例如："17. A 选项文字"，"18. B"），绝对不能自己从 1 开始顺延编号！绝对不要包含任何解析或废话。\n题型：$qType\n题目内容：$content';

    final baseUrl = await _secureStorage.read(key: 'custom_base_url') ??
        'https://api.deepseek.com/v1';
    final modelName =
        await _secureStorage.read(key: 'custom_model_name') ?? 'deepseek-chat';
    final endpoint = baseUrl.endsWith('/')
        ? '${baseUrl}chat/completions'
        : '$baseUrl/chat/completions';

    final imageRegex = RegExp(
        r'<img[^>]+(?:src|data-src)=\\?["\u0027](https?://[^"\u0027\\]+)\\?["\u0027]');
    final matches1 = imageRegex.allMatches(content);
    final directUrlRegex = RegExp(
        r'https?://[^"\u0027\\]+(?:storage\.yuketang\.cn|qn-storage)[^"\u0027\\]+|https?://[^"\u0027\\]+\.(?:png|jpg|jpeg|webp|gif|bmp)(?:\?[^"\u0027\\]*)?');
    final matches2 = directUrlRegex.allMatches(content);

    final Set<String> urlSet = {};
    for (final match in matches1) {
      if (match.groupCount >= 1 && match.group(1) != null) {
        urlSet.add(match.group(1)!);
      }
    }
    for (final match in matches2) {
      var url = match.group(0)!;
      url = url.replaceAll(RegExp(r'[\\.,;"]+$'), '');
      urlSet.add(url);
    }

    dynamic messagesContent;
    if (urlSet.isNotEmpty) {
      final List<Map<String, dynamic>> contentArray = [
        {'type': 'text', 'text': prompt}
      ];
      for (final url in urlSet) {
        contentArray.add({
          'type': 'image_url',
          'image_url': {'url': url}
        });
      }
      messagesContent = contentArray;
    } else {
      messagesContent = prompt;
    }

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
            {'role': 'user', 'content': messagesContent}
          ],
          'temperature': 0.1,
        },
      );

      if (response.statusCode == 200) {
        final choices = response.data['choices'] as List? ?? const [];
        if (choices.isNotEmpty) {
          final usage = response.data['usage'] as Map? ?? const {};
          return AnswerGatewayResult(
            ok: true,
            answer: choices[0]['message']['content'].toString().trim(),
            message: '直连模型作答成功',
            source: 'direct',
            usesOfficialBackend: false,
            promptTokens: int.tryParse('${usage['prompt_tokens'] ?? 0}') ?? 0,
            completionTokens:
                int.tryParse('${usage['completion_tokens'] ?? 0}') ?? 0,
            totalTokens: int.tryParse('${usage['total_tokens'] ?? 0}') ?? 0,
            cacheReferenceTokens: 0,
            billedAmountCents: 0,
            reservedAmountCents: 0,
            balanceAfterCents: 0,
          );
        }
      }
      return AnswerGatewayResult.error('AI 响应格式异常', usesOfficialBackend: false);
    } catch (e) {
      return AnswerGatewayResult.error('直连 AI 失败: $e',
          usesOfficialBackend: false);
    }
  }

  Future<AnswerGatewayResult> _askBackend(
    String qType,
    Map<String, dynamic> rawContent,
    String contentText,
    void Function(String)? onProgress, {
    required bool forceRefresh,
    required bool saveToCache,
  }) async {
    final token = await _secureStorage.read(key: StorageKeys.authToken);
    if (token == null || token.isEmpty) {
      return AnswerGatewayResult.error('未登录，无法使用官方接口',
          usesOfficialBackend: true);
    }

    var payloadText = contentText;
    if (payloadText.length > 25000) {
      payloadText = '${payloadText.substring(0, 25000)}...[截断]';
    }

    int maxRetries = 5;
    int retryCount = 0;

    while (retryCount <= maxRetries) {
      try {
        if (retryCount > 0) {
          onProgress
              ?.call('题目较多，服务器 AI 仍在处理中，继续等待 ($retryCount/$maxRetries)...');
          await Future.delayed(const Duration(seconds: 2));
        } else {
          onProgress?.call(forceRefresh ? 'AI答题中（忽略旧缓存）...' : 'AI答题中...');
        }

        final rootUrl = ApiConstants.apiRootFromBaseUrl(ApiConstants.baseUrl);
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
            'raw_content': rawContent,
            'content_text': payloadText,
            'force_refresh': forceRefresh,
            'save_to_cache': saveToCache,
          },
        );

        if (response.statusCode == 200 &&
            response.data is Map &&
            response.data['success'] == true) {
          final usage = response.data['usage'] as Map? ?? const {};
          final billing = response.data['billing'] as Map? ?? const {};
          return AnswerGatewayResult(
            ok: true,
            answer: response.data['answer']?.toString() ?? '',
            message: '官方接口作答成功',
            source: response.data['source']?.toString() ?? 'ai',
            usesOfficialBackend: true,
            promptTokens: int.tryParse('${usage['prompt_tokens'] ?? 0}') ?? 0,
            completionTokens:
                int.tryParse('${usage['completion_tokens'] ?? 0}') ?? 0,
            totalTokens: int.tryParse('${usage['total_tokens'] ?? 0}') ?? 0,
            cacheReferenceTokens:
                int.tryParse('${usage['cache_reference_tokens'] ?? 0}') ?? 0,
            billedAmountCents:
                int.tryParse('${billing['billed_amount_cents'] ?? 0}') ?? 0,
            reservedAmountCents:
                int.tryParse('${billing['reserved_amount_cents'] ?? 0}') ?? 0,
            balanceAfterCents:
                int.tryParse('${billing['balance_after_cents'] ?? 0}') ?? 0,
          );
        }

        if (response.data is Map) {
          return AnswerGatewayResult.error(
            response.data['error']?.toString() ?? '未知错误',
            usesOfficialBackend: true,
          );
        }
        return AnswerGatewayResult.error('服务器返回异常: ${response.statusCode}',
            usesOfficialBackend: true);
      } on DioException catch (e) {
        final statusCode = e.response?.statusCode;
        if (statusCode == 504 || statusCode == 502 || statusCode == 524) {
          retryCount++;
          if (retryCount <= maxRetries) continue;
        }

        if (statusCode == 403) {
          return AnswerGatewayResult.error('余额不足，请充值或配置自定义 Key',
              usesOfficialBackend: true);
        }

        if (e.response?.data is Map && e.response!.data['error'] != null) {
          return AnswerGatewayResult.error(e.response!.data['error'].toString(),
              usesOfficialBackend: true);
        }
        return AnswerGatewayResult.error(
          '请求后端失败: ${e.message} (Status: $statusCode)',
          usesOfficialBackend: true,
        );
      } catch (e) {
        return AnswerGatewayResult.error('系统错误: $e', usesOfficialBackend: true);
      }
    }

    return AnswerGatewayResult.error('请求超时，请稍后再试', usesOfficialBackend: true);
  }
}
