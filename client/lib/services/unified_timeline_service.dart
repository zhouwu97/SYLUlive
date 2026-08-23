import 'package:flutter/material.dart';

import '../models/campus_calendar.dart';
import '../models/campus_timeline.dart';
import '../models/exam_schedule.dart';
import '../models/user_calendar.dart';
import '../providers/course_schedule_provider.dart';

/// 将不同业务域转换成同一套时间语义。
///
/// 这个服务只做映射、去重和范围裁剪，不把官方事件复制进个人日历。
class UnifiedTimelineService {
  const UnifiedTimelineService();

  List<CampusTimelineItem> build({
    required DateTimeRange range,
    CampusCalendar? officialCalendar,
    List<CourseBlock> courses = const <CourseBlock>[],
    DateTime? semesterStart,
    int teachingWeek = 0,
    List<ExamModel> exams = const <ExamModel>[],
    List<CompetitionTimelineEntry> competitions =
        const <CompetitionTimelineEntry>[],
    List<UserCalendarEvent> personalEvents = const <UserCalendarEvent>[],
  }) {
    final items = <CampusTimelineItem>[
      ..._officialItems(officialCalendar, range),
      ..._courseItems(courses, semesterStart, teachingWeek, range),
      ..._examItems(exams, range),
      ..._competitionItems(competitions, range),
      ...personalEvents
          .where((event) => event.intersects(range))
          .map(_personalItem),
    ];
    items.sort((left, right) {
      final time = left.startAt.compareTo(right.startAt);
      return time != 0 ? time : left.title.compareTo(right.title);
    });
    return List<CampusTimelineItem>.unmodifiable(items);
  }

  List<CampusTimelineItem> _officialItems(
    CampusCalendar? calendar,
    DateTimeRange range,
  ) {
    if (calendar == null) return const <CampusTimelineItem>[];
    return calendar.events
        .map(
          (event) => CampusTimelineItem(
            type: CampusTimelineType.campusEvent,
            title: event.title,
            startAt: _dayStart(event.startDate),
            endAt: _dayEnd(event.endDate),
            allDay: true,
            location: '',
            sourceType: 'official_calendar',
            sourceId: event.id,
            importance: event.type == 'holiday' ? 'high' : 'normal',
            editable: false,
            sourceVersion: '${calendar.version}',
            description: event.description,
          ),
        )
        .where((item) => item.intersects(range))
        .toList(growable: false);
  }

  List<CampusTimelineItem> _courseItems(
    List<CourseBlock> courses,
    DateTime? semesterStart,
    int teachingWeek,
    DateTimeRange range,
  ) {
    if (semesterStart == null) return const <CampusTimelineItem>[];
    final items = <CampusTimelineItem>[];
    for (var day = _dayStart(range.start);
        day.isBefore(range.end);
        day = day.add(const Duration(days: 1))) {
      final week =
          teachingWeek > 0 ? teachingWeek : _weekFor(semesterStart, day);
      for (final course in courses) {
        if (course.weekday != day.weekday ||
            (course.weeks.isNotEmpty && !course.weeks.contains(week))) {
          continue;
        }
        final item = CampusTimelineItem(
          type: CampusTimelineType.course,
          title: course.name,
          startAt: _sectionStart(day, course.startSection),
          endAt: _sectionEnd(day, course.endSection),
          allDay: false,
          location: course.location ?? '',
          sourceType: 'schedule',
          sourceId: '${course.id}:$week',
          importance: 'normal',
          editable: course.id < 0,
          description: course.teacher ?? '',
        );
        if (item.intersects(range)) items.add(item);
      }
    }
    return items;
  }

