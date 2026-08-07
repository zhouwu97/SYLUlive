import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';

void main() {
  test('解析服务端 AI 能力与配额', () {
    final capabilities = AiCapabilities.fromJson({
      'enabled': true,
      'access_allowed': true,
      'internal_test_only': true,
      'phase': 'p0',
      'chat_enabled': false,
      'features': {
        'policy_rag': false,
        'schedule_windows': false,
        'hy3_competition_compare': true,
        'hy3_academic_analysis': true,
        'hy3_week_plan': true,
      },
      'quota': {
        'limit': 3,
        'remaining': 2,
        'unlimited': true,
        'window_seconds': 3600,
        'reset_at': '2026-07-19T12:30:00+08:00',
      },
      'max_message_chars': 501,
    });

    expect(capabilities.isVisible, isTrue);
    expect(capabilities.chatEnabled, isFalse);
    expect(capabilities.phase, 'p0');
    expect(capabilities.quota.remaining, 2);
    expect(capabilities.quota.unlimited, isTrue);
    expect(capabilities.quota.resetAt, isNotNull);
    expect(capabilities.maxMessageChars, 500);
    expect(capabilities.features.hy3CompetitionCompare, isTrue);
    expect(capabilities.features.hy3AcademicAnalysis, isTrue);
    expect(capabilities.features.hy3WeekPlan, isTrue);
  });

  test('无资格账号不会显示入口', () {
    final capabilities = AiCapabilities.fromJson({
      'enabled': true,
      'access_allowed': false,
      'features': <String, dynamic>{},
      'quota': <String, dynamic>{},
    });

    expect(capabilities.isVisible, isFalse);
    expect(capabilities.maxMessageChars, 500);
    expect(capabilities.features.hy3CompetitionCompare, isFalse);
    expect(capabilities.features.hy3AcademicAnalysis, isFalse);
    expect(capabilities.features.hy3WeekPlan, isFalse);
  });
}
