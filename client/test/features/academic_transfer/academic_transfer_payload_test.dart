import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_payload.dart';

final _key = 'A' * 87;
const _session = 'AAECAwQFBgcICQoLDA0ODw';

void main() {
  group('二维码链接', () {
    test('接受网页二维码和落地页的 App 链接', () {
      for (final raw in <String>[
        'https://sylulive.online/web/app-scan#v=1&s=$_session&k=$_key',
        'http://127.0.0.1:5173/web/app-scan#v=1&s=$_session&k=$_key',
        'sylulive://academic-transfer?v=1&s=$_session&k=$_key',
        '  https://sylulive.online/web/app-scan#v=1&s=$_session&k=$_key\n',
      ]) {
        final link = AcademicTransferLink.tryParse(raw);
        expect(link?.sessionId, _session, reason: raw);
        expect(link?.webPublicKey, _key, reason: raw);
      }
    });

    test('拒绝其他二维码、旧版本和不完整参数', () {
      for (final raw in <String?>[
        null,
        '',
        'https://sylulive.online/team/12',
        'https://sylulive.online/web/app-scan?v=1&s=$_session&k=$_key',
        'https://sylulive.online/web/app-scan#v=2&s=$_session&k=$_key',
        'https://sylulive.online/web/app-scan#v=1&s=short&k=$_key',
        'https://sylulive.online/web/app-scan#v=1&s=$_session&k=abc',
        'https://sylulive.online/web/app-scan#v=1&s=$_session&k=${'+' * 87}',
        'sylulive://team?v=1&s=$_session&k=$_key',
        'javascript:alert(1)',
      ]) {
        expect(AcademicTransferLink.tryParse(raw), isNull, reason: raw);
      }
    });
  });

  group('课程转换', () {
    test('节次展开、周次去重排序，并保留稳定 id', () {
      final course = transferCourseFromBlock(<String, dynamic>{
        'id': 5,
        'course_key': 'k1',
        'meeting_key': 'm1',
        'name': '高等数学',
        'teacher': '张老师',
        'location': 'A101',
        'weekday': 3,
        'start_section': 3,
        'end_section': 5,
        'weeks': [4, 2, 2, 61, 0],
        'note': '不应带出',
        'color': '#fff',
      }, 0);
      expect(course, <String, dynamic>{
        'id': 'k1:m1',
        'name': '高等数学',
        'teacher': '张老师',
        'room': 'A101',
        'day': 3,
        'periods': [3, 4, 5],
        'weeks': [2, 4],
      });
    });

    test('字段不完整的课程被丢弃', () {
      final base = <String, dynamic>{
        'name': '课',
        'weekday': 1,
        'start_section': 1,
        'end_section': 2,
        'weeks': [1],
      };
      expect(transferCourseFromBlock(base, 0)?['id'], 'app:0');
      for (final patch in <Map<String, dynamic>>[
        {'name': ' '},
        {'weekday': 8},
        {'start_section': 0},
        {'end_section': 21},
        {'start_section': 4, 'end_section': 2},
        {'weeks': <int>[]},
      ]) {
        expect(transferCourseFromBlock({...base, ...patch}, 0), isNull,
            reason: '$patch');
      }
      expect(
          transferCourses([
            base,
            {...base, 'weekday': 0},
            base
          ]),
          hasLength(2));
    });
  });

  test('成绩只保留展示字段，二课与体测转换为网页结构', () {
    final grade = transferGrade(<String, dynamic>{
      'name': '线性代数',
      'course_id': 'MATH01',
      'credits': '3',
      'grade': '--',
      'fraction': 92.5,
      'gpa': '4.2',
      'course_nature': '必修',
      'student_grade_id': 'secret-token',
      'class_id': 'class-1',
    }, '2025-2026 第一学期', 0);
    expect(grade, <String, dynamic>{
      'id': 'MATH01:2025-2026 第一学期',
      'name': '线性代数',
      'credit': 3.0,
      'score': '92.5',
      'gpa': 4.2,
      'nature': '必修',
      'term': '2025-2026 第一学期',
    });
    expect(transferGrade({'name': '无学分', 'grade': '90'}, 't', 0), isNull);

    final erke = transferErke(<String, dynamic>{
      'fetchedAt': '2026-11-09T10:00:00.000Z',
      'graduation': {
        'requiredTotal': 60,
        'earnedTotal': 42.5,
        'graduationGap': 17.5,
        'officialConclusion': '未达标',
        'categories': [
          {'code': 'A', 'name': '思想成长', 'required': 10, 'earned': 8},
          {'code': 'B', 'name': ''},
        ],
      },
      'activities': [
        {
          'item': '志愿服务',
          'score': '1.5',
          'date': '2026-10-01',
          'category': '志愿公益'
        },
      ],
    });
    expect(erke['earnedTotal'], 42.5);
    expect(erke['conclusion'], '未达标');
    expect(erke['categories'], hasLength(1));
    expect(erke['activities'], hasLength(1));

    final physical = transferPhysical(<String, dynamic>{
      'years': {
        '2024': {'total_grade': '及格', 'total_score': 70, 'scores': []},
        '2025': {
          'total_grade': '良好',
          'total_score': '82.5',
          'scores': [
            {'sub_name': '50米跑', 'result': '7.2', 'grade': '良好', 'score': 80},
          ],
        },
      },
    }, DateTime.utc(2026, 11, 8));
    expect(physical?['fetchedAt'], '2026-11-08T00:00:00.000Z');
    expect((physical?['years'] as List).first, <String, dynamic>{
      'year': '2025',
      'totalScore': 82.5,
      'totalGrade': '良好',
      'scores': [
        {'name': '50米跑', 'result': '7.2', 'grade': '良好', 'score': 80.0},
      ],
    });
    expect(transferPhysical(<String, dynamic>{'years': {}}, null), isNull);
  });

  test('只编码用户勾选的资料，空课表不发送', () {
    final bundle = AcademicTransferBundle(
      schedules: [
        AcademicTransferSchedule(
          id: 'current',
          kind: 'current',
          label: '2026-2027 第一学期',
          provider: 'undergraduate',
          year: '2026',
          semester: 3,
          termStart: DateTime(2026, 9, 7),
          courses: [
            {
              'id': 'c1',
              'name': '课',
              'teacher': '',
              'room': '',
              'day': 1,
              'periods': [1],
              'weeks': [1]
            },
          ],
        ),
        const AcademicTransferSchedule(
            id: 'term:x', kind: 'term', label: '空学期', courses: []),
      ],
      grades: const [
        {
          'id': 'g',
          'name': '课',
          'credit': 1,
          'score': '90',
          'gpa': 4.0,
          'nature': '',
          'term': ''
        },
      ],
      erke: const {'categories': [], 'activities': []},
    );
    expect(bundle.count(AcademicTransferPart.schedules), 1);
    expect(bundle.count(AcademicTransferPart.exams), 0);
    expect(bundle.isEmpty, isFalse);
    expect(const AcademicTransferBundle().isEmpty, isTrue);

    final decoded = jsonDecode(utf8.decode(bundle.encode(
      {AcademicTransferPart.schedules, AcademicTransferPart.exams},
      now: DateTime.utc(2026, 11, 11),
    ))) as Map<String, dynamic>;
    expect(decoded.keys, ['version', 'generatedAt', 'schedules']);
    expect(decoded['version'], 1);
    final schedule = (decoded['schedules'] as List).single as Map;
    expect(schedule['term'], {'year': '2026', 'semester': '3'});
    expect(schedule['termStart'], '2026-09-07');
    expect(schedule.containsKey('fetchedAt'), isFalse);

    final all = jsonDecode(
            utf8.decode(bundle.encode(AcademicTransferPart.values.toSet())))
        as Map<String, dynamic>;
    expect(all.keys, containsAll(['schedules', 'grades', 'erke']));
    expect(all.containsKey('exams'), isFalse);
    expect(all.containsKey('physical'), isFalse);
  });
}