  List<CampusTimelineItem> _examItems(
    List<ExamModel> exams,
    DateTimeRange range,
  ) =>
      exams
          .where((exam) =>
              exam.startTime.isBefore(range.end) &&
              exam.endTime.isAfter(range.start))
          .map(
            (exam) => CampusTimelineItem(
              type: CampusTimelineType.exam,
              title: exam.name,
              startAt: exam.startTime,
              endAt: exam.endTime,
              allDay: false,
              location: exam.location,
              sourceType: 'exam',
              sourceId: '${exam.startTime.toIso8601String()}:${exam.name}',
              importance: 'high',
              editable: true,
            ),
          )
          .toList(growable: false);

  List<CampusTimelineItem> _competitionItems(
    List<CompetitionTimelineEntry> competitions,
    DateTimeRange range,
  ) {
    final items = <CampusTimelineItem>[];
    for (final competition in competitions) {
      if (competition.registrationEnd != null) {
        final deadline = competition.registrationEnd!;
        final item = CampusTimelineItem(
          type: CampusTimelineType.competition,
          title: '${competition.title} · 报名截止',
          startAt: deadline,
          endAt: deadline.add(const Duration(minutes: 30)),
          allDay: false,
          location: '',
          sourceType: 'competition',
          sourceId: '${competition.eventId}:registration_end',
          importance: 'high',
          editable: false,
          sourceVersion: competition.version?.toString(),
        );
        if (item.intersects(range)) items.add(item);
      }
      if (competition.eventStart != null) {
        final start = competition.eventStart!;
        final end = competition.eventEnd ?? start.add(const Duration(hours: 2));
        final item = CampusTimelineItem(
          type: CampusTimelineType.competition,
          title: competition.title,
          startAt: start,
          endAt: end,
          allDay: false,
          location: competition.location,
          sourceType: 'competition',
          sourceId: '${competition.eventId}:event',
          importance: 'high',
          editable: false,
          sourceVersion: competition.version?.toString(),
        );
        if (item.intersects(range)) items.add(item);
      }
    }
    return items;
  }

  CampusTimelineItem _personalItem(UserCalendarEvent event) =>
      CampusTimelineItem(
        type: CampusTimelineType.personal,
        title: event.title,
        startAt: event.startAt.toLocal(),
        endAt: event.endAt.toLocal(),
        allDay: event.allDay,
        location: event.location,
        sourceType: event.sourceType,
        sourceId: '${event.id}',
        importance: 'normal',
        editable: true,
        sourceVersion: '${event.version}',
        description: event.description,
      );

  static DateTime _dayStart(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static DateTime _dayEnd(DateTime date) =>
      DateTime(date.year, date.month, date.day).add(const Duration(days: 1));

  static DateTime _mondayOf(DateTime date) =>
      DateTime(date.year, date.month, date.day)
          .subtract(Duration(days: date.weekday - 1));

  static int _weekFor(DateTime semesterStart, DateTime date) {
    final start = _mondayOf(semesterStart);
    return (date.difference(start).inDays ~/ 7) + 1;
  }

  static DateTime _sectionStart(DateTime day, int section) {
    const starts = <String>[
      '08:00',
      '08:55',
      '10:00',
      '10:55',
      '13:00',
      '13:55',
      '14:50',
      '15:45',
      '16:40',
      '17:35',
      '18:30',
      '19:25',
    ];
    return _at(day, starts[(section - 1).clamp(0, starts.length - 1)]);
  }

  static DateTime _sectionEnd(DateTime day, int section) {
    const ends = <String>[
      '08:45',
      '09:40',
      '10:45',
      '11:40',
      '13:45',
      '14:40',
      '15:35',
      '16:30',
      '17:25',
      '18:20',
      '19:15',
      '20:10',
    ];
    return _at(day, ends[(section - 1).clamp(0, ends.length - 1)]);
  }

  static DateTime _at(DateTime date, String time) {
    final parts = time.split(':');
    return DateTime(date.year, date.month, date.day, int.parse(parts[0]),
        int.parse(parts[1]));
  }
}

extension on UserCalendarEvent {
  bool intersects(DateTimeRange range) =>
      startAt.toLocal().isBefore(range.end) &&
      endAt.toLocal().isAfter(range.start);
}
