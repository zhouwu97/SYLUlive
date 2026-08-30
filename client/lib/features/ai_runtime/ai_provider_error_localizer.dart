/// 将第三方模型服务的错误转换为稳定、可操作的中文提示。
///
/// 服务商的错误文案和大小写并不统一，因此这里只匹配常见语义；无法识别的
/// 外文错误使用调用方提供的中文兜底，避免直接把英文内部错误暴露给用户。
String localizeAIProviderError({
  int? statusCode,
  String? rawMessage,
  String? errorCode,
  required String fallback,
}) {
  final message = rawMessage?.trim() ?? '';
  final searchable = '$errorCode $message'.toLowerCase();

  if (errorCode == 'ai_budget_exceeded') {
    return '当前 AI 服务额度已达到平台限制\n额度购买与计费功能暂未开发';
  }

  if (statusCode == 401 ||
      statusCode == 403 ||
      _containsAny(searchable, const <String>[
        'invalid api key',
        'invalid_api_key',
        'authentication',
        'unauthorized',
      ])) {
    return 'API Key 无效、已失效或没有该模型的访问权限';
  }
  if (statusCode == 402 ||
      _containsAny(searchable, const <String>[
        'insufficient balance',
        'insufficient_balance',
        'insufficient quota',
        'insufficient_quota',
        'billing',
        'payment required',
        'credit balance',
      ])) {
    return '模型服务余额或调用额度不足，请充值或更换 API Key';
  }
  if (statusCode == 429 ||
      _containsAny(searchable, const <String>[
        'rate limit',
        'rate_limit',
        'too many requests',
        'requests per minute',
        'tokens per minute',
      ])) {
    return '模型服务请求过于频繁，请稍后重试';
  }
  if (_containsAny(searchable, const <String>[
    'model not found',
    'model_not_found',
    'does not exist',
    'unknown model',
  ])) {
    return '所选模型不存在或当前 API Key 无权使用，请重新选择模型';
  }
  if (_containsAny(searchable, const <String>[
    'context length',
    'context_length',
    'maximum context',
    'too many tokens',
  ])) {
    return '发送内容超过模型上下文长度限制，请缩短内容后重试';
  }
  if (statusCode != null && statusCode >= 500 ||
      _containsAny(searchable, const <String>[
        'overloaded',
        'service unavailable',
        'server error',
        'internal error',
      ])) {
    return '模型服务暂时繁忙，请稍后重试';
  }

  // 服务商已经返回中文时保留其具体说明；其他语言统一使用产品内中文兜底。
  if (RegExp(r'[\u4e00-\u9fff]').hasMatch(message)) return message;
  return fallback;
}

bool _containsAny(String value, List<String> patterns) {
  return patterns.any(value.contains);
}
