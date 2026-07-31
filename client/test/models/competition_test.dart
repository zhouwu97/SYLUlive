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

  group('CompetitionEvent preference matching', () {
    test('解析并序列化个性化分数和推荐层级', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 12,
        'title': '程序设计竞赛',
        'personalized_score': 78,
        'recommendation_tier': 'recommended',
        'fit_level': 'preference',
        'fit_reasons': ['与你关注的程序设计方向一致'],
      });

      expect(event.personalizedScore, 78);
      expect(event.recommendationTier, 'recommended');
      expect(event.fitLevel, 'preference');
      expect(event.toJson()['personalized_score'], 78);
      expect(event.toJson()['recommendation_tier'], 'recommended');
    });

    test('旧响应不产生个性化字段', () {
      final event = CompetitionEvent.fromJson(<String, dynamic>{
        'id': 13,
        'title': '通用赛事',
      });

      expect(event.personalizedScore, isNull);
      expect(event.recommendationTier, isEmpty);
      expect(event.toJson().containsKey('personalized_score'), isFalse);
    });
  });

  group('CompetitionEvent candidate contract', () {
    test('匹配维度、解释字段和权限门可往返序列化', () {
      final source = <String, dynamic>{
        'id': 14,
        'competition_id': 'COMP-014',
        'title': '候选赛事',
        'group_key': 'major_match',
        'rule_order': 2,
        'match_dimensions': {
          'eligibility': 'matched',
          'major': 'matched',
          'college': 'unknown',
          'grade': 'partial',
          'goal': 'matched',
          'direction': 'matched',
          'skill': 'partial',
          'role': 'unknown',
          'time': 'matched',
          'training': 'unknown',
        },
        'core_reason': '资格与专业方向符合',
        'cautions': ['报名时间待确认'],
        'questions_to_confirm': ['是否接受长期训练'],
        'evidence_subgrade': 'B1',
        'dataset_version': 'catalog-2026-07',
        'record_hash': 'hash-014',
        'gates': {
          'candidate_pool_allowed': true,
          'personalized_ranking_allowed': false,
          'strong_recommendation_eligible': false,
          'recommendation_permission_level': 'candidate_only',
          'ai_mode': 'candidate_explanation',
        },
      };

      final event = CompetitionEvent.fromJson(source);
      final serialized = event.toJson();

      expect(serialized['competition_id'], 'COMP-014');
      expect(serialized['group_key'], 'major_match');
      expect(serialized['match_dimensions'], source['match_dimensions']);
      expect(serialized['core_reason'], '资格与专业方向符合');
      expect(serialized['gates'], source['gates']);
    });
  });
}
