import 'package:flutter/material.dart';
import '../../models/competition.dart';
import 'competition_ui_tokens.dart';

class CompetitionStatusView {
  final String label;
  final Color color;

  const CompetitionStatusView(this.label, this.color);
}

CompetitionStatusView resolveCompetitionStatus(
  CompetitionEvent event,
  bool isDark,
) {
  final now = DateTime.now();

  // 1. Check registration end
  if (event.registrationEnd != null) {
    final regEnd = event.registrationEnd!;
    if (now.isAfter(regEnd)) {
      return CompetitionStatusView(
        '已结束',
        CompetitionUiTokens.archivedColor(isDark),
      );
    }

    final daysLeft = regEnd.difference(now).inDays;
    if (daysLeft <= 3 && daysLeft >= 0) {
      return CompetitionStatusView(
        '即将截止',
        CompetitionUiTokens.upcomingColor(isDark),
      );
    }

    return CompetitionStatusView(
      '报名中',
      CompetitionUiTokens.warningColor(isDark),
    );
  }

  // 2. Check event end (we only have eventStart in model, so we check if eventStart is passed)
  if (event.eventStart != null) {
    final evStart = event.eventStart!;
    if (now.isAfter(evStart)) {
      return CompetitionStatusView(
        '已结束',
        CompetitionUiTokens.archivedColor(isDark),
      );
    }
    return CompetitionStatusView(
      '比赛中',
      CompetitionUiTokens.warningColor(isDark),
    );
  }

  // 3. Fallbacks
  if (event.timeStatus == 'pending' || event.timeStatus == 'unknown') {
    return CompetitionStatusView(
      '时间待公布',
      CompetitionUiTokens.pendingColor(isDark),
    );
  }

  return CompetitionStatusView(
    '时间待确认',
    CompetitionUiTokens.pendingColor(isDark),
  );
}

String? getCompetitionCriticalTime(CompetitionEvent event) {
  if (event.registrationEnd != null) {
    final dt = event.registrationEnd!;
    return '报名截止：${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
  if (event.registrationTimeText.isNotEmpty) {
    return '报名安排：${event.registrationTimeText}';
  }
  if (event.eventStart != null) {
    final dt = event.eventStart!;
    return '比赛时间：${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
  if (event.eventTimeText.isNotEmpty) {
    return '比赛安排：${event.eventTimeText}';
  }
  return null;
}

String competitionSourceLabel(String? source) {
  switch (source) {
    case 'local_json':
      return '本地导入';
    case 'official':
    case 'school_catalog':
    case 'college_notice':
      return '官方比赛库';
    case 'manual':
    case 'admin_manual':
      return '手动创建';
    case 'share':
      return '分享导入';
    case 'ai_import':
      return 'AI导入';
    default:
      if (source == null || source.isEmpty) return '来源未知';
      return '其他来源';
  }
}

String competitionRecognitionLabel(String value) {
  switch (value) {
    case 'recognized':
      return '已认定';
    case 'not_recognized':
      return '未认定';
    case 'pending':
      return '待确认';
    case 'unknown':
      return '未知';
    default:
      return value.isEmpty ? '未知' : value;
  }
}

String competitionManualRatingShort(String level) {
  final value = level.trim();
  return value.isEmpty ? '' : '价值 $value';
}

String competitionManualRatingLabel(String level) {
  final value = level.trim();
  return value.isEmpty ? '未评级' : value;
}

String competitionSchoolRecognitionShort({
  required String status,
  required String grade,
}) {
  final normalizedStatus = status.trim();
  final normalizedGrade = grade.trim();

  switch (normalizedStatus) {
    case 'recognized':
      return normalizedGrade.isEmpty ? '校已认' : '校认 $normalizedGrade';
    case 'pending':
      return '校认待定';
    case 'not_recognized':
      return '校不认';
    case 'unknown':
      return '';
    default:
      return '';
  }
}

String competitionSchoolRecognitionLabel({
  required String status,
  required String grade,
}) {
  switch (status.trim()) {
    case 'recognized':
      return grade.trim().isEmpty ? '学校已认定' : '学校认定等级 ${grade.trim()}';
    case 'pending':
      return '学校认定待确认';
    case 'not_recognized':
      return '学校未认定';
    case 'unknown':
      return '';
    default:
      return '';
  }
}
