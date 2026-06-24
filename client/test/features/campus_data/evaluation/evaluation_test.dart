import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_models.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_page_detector.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_constants.dart';

/// Build a minimal probe map.
Map<String, dynamic> _makeProbe({
  String url = 'https://jxw.sylu.edu.cn/xspjgl/eval_detail.html',
  String title = '',
  String pageTextSample = '',
  int radioCount = 0,
  List<Map<String, dynamic>> radioOptions = const [],
  int textareaCount = 0,
  List<Map<String, dynamic>> forms = const [],
  List<Map<String, dynamic>> buttons = const [],
  List<Map<String, dynamic>> possibleCourseRows = const [],
  bool hasLoginForm = false,
  bool hasEvaluationForm = false,
  bool hasSubmittedText = false,
  bool hasSessionExpiredText = false,
  bool hasAccessDeniedText = false,
  bool hasMaintenanceText = false,
  bool hasAlreadyEvaluatedText = false,
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
    'hasSubmittedText': hasSubmittedText,
    'hasSessionExpiredText': hasSessionExpiredText,
    'hasAccessDeniedText': hasAccessDeniedText,
    'hasMaintenanceText': hasMaintenanceText,
    'hasAlreadyEvaluatedText': hasAlreadyEvaluatedText,
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
  final m = <String, dynamic>{
    'name': name ?? 'group1',
    'id': id ?? 'opt1',
    'value': value ?? '1',
    'className': 'radio-option',
    'checked': checked,
    'disabled': disabled,
  };
  if (dataDyf != null) m['data_dyf'] = dataDyf;
  if (dataScore != null) m['data_score'] = dataScore;
  if (dataFz != null) m['data_fz'] = dataFz;
  return m;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ProbeResult JSON parsing
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationProbeResult.fromJson', () {
    test('parses new boolean text flags', () {
      final json = _makeProbe(
        hasSubmittedText: true,
        hasSessionExpiredText: false,
        hasAccessDeniedText: false,
        hasMaintenanceText: false,
        hasAlreadyEvaluatedText: true,
      );
      final result = EvaluationProbeResult.fromJson(json);
      expect(result.hasSubmittedText, true);
      expect(result.hasSessionExpiredText, false);
      expect(result.hasAccessDeniedText, false);
      expect(result.hasMaintenanceText, false);
      expect(result.hasAlreadyEvaluatedText, true);
    });

    test('boolean flags default to false when absent', () {
      final result = EvaluationProbeResult.fromJson({
        'url': '',
        'title': '',
        'pageTextSample': '',
        'radioCount': 0,
        'radioOptions': <Map<String, dynamic>>[],
        'textareaCount': 0,
        'forms': <Map<String, dynamic>>[],
        'buttons': <Map<String, dynamic>>[],
        'possibleCourseRows': <Map<String, dynamic>>[],
        'hasLoginForm': false,
        'hasEvaluationForm': false,
      });
      expect(result.hasSubmittedText, false);
      expect(result.hasSessionExpiredText, false);
      expect(result.hasAccessDeniedText, false);
      expect(result.hasMaintenanceText, false);
      expect(result.hasAlreadyEvaluatedText, false);
    });

    test('parses radio groups from options', () {
      final json = _makeProbe(
        radioCount: 6,
        radioOptions: [
          _radioOption(name: 'g1', value: '1', dataDyf: '10'),
          _radioOption(name: 'g1', value: '2', dataDyf: '8'),
          _radioOption(name: 'g2', value: '1', dataScore: '95'),
          _radioOption(name: 'g2', value: '2', dataScore: '85'),
          _radioOption(name: 'g3', value: '1', dataFz: '100'),
          _radioOption(name: 'g3', value: '2', dataFz: '90'),
        ],
      );
      final result = EvaluationProbeResult.fromJson(json);
      expect(result.radioGroups.length, 3);
    });

    test('handles empty probe gracefully', () {
      final result = EvaluationProbeResult.fromJson({});
      expect(result.url, '');
      expect(result.radioCount, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  RadioGroup — score extraction (data attributes ONLY, no value)
  // ═══════════════════════════════════════════════════════════════════
  group('RadioGroup score extraction (data attributes only)', () {
    test('data-dyf selects highest', () {
      final opts = [
        RadioOption(value: '1', dataDyf: '2'),
        RadioOption(value: '2', dataDyf: '10'),
        RadioOption(value: '3', dataDyf: '6'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 10);
      expect(group.bestOption!.dataDyf, '10');
    });

    test('data-score fallback', () {
      final opts = [
        RadioOption(value: 'a', dataScore: '85'),
        RadioOption(value: 'b', dataScore: '95'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 95);
    });

    test('data-fz fallback', () {
      final opts = [
        RadioOption(value: 'x', dataFz: '70'),
        RadioOption(value: 'y', dataFz: '100'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 100);
    });

    test('numeric value NEVER used as score', () {
      final opts = [
        RadioOption(value: '100'), // looks like a score but has no data attrs
        RadioOption(value: '1'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.hasScoreAttribute, false);
      expect(group.bestScore, isNull);
      expect(group.bestOption, isNull);
    });

    test('value=1/2/3/4/5 without data attrs → no selection', () {
      final opts = [
        RadioOption(value: '1'),
        RadioOption(value: '2'),
        RadioOption(value: '3'),
        RadioOption(value: '4'),
        RadioOption(value: '5'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestOption, isNull);
    });

    test('value=100 without data attrs → no selection', () {
      final opts = [RadioOption(value: '50'), RadioOption(value: '100')];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestOption, isNull);
    });

    test('data-dyf present → works correctly', () {
      final opts = [
        RadioOption(value: '1', dataDyf: '10'),
        RadioOption(value: '2', dataDyf: '8'),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.hasScoreAttribute, true);
      expect(group.bestScore, 10);
      expect(group.bestOption!.dataDyf, '10');
    });

    test('skips disabled options', () {
      final opts = [
        RadioOption(value: '1', dataDyf: '10'),
        RadioOption(value: '2', dataDyf: '99', disabled: true),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, 10);
    });

    test('all disabled → null', () {
      final opts = [
        RadioOption(dataDyf: '10', disabled: true),
        RadioOption(dataDyf: '99', disabled: true),
      ];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.bestScore, isNull);
      expect(group.bestOption, isNull);
    });

    test('no score attributes → null', () {
      final opts = [RadioOption(value: '完全符合'), RadioOption(value: '比较符合')];
      final group = RadioGroup(name: 'test', options: opts);
      expect(group.hasScoreAttribute, false);
      expect(group.bestOption, isNull);
    });

    test('isAlreadyCompleted detects checked', () {
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
  });

  // ═══════════════════════════════════════════════════════════════════
  //  FillResult
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationFillResult', () {
    test('parses complete', () {
      final json = {
        'totalGroups': 10,
        'completedGroups': 8,
        'unresolvedGroups': ['g1'],
        'alreadyCompletedGroups': 1,
        'textareaCount': 2,
        'requiredTextareas': ['comment1'],
        'warnings': ['Group "g1" has no scoreable options'],
      };
      final r = EvaluationFillResult.fromJson(json);
      expect(r.totalGroups, 10);
      expect(r.completedGroups, 8);
      expect(r.hasUnresolved, true);
      expect(r.hasRequiredTextareas, true);
      expect(r.allCompleted, false);
    });

    test('all completed', () {
      final json = {
        'totalGroups': 5,
        'completedGroups': 5,
        'unresolvedGroups': <String>[],
        'alreadyCompletedGroups': 0,
        'textareaCount': 0,
        'requiredTextareas': <String>[],
        'warnings': <String>[],
      };
      final r = EvaluationFillResult.fromJson(json);
      expect(r.allCompleted, true);
    });

    test('error factory', () {
      final r = EvaluationFillResult.error('bad');
      expect(r.error, 'bad');
      expect(r.totalGroups, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Page detector (tightened rules)
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationPageDetector', () {
    const detector = EvaluationPageDetector();

    // ── Login ──
    test('detects login by form', () {
      final p = EvaluationProbeResult.fromJson(_makeProbe(hasLoginForm: true));
      expect(detector.classify(p), EvaluationPageType.login);
    });

    test('detects login by CAS title', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(title: '统一身份认证 - 登录'),
      );
      expect(detector.classify(p), EvaluationPageType.login);
    });

    // ── Session expired ──
    test('detects session expired via boolean flag', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(hasSessionExpiredText: true),
      );
      expect(detector.classify(p), EvaluationPageType.sessionExpired);
    });

    // ── Access denied / maintenance ──
    test('detects access denied', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(hasAccessDeniedText: true),
      );
      expect(detector.classify(p), EvaluationPageType.accessDenied);
    });

    test('detects maintenance', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(hasMaintenanceText: true),
      );
      expect(detector.classify(p), EvaluationPageType.accessDenied);
    });

    // ── Submitted ──
    test('detects submitted via flag', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(hasSubmittedText: true),
      );
      expect(detector.classify(p), EvaluationPageType.submitted);
    });

    test('detects already evaluated', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(hasAlreadyEvaluatedText: true),
      );
      expect(detector.classify(p), EvaluationPageType.submitted);
    });

    // ── Evaluation form (requires /xspjgl/ + ≥3 groups with ≥2 options) ──
    test('detects evaluation form with correct URL and groups', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(
          url: 'https://jxw.sylu.edu.cn/xspjgl/eval_detail.html',
          hasEvaluationForm: true,
          radioCount: 9,
          radioOptions: [
            _radioOption(name: 'g1', value: '1', dataDyf: '10'),
            _radioOption(name: 'g1', value: '2', dataDyf: '8'),
            _radioOption(name: 'g2', value: '1', dataScore: '95'),
            _radioOption(name: 'g2', value: '2', dataScore: '85'),
            _radioOption(name: 'g3', value: '1', dataFz: '100'),
            _radioOption(name: 'g3', value: '2', dataFz: '90'),
            _radioOption(name: 'g4', value: '1', dataDyf: '10'),
            _radioOption(name: 'g4', value: '2', dataDyf: '8'),
            _radioOption(name: 'g5', value: '1', dataScore: '95'),
          ],
        ),
      );
      expect(detector.classify(p), EvaluationPageType.evaluationForm);
    });

    test('rejects evaluation form without /xspjgl/ in URL', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(
          url: 'https://jxw.sylu.edu.cn/other/page.html',
          radioCount: 15,
          radioOptions: List.generate(
            15,
            (i) => _radioOption(
              name: 'g${i ~/ 3}',
              value: '${(i % 5) + 1}',
              dataDyf: '${(i % 5) * 2 + 2}',
            ),
          ),
        ),
      );
      // Without /xspjgl/ in URL, should NOT be evaluationForm
      expect(detector.classify(p), isNot(EvaluationPageType.evaluationForm));
    });

    test('5 plain radios without /xspjgl/ → not evaluation form', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(
          url: 'https://jxw.sylu.edu.cn/some/query_page.html',
          radioCount: 5,
          radioOptions: List.generate(
            5,
            (i) => _radioOption(name: 'g$i', value: '${i + 1}'),
          ),
        ),
      );
      expect(detector.classify(p), isNot(EvaluationPageType.evaluationForm));
    });

    // ── Course list ──
    test('detects course list by index URL + few radios', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(
          url: 'https://jxw.sylu.edu.cn/xspjgl/xspj_cxXspjIndex.html',
          possibleCourseRows: [
            {
              'index': 0,
              'cells': ['高数', '李老师', '待评价'],
            },
            {
              'index': 1,
              'cells': ['英语', '张老师', '已评价'],
            },
          ],
        ),
      );
      expect(detector.classify(p), EvaluationPageType.courseList);
    });

    test('course list not mistaken for evaluation form', () {
      // URL has xspjIndex but few radio groups → courseList
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(
          url: 'https://jxw.sylu.edu.cn/xspjgl/xspj_cxXspjIndex.html',
          radioCount: 4,
          radioOptions: [
            _radioOption(name: 'g1', value: '1'),
            _radioOption(name: 'g1', value: '2'),
          ],
          possibleCourseRows: [],
        ),
      );
      expect(detector.classify(p), EvaluationPageType.courseList);
    });

    // ── Unknown ──
    test('empty page → unknown', () {
      final p = EvaluationProbeResult.fromJson(
        _makeProbe(url: 'https://jxw.sylu.edu.cn/unknown_page.html'),
      );
      expect(detector.classify(p), EvaluationPageType.unknown);
    });

    test('error probe → unknown', () {
      final p = EvaluationProbeResult.fromJson(_makeProbe(error: 'fail'));
      expect(detector.classify(p), EvaluationPageType.unknown);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Domain allowlist (no lnu.edu.cn)
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationDomainAllowlist', () {
    test('allows sylu.edu.cn subdomains', () {
      expect(EvaluationDomainAllowlist.isAllowed('jxw.sylu.edu.cn'), true);
      expect(
        EvaluationDomainAllowlist.isAllowed('authserver.sylu.edu.cn'),
        true,
      );
      expect(EvaluationDomainAllowlist.isAllowed('webvpn.sylu.edu.cn'), true);
      expect(EvaluationDomainAllowlist.isAllowed('xg.sylu.edu.cn'), true);
    });

    test('rejects external domain', () {
      expect(EvaluationDomainAllowlist.isAllowed('evil.com'), false);
      expect(EvaluationDomainAllowlist.isAllowed('lnu.edu.cn'), false);
    });

    test('rejects empty host', () {
      expect(EvaluationDomainAllowlist.isAllowed(''), false);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  EvaluationUrls
  // ═══════════════════════════════════════════════════════════════════
  group('EvaluationUrls', () {
    test('evaluation index is non-empty', () {
      expect(EvaluationUrls.evaluationIndex.isNotEmpty, true);
      expect(EvaluationUrls.evaluationIndex, contains('/xspjgl/'));
    });

    test('cookie domains are real URLs (no wildcards)', () {
      for (final d in EvaluationUrls.cookieDomains) {
        expect(d, contains('https://'));
        expect(Uri.tryParse(d), isNotNull);
        // Must not be a wildcard/prefix pattern like https://.sylu.edu.cn
        expect(d, isNot(contains('https://.')));
      }
    });

    test('evaluation path prefix is /xspjgl/', () {
      expect(EvaluationUrls.evaluationPathPrefix, '/xspjgl/');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Labels
  // ═══════════════════════════════════════════════════════════════════
  group('Page detector labels', () {
    test('every type has non-empty label', () {
      for (final t in EvaluationPageType.values) {
        expect(EvaluationPageDetector.label(t).isNotEmpty, true);
      }
    });
  });
}
