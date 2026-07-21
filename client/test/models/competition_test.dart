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

  group('CompetitionEvent rating compatibility', () {
    test('新旧评级同时存在时分别保留', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 9,
        'title': '迁移中赛事',
        'competition_rating': 'A',
        'recommendation_level': 'B+',
      });

      expect(event.competitionRating, 'A');
      expect(event.recommendationLevel, 'B+');
    });

    test('仅有旧字段时为新评级提供兼容值', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 10,
        'title': '旧响应赛事',
        'competition_rating': ' ',
        'recommendation_level': 'B',
      });

      expect(event.competitionRating, 'B');
      expect(event.recommendationLevel, 'B');
      expect(event.toJson()['competition_rating'], 'B');
    });

    test('仅有新字段时旧属性仍可读取', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 11,
        'title': '新响应赛事',
        'competition_rating': 'S',
      });

      expect(event.competitionRating, 'S');
      expect(event.recommendationLevel, 'S');
    });
  });
}
