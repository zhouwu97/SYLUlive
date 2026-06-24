/// Pure-Dart page-type classifier using probe result + boolean text flags.
library;

import 'evaluation_models.dart';

/// Classifies a教务 evaluation page based on structured probe data.
class EvaluationPageDetector {
  const EvaluationPageDetector();

  EvaluationPageType classify(EvaluationProbeResult probe) {
    if (probe.error != null && probe.error!.isNotEmpty) {
      return EvaluationPageType.unknown;
    }

    // Use boolean flags from JS (full-body scan) — these are more reliable
    // than the truncated pageTextSample.

    // 1. Session expired
    if (probe.hasSessionExpiredText) {
      return EvaluationPageType.sessionExpired;
    }

    // 2. Access denied or maintenance
    if (probe.hasAccessDeniedText || probe.hasMaintenanceText) {
      return EvaluationPageType.accessDenied;
    }

    // 3. Submitted
    if (probe.hasSubmittedText) {
      return EvaluationPageType.submitted;
    }

    // 4. Login page
    if (probe.hasLoginForm) {
      return EvaluationPageType.login;
    }
    // CAS login text detection
    final title = probe.title.toLowerCase();
    if (title.contains('登录') && title.contains('认证')) {
      return EvaluationPageType.login;
    }

    // 5. Evaluation form — must satisfy ALL conditions:
    //    a) URL path contains /xspjgl/
    //    b) Multiple radio groups with ≥2 options each
    //    c) Not a course list page
    if (_isEvaluationFormPage(probe)) {
      return EvaluationPageType.evaluationForm;
    }

    // 6. Course list
    if (_isCourseList(probe)) {
      return EvaluationPageType.courseList;
    }

    // 7. Already evaluated — check both boolean flag and text sample
    if (probe.hasAlreadyEvaluatedText) {
      return EvaluationPageType.submitted;
    }
    final body = probe.pageTextSample.toLowerCase();
    if (body.contains('已评价') || body.contains('已完成')) {
      return EvaluationPageType.submitted;
    }

    // 8. Fallback: login-related text
    if (body.contains('统一身份认证')) {
      return EvaluationPageType.login;
    }

    return EvaluationPageType.unknown;
  }

  /// Strict evaluation form detection.
  /// Requires: /xspjgl/ in URL path AND multiple radio groups (≥2 options each).
  bool _isEvaluationFormPage(EvaluationProbeResult probe) {
    // Must have /xspjgl/ in URL path
    if (!probe.url.contains('/xspjgl/')) return false;

    // Must have multiple radio groups where each group has ≥ 2 options
    final groups = probe.radioGroups;
    if (groups.length < 3) return false;
    final multiOptionGroups = groups.where((g) => g.options.length >= 2).length;
    if (multiOptionGroups < 3) return false;

    // Must not be a course list page
    if (_isCourseList(probe)) return false;

    // Must have evaluation form OR enough context
    if (probe.hasEvaluationForm) return true;

    // At least have evaluation-related buttons or forms
    return groups.length >= 5;
  }

  bool _isCourseList(EvaluationProbeResult probe) {
    // Multiple course rows with few radios → list page
    if (probe.possibleCourseRows.length >= 2 && probe.radioCount < 5) {
      return true;
    }

    // URL contains index/list pattern
    if (probe.url.contains('xspjIndex') || probe.url.contains('xspj_cx')) {
      // Unless we have many radio groups (actual evaluation form)
      if (probe.radioGroups.length < 3) return true;
    }

    return false;
  }

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
