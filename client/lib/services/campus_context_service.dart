import 'package:flutter/material.dart';

import '../features/ai_runtime/deterministic/campus_availability_engine.dart';
import '../models/campus_calendar.dart';
import '../models/campus_timeline.dart';
import '../models/exam_schedule.dart';
import '../models/user_calendar.dart';
import '../providers/course_schedule_provider.dart';
import 'unified_timeline_service.dart';

class CampusContext {
  const CampusContext({
    required this.now,
    this.calendar,
    this.courses = const <CourseBlock>[],
    this.exams = const <ExamModel>[],
    this.competitions = const <CompetitionTimelineEntry>[],
    this.personalEvents = const <UserCalendarEvent>[],
  });

  final DateTime now;
  final CampusCalendar? calendar;
  final List<CourseBlock> courses;
  final List<ExamModel> exams;
  final List<CompetitionTimelineEntry> competitions;
  final List<UserCalendarEvent> personalEvents;

  List<CampusTimelineItem> timeline({
    required DateTimeRange range,
    DateTime? semesterStart,
    int teachingWeek = 0,
  }) =>
      const UnifiedTimelineService().build(
        range: range,
        officialCalendar: calendar,
        courses: courses,
        semesterStart: semesterStart,
        teachingWeek: teachingWeek,
        exams: exams,
        competitions: competitions,
        personalEvents: personalEvents,
      );

  CampusLoadSummary load(
          {required DateTimeRange range,
          required List<CampusTimelineItem> items}) =>
      const CampusAvailabilityEngine()
          .calculateLoad(range: range, items: items);
}

/// Context service 的职责是拼接各 Provider 的事实快照；网络刷新仍由各域 Provider 自己负责。
class CampusContextService {
  const CampusContextService();

  CampusContext snapshot({
    DateTime? now,
    CampusCalendar? calendar,
    List<CourseBlock> courses = const <CourseBlock>[],
    List<ExamModel> exams = const <ExamModel>[],
    List<CompetitionTimelineEntry> competitions =
        const <CompetitionTimelineEntry>[],
    List<UserCalendarEvent> personalEvents = const <UserCalendarEvent>[],
  }) =>
      CampusContext(
        now: now ?? DateTime.now(),
        calendar: calendar,
        courses: List.unmodifiable(courses),
        exams: List.unmodifiable(exams),
        competitions: List.unmodifiable(competitions),
        personalEvents: List.unmodifiable(personalEvents),
      );
}
