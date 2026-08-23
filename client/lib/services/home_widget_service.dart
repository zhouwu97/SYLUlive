import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/home_widget_config.dart';
import '../providers/course_schedule_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


class HomeWidgetExamEntry {
  const HomeWidgetExamEntry({
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.location,
  });

  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final String location;
}

class HomeWidgetPreviewItem {
  const HomeWidgetPreviewItem({
    required this.title,
    required this.primaryDetail,
    this.secondaryDetail = '',
    this.badge = '',
    this.color = '#3B82F6',
  });

  final String title;
  final String primaryDetail;
  final String secondaryDetail;
  final String badge;
  final String color;
}

class HomeWidgetPreviewData {
  const HomeWidgetPreviewData({
    this.subtitle = '',
    this.items = const [],
  });

  final String subtitle;
  final List<HomeWidgetPreviewItem> items;
}

class HomeWidgetInstalledCounts {
  const HomeWidgetInstalledCounts({
    this.course2x2 = 0,
    this.course4x2 = 0,
    this.exam2x2 = 0,
    this.exam4x2 = 0,
  });

  final int course2x2;
  final int course4x2;
  final int exam2x2;
  final int exam4x2;

  int totalFor(HomeWidgetKind kind) => switch (kind) {
        HomeWidgetKind.course => course2x2 + course4x2,
        HomeWidgetKind.exam => exam2x2 + exam4x2,
      };

  int countFor(HomeWidgetKind kind, HomeWidgetSize size) =>
      switch ((kind, size)) {
        (HomeWidgetKind.course, HomeWidgetSize.size2x2) => course2x2,
        (HomeWidgetKind.course, HomeWidgetSize.size4x2) => course4x2,
        (HomeWidgetKind.exam, HomeWidgetSize.size2x2) => exam2x2,
        (HomeWidgetKind.exam, HomeWidgetSize.size4x2) => exam4x2,
      };

  factory HomeWidgetInstalledCounts.fromMap(Map<Object?, Object?> map) {
    int read(String key) => (map[key] as num?)?.toInt() ?? 0;
    return HomeWidgetInstalledCounts(
      course2x2: read('course2x2'),
      course4x2: read('course4x2'),
      exam2x2: read('exam2x2'),
      exam4x2: read('exam4x2'),
    );
  }
}

enum HomeWidgetPinStatus { requested, unsupported, rejected, failed }

class HomeWidgetPinResult {
  const HomeWidgetPinResult(this.status, {this.message});

  final HomeWidgetPinStatus status;
  final String? message;

  bool get requestSent => status == HomeWidgetPinStatus.requested;
}

/// Flutter 与 Android RemoteViews / iOS WidgetKit 之间唯一的数据同步入口。
class HomeWidgetService {
  HomeWidgetService._();

  static const _channel = MethodChannel('shenliyuan/widget');
  static const _courseDataKey = 'widget_course_data';
  static const _examDataKey = 'widget_exam_data';
  static const widgetSchemaVersion = 1;

  static CourseScheduleProvider? _lastCourseProvider;
  static List<HomeWidgetExamEntry>? _lastExamEntries;

  static Future<void> migrateLegacyAppearance() async {
    final prefs = await AppPreferencesStore.getInstance();
    final legacyTheme =
        prefs.containsKey(HomeWidgetPreferenceKeys.legacyTextColor)
            ? HomeWidgetTheme.fromLegacyTextColor(
                prefs.getString(HomeWidgetPreferenceKeys.legacyTextColor),
              )
            : HomeWidgetTheme.system;
    final legacyTitle = prefs.getString(HomeWidgetPreferenceKeys.legacyTitle);

    for (final kind in HomeWidgetKind.values) {
      final themeKey = HomeWidgetPreferenceKeys.theme(kind);
      final titleKey = HomeWidgetPreferenceKeys.title(kind);
      if (!prefs.containsKey(themeKey)) {
        await prefs.setString(themeKey, legacyTheme.storageName);
      }
      if (!prefs.containsKey(titleKey)) {
        final title = legacyTitle?.trim();
        await prefs.setString(
          titleKey,
          title == null || title.isEmpty ? kind.defaultTitle : title,
        );
      }
    }
  }

