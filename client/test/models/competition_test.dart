import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';

void main() {
  group('CompetitionEvent governance contract', () {
    test('解析后端治理字段', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 7,
        'title': '人工评估赛事',
        'manual_rating': 4.5,
        'evidence_status': 'verified',
        'strong_recommendation_ready': true,
      });

      expect(event.manualRating, 4.5);
      expect(event.evidenceStatus, 'verified');
      expect(event.strongRecommendationReady, isTrue);
    });

    test('旧响应缺少治理字段时采用失败关闭默认值', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 8,
        'title': '旧数据赛事',
        'recommendation_level': 'S',
        'importance_score': 100,
      });

      expect(event.manualRating, isNull);
      expect(event.evidenceStatus, 'pending');
      expect(event.strongRecommendationReady, isFalse);
    });
  });
}
