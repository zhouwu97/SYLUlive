import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/competition/competition_status_helper.dart';

void main() {
  group('CompetitionStatusHelper', () {
    test('competitionManualRatingLabel', () {
      expect(competitionManualRatingLabel('A'), 'A');
      expect(competitionManualRatingLabel('S'), 'S');
      expect(competitionManualRatingLabel('B+'), 'B+');
      expect(competitionManualRatingLabel('  '), '未评级');
      expect(competitionManualRatingLabel(''), '未评级');
    });

    test('competitionManualRatingShort', () {
      expect(competitionManualRatingShort('A'), '人工 A');
      expect(competitionManualRatingShort(' B+ '), '人工 B+');
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