  static Future<HomeWidgetAppearance> getAppearance(
    HomeWidgetKind kind,
  ) async {
    await migrateLegacyAppearance();
    final prefs = await AppPreferencesStore.getInstance();
    return HomeWidgetAppearance(
      kind: kind,
      theme: HomeWidgetTheme.fromStorage(
        prefs.getString(HomeWidgetPreferenceKeys.theme(kind)),
      ),
      title: prefs.getString(HomeWidgetPreferenceKeys.title(kind)) ??
          kind.defaultTitle,
    );
  }

  static Future<void> updateAppearance(HomeWidgetAppearance appearance) async {
    await migrateLegacyAppearance();
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString(
      HomeWidgetPreferenceKeys.theme(appearance.kind),
      appearance.theme.storageName,
    );
    await prefs.setString(
      HomeWidgetPreferenceKeys.title(appearance.kind),
      appearance.title.trim().isEmpty
          ? appearance.kind.defaultTitle
          : appearance.title.trim(),
    );
    await _refreshNative();
  }

  static Future<void> syncCourseData(CourseScheduleProvider provider) async {
    _lastCourseProvider = provider;
    try {
      final now = DateTime.now();
      final weekday = now.weekday;
      final academicWeek = provider.getAcademicWeek(now);
      final weekName = ['', '一', '二', '三', '四', '五', '六', '日'][weekday];
      final weekText = academicWeek == null ? '' : '第$academicWeek周';
      final date = '${now.month}.${now.day} $weekText 周$weekName';

      final todayCourses = provider.courses.where((course) {
        if (course.weekday != weekday) return false;
        return academicWeek == null ||
            provider.isCourseActive(course, academicWeek);
      }).toList()
        ..sort((a, b) => a.startSection.compareTo(b.startSection));

      const starts = [
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
      const ends = [
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

      final courses = todayCourses.map((course) {
        final startIndex = (course.startSection - 1).clamp(0, 11);
        final endIndex = (course.endSection - 1).clamp(0, 11);
        return {
          'name': course.name,
          'time': '${starts[startIndex]}-${ends[endIndex]}',
          'location': course.location ?? '',
          'teacher': course.teacher ?? '',
          'color': course.color,
        };
      }).toList();

      final prefs = await AppPreferencesStore.getInstance();
      await prefs.setString(
        _courseDataKey,
        jsonEncode({
          'schema_version': widgetSchemaVersion,
          'updated_at': now.toIso8601String(),
          'title': '沈理院课表',
          'date': date,
          'courses': courses,
        }),
      );
      await _refreshNative();
      debugPrint('课表小组件已同步：${courses.length} 门课，日期 $date');
    } catch (error) {
      debugPrint('课表小组件同步失败：$error');
    }
  }

  static Future<void> syncExamData(
    Iterable<HomeWidgetExamEntry> entries,
  ) async {
    final cached = entries.toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    _lastExamEntries = cached;
    try {
      final now = DateTime.now();
      final exams =
          cached.where((exam) => exam.endTime.isAfter(now)).map((exam) {
        final date = _date(exam.startTime);
        return {
          'name': exam.name,
          'date': date,
          'time': '${_time(exam.startTime)}-${_time(exam.endTime)}',
          'location': exam.location.isEmpty ? '未指定' : exam.location,
          'countdown': _countdown(exam.startTime, now),
        };
      }).toList();

      final prefs = await AppPreferencesStore.getInstance();
      await prefs.setString(
        _examDataKey,
        jsonEncode({
          'schema_version': widgetSchemaVersion,
          'updated_at': now.toIso8601String(),
          'exams': exams,
        }),
      );
      await _refreshNative();
      debugPrint('考试小组件已同步：${exams.length} 场考试');
    } catch (error) {
      debugPrint('考试小组件同步失败：$error');
    }
  }

  static Future<void> syncKind(HomeWidgetKind kind) async {
    switch (kind) {
      case HomeWidgetKind.course:
        final provider = _lastCourseProvider;
        if (provider != null) return syncCourseData(provider);
        break;
      case HomeWidgetKind.exam:
        final exams = _lastExamEntries;
        if (exams != null) return syncExamData(exams);
        break;
    }
    await _refreshNative();
  }

  static Future<void> syncAll() async {
    final course = _lastCourseProvider;
    final exams = _lastExamEntries;
    if (course != null) await syncCourseData(course);
    if (exams != null) await syncExamData(exams);
    if (course == null && exams == null) await _refreshNative();
  }

  static Future<HomeWidgetPinResult> requestPinWidget(
    HomeWidgetKind kind,
    HomeWidgetSize size,
  ) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'requestPinWidget',
        {'kind': kind.storageName, 'size': size.channelName},
      );
      final status = raw?['status']?.toString();
      final message = raw?['message']?.toString();
      return HomeWidgetPinResult(
        switch (status) {
          'requested' => HomeWidgetPinStatus.requested,
          'unsupported' => HomeWidgetPinStatus.unsupported,
          'rejected' => HomeWidgetPinStatus.rejected,
          _ => HomeWidgetPinStatus.failed,
        },
        message: message,
      );
    } on MissingPluginException {
      return const HomeWidgetPinResult(HomeWidgetPinStatus.unsupported);
    } catch (error) {
      return HomeWidgetPinResult(
        HomeWidgetPinStatus.failed,
        message: error.toString(),
      );
    }
  }

  static Future<HomeWidgetInstalledCounts> getInstalledWidgetCounts() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getInstalledWidgetCounts',
      );
      return HomeWidgetInstalledCounts.fromMap(raw ?? const {});
    } catch (_) {
      return const HomeWidgetInstalledCounts();
    }
  }

  static Future<HomeWidgetPreviewData> getPreviewData(
    HomeWidgetKind kind,
  ) async {
    final prefs = await AppPreferencesStore.getInstance();
    try {
      if (kind == HomeWidgetKind.course) {
        final raw = prefs.getString(_courseDataKey);
        if (raw == null) return const HomeWidgetPreviewData();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final courses = (data['courses'] as List<dynamic>? ?? const []);
        return HomeWidgetPreviewData(
          subtitle: data['date']?.toString() ?? '',
          items: courses.map((item) {
            final course = item as Map<String, dynamic>;
            final location = course['location']?.toString() ?? '';
            final teacher = course['teacher']?.toString() ?? '';
            return HomeWidgetPreviewItem(
              title: course['name']?.toString() ?? '',
              primaryDetail: course['time']?.toString() ?? '',
              secondaryDetail: [location, teacher]
                  .where((value) => value.isNotEmpty)
                  .join(' · '),
              color: course['color']?.toString() ?? '#3B82F6',
            );
          }).toList(),
        );
      }

      final raw = prefs.getString(_examDataKey);
      if (raw == null) return const HomeWidgetPreviewData();
      final decoded = jsonDecode(raw);
      final exams = decoded is Map<String, dynamic>
          ? (decoded['exams'] as List<dynamic>? ?? const [])
          : decoded as List<dynamic>;
      return HomeWidgetPreviewData(
        items: exams.map((item) {
          final exam = item as Map<String, dynamic>;
          return HomeWidgetPreviewItem(
            title: exam['name']?.toString() ?? '',
            primaryDetail: [exam['date'], exam['time']]
                .where((value) => value?.toString().isNotEmpty ?? false)
                .join(' '),
            secondaryDetail: exam['location']?.toString() ?? '',
            badge: exam['countdown']?.toString() ?? '',
          );
        }).toList(),
      );
    } catch (error) {
      debugPrint('读取小组件预览失败：$error');
      return const HomeWidgetPreviewData();
    }
  }

  static Future<void> _refreshNative() async {
    try {
      final prefs = await AppPreferencesStore.getInstance();
      await _channel.invokeMethod<void>('updateWidget', {
        'course_data': prefs.getString(_courseDataKey),
        'exam_data': prefs.getString(_examDataKey),
      });
    } on MissingPluginException {
      // 桌面端和单元测试没有 Android 通道，数据仍会正常写入。
    } catch (error) {
      debugPrint('原生小组件刷新失败：$error');
    }
  }

  static String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  static String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  static String _countdown(DateTime examDateTime, DateTime now) {
    final examDate = DateTime(
      examDateTime.year,
      examDateTime.month,
      examDateTime.day,
    );
    final today = DateTime(now.year, now.month, now.day);
    final days = examDate.difference(today).inDays;
    return switch (days) {
      0 => '今天',
      1 => '明天',
      2 => '后天',
      < 0 => '已结束',
      _ => '$days天后',
    };
  }
}
