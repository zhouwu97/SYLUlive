import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/ai_provider_error_localizer.dart';

void main() {
  test('余额不足错误转换为中文操作提示', () {
    expect(
      localizeAIProviderError(
        statusCode: 402,
        rawMessage: 'Insufficient Balance',
        fallback: '模型服务请求失败',
      ),
      '模型服务余额或调用额度不足，请充值或更换 API Key',
    );
  });

  test('常见服务商错误使用中文提示', () {
    expect(
      localizeAIProviderError(
        statusCode: 429,
        rawMessage: 'Rate limit exceeded',
        fallback: '模型服务请求失败',
      ),
      '模型服务请求过于频繁，请稍后重试',
    );
    expect(
      localizeAIProviderError(
        statusCode: 404,
        rawMessage: 'Model not found',
        fallback: '模型服务请求失败',
      ),
      '所选模型不存在或当前 API Key 无权使用，请重新选择模型',
    );
  });

  test('平台内部预算限制不走第三方余额文案', () {
    expect(
      localizeAIProviderError(
        statusCode: 503,
        errorCode: 'ai_budget_exceeded',
        rawMessage: '当前 AI 服务额度已达到平台限制',
        fallback: '模型服务请求失败',
      ),
      '当前 AI 服务额度已达到平台限制\n额度购买与计费功能暂未开发',
    );
  });

  test('未知英文不直接显示，中文服务商提示予以保留', () {
    expect(
      localizeAIProviderError(
        rawMessage: 'Unknown upstream failure detail',
        fallback: '模型服务请求失败，请稍后重试',
      ),
      '模型服务请求失败，请稍后重试',
    );
    expect(
      localizeAIProviderError(
        rawMessage: '当前账户已被冻结',
        fallback: '模型服务请求失败',
      ),
      '当前账户已被冻结',
    );
  });
}
