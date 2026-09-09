import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/widgets/competition/competition_status_helper.dart';

void main() {
  test('人数缺失不能推定为零人、单人或不限人数', () {
    CompetitionEvent event({int? min, int? max}) => CompetitionEvent(
          id: 1,
          title: '比赛',
          teamSizeMin: min,
          teamSizeMax: max,
        );
    expect(competitionTeamSizeText(event(min: 0, max: 0)), '人数要求待确认');
    expect(competitionTeamSizeText(event(min: 3)), '至少 3 人，上限待确认');
    expect(competitionTeamSizeText(event(max: 5)), '最多 5 人，下限待确认');
    expect(competitionTeamSizeText(event(min: 3, max: 3)), '3 人');
    expect(competitionTeamSizeText(event(min: 3, max: 5)), '3–5 人');
    expect(competitionTeamSizeText(event(min: 5, max: 3)), '人数要求待核实');
  });

  test('原始枚举显示中文，已有中文内容保持不变', () {
    expect(competitionParticipationLabel('not_recorded'), '参赛形式待确认');
    expect(competitionParticipationLabel('team'), '团队赛');
    expect(competitionParticipationLabel('个人或团队（按赛道）'), '个人或团队（按赛道）');
    expect(competitionLevelLabel('national'), '国家级');
    expect(competitionLevelLabel('省级'), '省级');
    expect(competitionSourceLabel('pending'), '来源待核实');
  });

  group('CompetitionStatusHelper', () {
    test('competitionManualRatingLabel', () {
      expect(competitionManualRatingLabel('A'), 'A');
      expect(competitionManualRatingLabel('S'), 'S');
      expect(competitionManualRatingLabel('B+'), 'B+');
      expect(competitionManualRatingLabel('  '), '未评级');
      expect(competitionManualRatingLabel(''), '未评级');
    });

    test('competitionManualRatingShort', () {
      expect(competitionManualRatingShort('A'), '价值 A');
      expect(competitionManualRatingShort(' B+ '), '价值 B+');
      expect(competitionManualRatingShort('  '), '');
      expect(competitionManualRatingShort(''), '');
    });

    test('competitionSchoolRecognitionLabel', () {
      expect(
          competitionSchoolRecognitionLabel(status: 'recognized', grade: 'A'),
          '学校认定等级 A');
      expect(competitionSchoolRecognitionLabel(status: 'recognized', grade: ''),
          '学校已认定');
      expect(competitionSchoolRecognitionLabel(status: 'pending', grade: 'A'),
          '学校认定待确认');
      expect(
          competitionSchoolRecognitionLabel(
              status: 'not_recognized', grade: ''),
          '学校未认定');
      expect(
          competitionSchoolRecognitionLabel(status: 'unknown', grade: ''), '');
      expect(competitionSchoolRecognitionLabel(status: '  ', grade: ''), '');
    });

    test('competitionSchoolRecognitionShort', () {
      expect(
          competitionSchoolRecognitionShort(status: 'recognized', grade: 'A'),
          '校认 A');
      expect(competitionSchoolRecognitionShort(status: 'recognized', grade: ''),
          '校已认');
      expect(competitionSchoolRecognitionShort(status: 'pending', grade: 'B'),
          '校认待定');
      expect(
          competitionSchoolRecognitionShort(
              status: 'not_recognized', grade: ''),
          '校不认');
      expect(
          competitionSchoolRecognitionShort(status: 'unknown', grade: ''), '');
      expect(competitionSchoolRecognitionShort(status: '', grade: ''), '');
    });
  });
}
