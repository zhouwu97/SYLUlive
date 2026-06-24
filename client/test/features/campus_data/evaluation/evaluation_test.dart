import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_models.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_page_detector.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_constants.dart';

/// Sample probe JSON fixtures as Dart maps.
Map<String, dynamic> _makeProbe({
  String url = 'https://jxw.sylu.edu.cn/xspjgl/xspj_cxXspjIndex.html',
  String title = '教学评价',
  String pageTextSample = '',
  int radioCount = 0,
  List<Map<String, dynamic>> radioOptions = const [],
  int textareaCount = 0,
  List<Map<String, dynamic>> forms = const [],
  List<Map<String, dynamic>> buttons = const [],
  List<Map<String, dynamic>> possibleCourseRows = const [],
  bool hasLoginForm = false,
  bool hasEvaluationForm = false,
  String? error,
}) {
  return {
    'url': url,
    'title': title,
    'pageTextSample': pageTextSample,
    'radioCount': radioCount,
    'radioOptions': radioOptions,
    'textareaCount': textareaCount,
    'forms': forms,
    'buttons': buttons,
    'possibleCourseRows': possibleCourseRows,
    'hasLoginForm': hasLoginForm,
    'hasEvaluationForm': hasEvaluationForm,
    if (error != null) 'error': error,
  };
}

