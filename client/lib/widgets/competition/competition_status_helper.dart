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
  bool isDark, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final pendingColor = CompetitionUiTokens.pendingColor(isDark);
  // 参考日程不能作为当届报名状态，比赛开始也不等于比赛结束。
  if (event.timeStatus == 'historical') {
    return CompetitionStatusView('往年参考', pendingColor);
  }
  if (event.timeStatus == 'estimated') {
    return CompetitionStatusView('预计时间', pendingColor);
  }
  if (event.eventEnd != null && current.isAfter(event.eventEnd!)) {
    return CompetitionStatusView(
        '比赛已结束', CompetitionUiTokens.archivedColor(isDark));
  }
  if (event.registrationStart != null &&
      current.isBefore(event.registrationStart!)) {
    return CompetitionStatusView('报名未开始', pendingColor);
  }
  if (event.registrationEnd != null) {
    final regEnd = event.registrationEnd!;
    if (current.isAfter(regEnd)) {
      return CompetitionStatusView(
        '报名已截止',
        CompetitionUiTokens.archivedColor(isDark),
      );
    }

    final daysLeft = regEnd.difference(current).inDays;
    if (daysLeft <= 3 && daysLeft >= 0) {
      return CompetitionStatusView(
        '即将截止',
        CompetitionUiTokens.upcomingColor(isDark),
      );
    }

    return CompetitionStatusView(
      event.registrationStart == null ? '报名截止已确认' : '报名中',
      CompetitionUiTokens.warningColor(isDark),
    );
  }

  if (event.eventStart != null) {
    final evStart = event.eventStart!;
    if (!current.isBefore(evStart)) {
      return CompetitionStatusView(
        event.eventEnd == null ? '比赛已开始' : '比赛进行中',
        CompetitionUiTokens.warningColor(isDark),
      );
    }
    return CompetitionStatusView(
      '比赛未开始',
      pendingColor,
    );
  }

  if (event.timeStatus == 'confirmed' &&
      event.registrationTimeText.trim().isNotEmpty) {
    return CompetitionStatusView('报名安排已核实', pendingColor);
  }
  return CompetitionStatusView('报名时间待核实', pendingColor);
}

// 国内赛事统一显示北京时间，避免 UTC 响应在设备上显示成前一天。
String competitionDateText(DateTime value) {
  final date = value.isUtc ? value.add(const Duration(hours: 8)) : value;
  String two(int value) => value.toString().padLeft(2, '0');
  final day = '${date.year}-${two(date.month)}-${two(date.day)}';
  return date.hour == 0 && date.minute == 0
      ? day
      : '$day ${two(date.hour)}:${two(date.minute)}';
}

String _qualifiedTime(CompetitionEvent event, String value) {
  if (event.timeStatus == 'historical') return '往年参考：$value';
  if (event.timeStatus == 'estimated') return '预计：$value';
  return value;
}

String competitionRegistrationText(CompetitionEvent event) {
  // 人工核验文本保留校内/全国、赛道等范围，不用单个日期覆盖这些限定。
  final text = event.registrationTimeText.trim();
  if (text.isNotEmpty) return _qualifiedTime(event, text);
  final start = event.registrationStart;
  final end = event.registrationEnd;
  if (start != null && end != null) {
    return _qualifiedTime(
        event, '${competitionDateText(start)} 至 ${competitionDateText(end)}');
  }
  if (end != null) {
    return _qualifiedTime(event, '截止 ${competitionDateText(end)}');
  }
  if (start != null) {
    return _qualifiedTime(event, '${competitionDateText(start)} 开始，截止时间待核实');
  }
  return '报名时间待核实';
}

String competitionEventTimeText(CompetitionEvent event) {
  final text = event.eventTimeText.trim();
  if (text.isNotEmpty) return _qualifiedTime(event, text);
  final start = event.eventStart;
  final end = event.eventEnd;
  if (start != null && end != null) {
    return _qualifiedTime(
        event, '${competitionDateText(start)} 至 ${competitionDateText(end)}');
  }
  if (start != null) {
    return _qualifiedTime(event, '${competitionDateText(start)} 开始');
  }
  if (end != null) {
    return _qualifiedTime(event, '${competitionDateText(end)} 结束');
  }
  return '比赛时间待核实';
}

String? getCompetitionCriticalTime(CompetitionEvent event) {
  final registration = competitionRegistrationText(event);
  return registration == '报名时间待核实' ? registration : '报名安排：$registration';
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
