/// Pure-Dart page-type classifier.
///
/// Uses the probe result JSON to determine which type of教务 page the WebView
/// is currently showing.  No DOM access — only structured probe data.
library;

import 'evaluation_models.dart';
import 'evaluation_constants.dart';

/// Classifies a教务 evaluation page based on probe data.
class EvaluationPageDetector {
  const EvaluationPageDetector();

  /// Determine the page type from a probe result.
  ///
  /// Order matters: more specific checks run first.
  EvaluationPageType classify(EvaluationProbeResult probe) {
    if (probe.error != null && probe.error!.isNotEmpty) {
      return EvaluationPageType.unknown;
    }

    final body = probe.pageTextSample.toLowerCase();
    final title = probe.title.toLowerCase();

    // 1. Submitted / success
    if (_matchesAny(body, EvaluationPageTextPatterns.submitted)) {
      return EvaluationPageType.submitted;
    }

    // 2. Session expired
    if (_matchesAny(body, EvaluationPageTextPatterns.sessionExpired)) {
      return EvaluationPageType.sessionExpired;
    }

    // 3. Access denied
    if (_matchesAny(body, EvaluationPageTextPatterns.accessDenied) ||
        probe.url.contains('403') ||
        probe.url.contains('denied')) {
      return EvaluationPageType.accessDenied;
    }

    // 4. Maintenance
    if (_matchesAny(body, EvaluationPageTextPatterns.maintenance)) {
      return EvaluationPageType.accessDenied;
    }

    // 5. Login page
    if (probe.hasLoginForm) {
      return EvaluationPageType.login;
    }
    // Also check for login-related text that may not have a password field
    if (body.contains('统一身份认证') ||
        body.contains('cas') && body.contains('登录') ||
        title.contains('登录') && title.contains('认证')) {
      return EvaluationPageType.login;
    }

    // 6. Evaluation form
    if (probe.hasEvaluationForm) {
      return EvaluationPageType.evaluationForm;
    }

    // 7. Course list
    if (_isCourseList(probe)) {
      return EvaluationPageType.courseList;
    }

    // 8. Evaluation form (weaker signal — many radios)
    if (probe.radioGroups.length >= 3) {
      return EvaluationPageType.evaluationForm;
    }

    // 9. Possible submitted page (thank-you text)
    if (body.contains('评教') && (body.contains('完成') || body.contains('结束'))) {
      return EvaluationPageType.submitted;
    }

    return EvaluationPageType.unknown;
  }

  bool _matchesAny(String text, List<String> patterns) {
    return patterns.any((p) => text.contains(p.toLowerCase()));
  }

  bool _isCourseList(EvaluationProbeResult probe) {
    final body = probe.pageTextSample.toLowerCase();

    // Multiple course rows
    if (probe.possibleCourseRows.length >= 2 && probe.radioCount < 5) {
      return true;
    }

    // Course list keywords without evaluation form
    final listKeywords = ['待评价', '未评价', '评价列表', '课程列表', '本学期'];
    final hits = listKeywords.where((k) => body.contains(k)).length;

    if (hits >= 2 && !probe.hasEvaluationForm) {
      return true;
    }

    // URL-based hint
    if (probe.url.contains('xspjIndex') || probe.url.contains('xspj_cx')) {
      return true;
    }

    return false;
  }

  /// Returns a human-readable label for the page type.
  static String label(EvaluationPageType type) {
    switch (type) {
      case EvaluationPageType.loading:
        return '加载中...';
      case EvaluationPageType.login:
        return '登录页面';
      case EvaluationPageType.courseList:
        return '课程列表';
      case EvaluationPageType.evaluationForm:
        return '评价表单';
      case EvaluationPageType.submitted:
        return '提交成功';
      case EvaluationPageType.sessionExpired:
        return '会话已过期';
      case EvaluationPageType.accessDenied:
        return '访问受限';
      case EvaluationPageType.unknown:
        return '未知页面';
    }
  }

  /// Actionable hint for the user based on page type.
  static String? hint(EvaluationPageType type) {
    switch (type) {
      case EvaluationPageType.login:
        return '请在官方教务页面中登录。';
      case EvaluationPageType.courseList:
        return '请先在网页中选择一门待评价课程。';
      case EvaluationPageType.evaluationForm:
        return '可以点击"一键填写"自动选择最优评价。';
      case EvaluationPageType.submitted:
        return '当前课程可能已完成评价，无需重复填写。';
      case EvaluationPageType.sessionExpired:
        return '会话已过期，请重新登录。';
      case EvaluationPageType.accessDenied:
        return '当前无权限访问此页面。';
      case EvaluationPageType.unknown:
        return '页面结构无法识别，请确认已进入评价页面。';
      case EvaluationPageType.loading:
        return null;
    }
  }
}