Map<String, dynamic> _radioOption({
  String? name,
  String? id,
  String? value,
  String? dataDyf,
  String? dataScore,
  String? dataFz,
  bool checked = false,
  bool disabled = false,
}) {
  return {
    'name': name ?? 'group1',
    'id': id ?? 'opt1',
    'value': value ?? '1',
    'className': 'radio-option',
    if (dataDyf != null) 'data_dyf': dataDyf,
    if (dataScore != null) 'data_score': dataScore,
    if (dataFz != null) 'data_fz': dataFz,
    'checked': checked,
    'disabled': disabled,
  };
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ProbeResult JSON parsing
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationProbeResult.fromJson', () {
    test('parses minimal valid probe', () {
      final json = _makeProbe();
      final result = EvaluationProbeResult.fromJson(json);
      expect(result.url, contains('jxw.sylu.edu.cn'));
      expect(result.title, '教学评价');
      expect(result.radioCount, 0);
      expect(result.hasLoginForm, false);
      expect(result.hasEvaluationForm, false);
      expect(result.error, isNull);
    });

    test('parses probe with radio options', () {
      final json = _makeProbe(
        radioCount: 5,
        radioOptions: [
          _radioOption(
            name: 'pj_001',
            value: '5',
            dataDyf: '10',
          ),
          _radioOption(
            name: 'pj_001',
            value: '4',
            dataDyf: '8',
          ),
          _radioOption(
            name: 'pj_001',
            value: '3',
            dataDyf: '6',
          ),
          _radioOption(
            name: 'pj_002',
            value: '5',
            dataScore: '10',
          ),
          _radioOption(
            name: 'pj_002',
            value: '4',
            dataScore: '8',
          ),
        ],
        hasEvaluationForm: true,
      );
      final result = EvaluationProbeResult.fromJson(json);
      expect(result.radioCount, 5);
      expect(result.radioOptions.length, 5);
      expect(result.hasEvaluationForm, true);

      // Groups
      final groups = result.radioGroups;
      expect(groups.length, 2);
      expect(groups[0].name, 'pj_001');
      expect(groups[0].options.length, 3);
      expect(groups[1].name, 'pj_002');
      expect(groups[1].options.length, 2);
    });

    test('parses probe with all optional fields', () {
      final json = _makeProbe(
        url: 'https://jxw.sylu.edu.cn/eval/detail',
        title: '大学英语教学评价',
        pageTextSample: '教学态度 教学内容 教学方法 评价指标',
        radioCount: 20,
        radioOptions: List.generate(
            20,
            (i) => _radioOption(
                  name: 'group_${i ~/ 4}',
                  id: 'radio_$i',
                  value: '${(i % 4) + 1}',
                  dataDyf: '${((i % 4) + 1) * 2}',
                )),
        textareaCount: 2,
        forms: [
          {
            'id': 'form1',
            'name': 'evalForm',
            'action': '/submit',
            'method': 'post'
          }
        ],
        buttons: [
          {'id': 'btn_submit', 'text': '提交', 'type': 'submit'},
        ],
        possibleCourseRows: [],
        hasLoginForm: false,
        hasEvaluationForm: true,
      );
      final result = EvaluationProbeResult.fromJson(json);
      expect(result.textareaCount, 2);
      expect(result.forms.length, 1);
      expect(result.buttons.length, 1);
      expect(result.buttons[0]['text'], '提交');
    });

    test('handles null/empty fields gracefully', () {
      final json = <String, dynamic>{};
      final result = EvaluationProbeResult.fromJson(json);
      expect(result.url, '');
      expect(result.title, '');
      expect(result.radioCount, 0);
      expect(result.radioOptions, isEmpty);
      expect(result.forms, isEmpty);
      expect(result.buttons, isEmpty);
    });

    test('handles malformed radioOptions in raw JSON', () {
      // Build raw map directly (bypass typed _makeProbe factory) to
      // simulate a broken page injecting non-map entries.
      final raw = <String, dynamic>{
        'url': '',
        'title': '',
        'pageTextSample': '',
        'radioCount': 3,
        'radioOptions': <dynamic>[
          {'name': 'ok'},
          'not_a_map',
          null,
        ],
        'textareaCount': 0,
        'forms': <Map<String, dynamic>>[],
        'buttons': <Map<String, dynamic>>[],
        'possibleCourseRows': <Map<String, dynamic>>[],
        'hasLoginForm': false,
        'hasEvaluationForm': false,
      };
      // The Dart-level fromJson will throw when encountering non-Map
      // entries (it casts with `as Map`).  The caller (controller) is
      // therefore expected to guard this with try/catch.
      expect(
        () => EvaluationProbeResult.fromJson(raw),
        throwsA(isA<TypeError>()),
      );
    });

    test('handles JSON string input', () {
      final map = _makeProbe(
        url: 'https://jxw.sylu.edu.cn/test',
        title: 'Test',
        radioCount: 5,
        hasEvaluationForm: true,
      );
      final jsonStr = jsonEncode(map);
      // Simulate what the controller does:
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = EvaluationProbeResult.fromJson(decoded);
      expect(result.radioCount, 5);
      expect(result.hasEvaluationForm, true);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  RadioGroup score extraction
  // ═══════════════════════════════════════════════════════════════════
  group('RadioGroup score extraction', () {
    test('selects highest data-dyf score', () {
      final opts = [
        RadioOption(value: '1', dataDyf: '2'),
        RadioOption(value: '2', dataDyf: '6'),
        RadioOption(value: '3', dataDyf: '8'),
        RadioOption(value: '4', dataDyf: '10'),
        RadioOption(value: '5', dataDyf: '6'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 10);
      expect(group.bestOption!.value, '4');
    });

    test('falls back to data-score when no data-dyf', () {
      final opts = [
        RadioOption(value: '1', dataScore: '3'),
        RadioOption(value: '2', dataScore: '9'),
        RadioOption(value: '3', dataScore: '5'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 9);
      expect(group.bestOption!.value, '2');
    });

    test('falls back to data-fz', () {
      final opts = [
        RadioOption(value: 'a', dataFz: '85'),
        RadioOption(value: 'b', dataFz: '95'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 95);
      expect(group.bestOption!.value, 'b');
    });

    test('falls back to numeric value', () {
      final opts = [
        RadioOption(value: '10'),
        RadioOption(value: '20'),
        RadioOption(value: '30'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 30);
      expect(group.bestOption!.value, '30');
    });

    test('skips disabled options', () {
      final opts = [
        RadioOption(value: '10'),
        RadioOption(value: '99', disabled: true),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 10);
      expect(group.bestOption!.value, '10');
    });

    test('all disabled → bestScore null', () {
      final opts = [
        RadioOption(value: '10', disabled: true),
        RadioOption(value: '99', disabled: true),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, isNull);
      expect(group.bestOption, isNull);
    });

    test('no score attributes → bestScore null', () {
      final opts = [
        RadioOption(value: 'agree'),
        RadioOption(value: 'disagree'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, isNull);
      expect(group.bestOption, isNull);
    });

    test('text values not mistaken for scores', () {
      final opts = [
        RadioOption(value: '完全符合'),
        RadioOption(value: '比较符合'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.hasScoreAttribute, false);
      expect(group.bestOption, isNull);
    });

    test('isAlreadyCompleted detects checked state', () {
      final opts = [
        RadioOption(value: '1', checked: false),
        RadioOption(value: '2', checked: true),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.isAlreadyCompleted, true);
    });

    test('isAlreadyCompleted ignores checked+disabled', () {
      final opts = [
        RadioOption(value: '1', checked: false),
        RadioOption(value: '2', checked: true, disabled: true),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.isAlreadyCompleted, false);
    });

    test('non-numeric values not treated as scores', () {
      // "10" is numeric but "ten" is not
      final opts = [
        RadioOption(value: 'ten'),
        RadioOption(value: '100'), // 100 is in range
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 100);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  EvaluationFillResult
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationFillResult', () {
    test('parses successful fill', () {
      final json = {
        'totalGroups': 10,
        'completedGroups': 8,
        'unresolvedGroups': ['group_unknown'],
        'alreadyCompletedGroups': 1,
        'textareaCount': 2,
        'requiredTextareas': ['comment1'],
        'warnings': ['Group "group_unknown" has no scoreable options'],
      };
      final result = EvaluationFillResult.fromJson(json);
      expect(result.totalGroups, 10);
      expect(result.completedGroups, 8);
      expect(result.unresolvedGroups, ['group_unknown']);
      expect(result.hasUnresolved, true);
      expect(result.hasRequiredTextareas, true);
      expect(result.hasWarnings, true);
      expect(result.allCompleted, false);
    });

    test('parses all-completed fill', () {
      final json = {
        'totalGroups': 5,
        'completedGroups': 5,
        'unresolvedGroups': <String>[],
        'alreadyCompletedGroups': 0,
        'textareaCount': 0,
        'requiredTextareas': <String>[],
        'warnings': <String>[],
      };
      final result = EvaluationFillResult.fromJson(json);
      expect(result.allCompleted, true);
      expect(result.hasUnresolved, false);
      expect(result.hasRequiredTextareas, false);
    });

    test('handles fill error', () {
      final result = EvaluationFillResult.error('Something went wrong');
      expect(result.error, 'Something went wrong');
      expect(result.totalGroups, 0);
    });

    test('parses fill result with error field from JSON', () {
      final json = {
        'totalGroups': 0,
        'completedGroups': 0,
        'unresolvedGroups': <String>[],
        'alreadyCompletedGroups': 0,
        'textareaCount': 0,
        'requiredTextareas': <String>[],
        'warnings': <String>[],
        'error': 'Script crashed',
      };
      final result = EvaluationFillResult.fromJson(json);
      expect(result.error, 'Script crashed');
    });

    test('handles empty JSON', () {
      final result = EvaluationFillResult.fromJson({});
      expect(result.totalGroups, 0);
      expect(result.completedGroups, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Page type detection
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationPageDetector', () {
    const detector = EvaluationPageDetector();

    test('detects login page by form', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        hasLoginForm: true,
        pageTextSample: '统一身份认证 用户名 密码',
      ));
      expect(detector.classify(probe), EvaluationPageType.login);
    });

    test('detects login page by CAS text', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        pageTextSample: 'CAS 统一身份认证 登录',
      ));
      expect(detector.classify(probe), EvaluationPageType.login);
    });

    test('detects evaluation form by flag', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        hasEvaluationForm: true,
        radioCount: 20,
        pageTextSample: '教学评价 评价指标 教学态度',
      ));
      expect(detector.classify(probe), EvaluationPageType.evaluationForm);
    });

    test('detects evaluation form by many radio groups', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        url: 'https://jxw.sylu.edu.cn/xspjgl/eval_detail.html',
        radioCount: 15,
        // 15 options each with a unique name → 15 groups → triggers evaluationForm
        radioOptions: List.generate(
            15,
            (i) => _radioOption(
                  name: 'g$i',
                  value: '${(i % 5) + 1}',
                  dataDyf: '${(i % 5) * 2 + 2}',
                )),
      ));
      // 15 groups (each with 1 option) — enough to trigger evaluationForm
      expect(detector.classify(probe), EvaluationPageType.evaluationForm);
    });

    test('detects course list by rows', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        possibleCourseRows: [
          {
            'index': 0,
            'cells': ['大学英语', '张老师', '待评价', '操作']
          },
          {
            'index': 1,
            'cells': ['高等数学', '李老师', '已评价', '查看']
          },
        ],
        pageTextSample: '本学期课程 待评价 评价列表',
      ));
      expect(detector.classify(probe), EvaluationPageType.courseList);
    });

    test('detects submitted page', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        pageTextSample: '提交成功 评价成功 感谢您的评价',
      ));
      expect(detector.classify(probe), EvaluationPageType.submitted);
    });

    test('detects session expired', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        pageTextSample: '会话已过期 请重新登录 登录超时',
      ));
      expect(detector.classify(probe), EvaluationPageType.sessionExpired);
    });

    test('detects access denied', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        pageTextSample: '无权限 禁止访问',
      ));
      expect(detector.classify(probe), EvaluationPageType.accessDenied);
    });

    test('detects maintenance as access denied', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        pageTextSample: '系统维护 暂未开放',
      ));
      expect(detector.classify(probe), EvaluationPageType.accessDenied);
    });

    test('detects URL-based course list', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        url:
            'https://jxw.sylu.edu.cn/xspjgl/xspj_cxXspjIndex.html?gnmkdm=N401605',
        pageTextSample: '学生评教',
      ));
      expect(detector.classify(probe), EvaluationPageType.courseList);
    });

    test('empty page → unknown', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        url: 'https://jxw.sylu.edu.cn/unknown_page.html',
      ));
      expect(detector.classify(probe), EvaluationPageType.unknown);
    });

    test('error probe → unknown', () {
      final probe = EvaluationProbeResult.fromJson(_makeProbe(
        error: 'Network error',
      ));
      expect(detector.classify(probe), EvaluationPageType.unknown);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Domain allowlist
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationDomainAllowlist', () {
    test('allows jxw.sylu.edu.cn', () {
      expect(
        EvaluationDomainAllowlist.isAllowed('jxw.sylu.edu.cn'),
        true,
      );
    });

    test('allows authserver.sylu.edu.cn', () {
      expect(
        EvaluationDomainAllowlist.isAllowed('authserver.sylu.edu.cn'),
        true,
      );
    });

    test('allows webvpn.sylu.edu.cn', () {
      expect(
        EvaluationDomainAllowlist.isAllowed('webvpn.sylu.edu.cn'),
        true,
      );
    });

    test('allows subdomain of sylu.edu.cn', () {
      expect(
        EvaluationDomainAllowlist.isAllowed('xg.sylu.edu.cn'),
        true,
      );
    });

    test('rejects external domain', () {
      expect(
        EvaluationDomainAllowlist.isAllowed('evil.example.com'),
        false,
      );
    });

    test('rejects empty host', () {
      expect(EvaluationDomainAllowlist.isAllowed(''), false);
    });

    test('allows lnu.edu.cn subdomain', () {
      expect(
        EvaluationDomainAllowlist.isAllowed('auth.lnu.edu.cn'),
        true,
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Page detector labels
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationPageDetector labels', () {
    test('each type has a non-empty label', () {
      for (final type in EvaluationPageType.values) {
        final label = EvaluationPageDetector.label(type);
        expect(label.isNotEmpty, true, reason: 'Label missing for $type');
      }
    });
  });
}
