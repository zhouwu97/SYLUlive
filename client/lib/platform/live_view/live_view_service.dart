import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_platform.dart';

/// 鸿蒙实况窗能力的服务接口（计划阶段 9）。
///
/// 首版只做“下一节课”实况窗：
///   超过 60 分钟 → 不创建；
///   60 分钟内 → 即将上课；
///   已开始 → 上课中；
///   已结束 → 自动结束（计划 14.1）。
///
/// 去重唯一键（计划 14.3）：type + business_id + start_time。
/// 重复同步只允许更新现有实况窗，不允许重复创建。
abstract class LiveViewService {
  AppPlatform get platform;
  bool get isSupported;

  /// 发布或更新一个实况窗。
  ///
  /// - [businessId] 业务唯一 ID（例：课表的 lessonId）。
  /// - [type] 实况窗类型，用于去重与系统侧展示区分（例：`next_class` / `exam` / `competition`）。
  /// - [title] 展示标题。
  /// - [body] 展示正文。
  /// - [startTime] / [endTime] 业务起止时间，鸿蒙侧据此判断“即将/进行中/结束”。
  /// - [extraJson] 平台自定义扩展字段；上层负责扫除敏感信息（计划 17.4）。
  Future<void> publish({
    required String type,
    required String businessId,
    required String title,
    required String body,
    required DateTime startTime,
    required DateTime endTime,
    String? extraJson,
  });

  /// 按阶段 9 状态机同步“下一节课”实况窗。
  ///
  /// [course] 为 null、课程已结束或距离开始超过 60 分钟时不创建；若已有旧课程
  /// 实况窗则结束旧实例。到达开始和结束时间时会分别更新状态和结束实例。
  Future<void> syncCourse(
    CourseLiveViewData? course, {
    DateTime? now,
  });

  /// 主动结束一个实况窗（课程结束 / 考试取消 / 切换用户等）。
  Future<void> end({
    required String type,
    required String businessId,
  });

  /// 清空所有实况窗（退出账号 / 切换用户，计划 14.4）。
  Future<void> clearAll();

  Future<void> dispose();
}

/// 基于 Flutter OHOS MethodChannel 的实况窗实现。
///
/// 原生侧负责调用 Live View Kit，Flutter 侧只传递已经脱敏的业务快照。
class OhosLiveViewService implements LiveViewService {
  OhosLiveViewService({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.sylulive.harmony/live_view');

  final MethodChannel _channel;
  final Set<String> _startedKeys = <String>{};
  CourseLiveViewData? _activeCourse;
  Timer? _courseStartTimer;
  Timer? _courseEndTimer;

  @override
  AppPlatform get platform => AppPlatform.ohos;

  @override
  bool get isSupported => true;

  @override
  Future<void> publish({
    required String type,
    required String businessId,
    required String title,
    required String body,
    required DateTime startTime,
    required DateTime endTime,
    String? extraJson,
  }) async {
    final key = '$type:$businessId';
    final isCourse = type == 'course' || type == 'next_class';
    final method = isCourse && _startedKeys.contains(key)
        ? 'updateCourseLiveView'
        : _startMethod(type);
    await _channel.invokeMethod<void>(method, {
      'dataJson': jsonEncode({
        'type': type,
        'businessId': businessId,
        'title': title,
        'body': body,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'route': _routeForType(type),
        'extraJson': extraJson,
      }),
    });
    _startedKeys.add(key);
  }

  @override
  Future<void> syncCourse(
    CourseLiveViewData? course, {
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    _cancelCourseTimers();

    final shouldPublish = course != null &&
        course.endTime.isAfter(current) &&
        course.startTime.difference(current) <= const Duration(minutes: 60);
    if (!shouldPublish) {
      await _endActiveCourse();
      return;
    }

    final next = course;
    final active = _activeCourse;
    if (active != null && active.businessId != next.businessId) {
      await end(type: 'course', businessId: active.businessId);
    }

    _activeCourse = next;
    await _publishCourse(next);
    _scheduleCourseTransitions(next, current);
  }

  @override
  Future<void> end({
    required String type,
    required String businessId,
  }) async {
    await _channel.invokeMethod<void>('endCourseLiveView', {
      'dataJson': jsonEncode({
        'type': type,
        'businessId': businessId,
        'title': '',
        'body': '',
      }),
    });
    _startedKeys.remove('$type:$businessId');
    if (type == 'course' || type == 'next_class') {
      if (_activeCourse?.businessId == businessId) {
        _activeCourse = null;
        _cancelCourseTimers();
      }
    }
  }

  @override
  Future<void> clearAll() async {
    _cancelCourseTimers();
    await _channel.invokeMethod<void>('clearAllLiveViews');
    _activeCourse = null;
    _startedKeys.clear();
  }

  @override
  Future<void> dispose() async {
    _cancelCourseTimers();
    _startedKeys.clear();
    _activeCourse = null;
  }

  Future<void> _publishCourse(CourseLiveViewData course) => publish(
        type: 'course',
        businessId: course.businessId,
        title: course.title,
        body: course.location,
        startTime: course.startTime,
        endTime: course.endTime,
      );

  Future<void> _endActiveCourse() async {
    final active = _activeCourse;
    if (active == null) {
      await _channel.invokeMethod<void>('endCourseLiveView', {
        'dataJson': jsonEncode({
          'type': 'course',
          'businessId': '',
          'title': '',
          'body': '',
        }),
      });
      return;
    }
    await end(type: 'course', businessId: active.businessId);
  }

  void _scheduleCourseTransitions(
    CourseLiveViewData course,
    DateTime now,
  ) {
    if (now.isBefore(course.startTime)) {
      _courseStartTimer = Timer(
        course.startTime.difference(now),
        () => _runTimerAction(() => _publishCourse(course)),
      );
    }
    _courseEndTimer = Timer(
      course.endTime.difference(now),
      () => _runTimerAction(
        () => end(type: 'course', businessId: course.businessId),
      ),
    );
  }

  void _runTimerAction(Future<void> Function() action) {
    unawaited(
      action().catchError((Object error, StackTrace stackTrace) {
        debugPrint('鸿蒙实况窗定时状态更新失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }),
    );
  }

  void _cancelCourseTimers() {
    _courseStartTimer?.cancel();
    _courseStartTimer = null;
    _courseEndTimer?.cancel();
    _courseEndTimer = null;
  }

  String _startMethod(String type) => switch (type) {
        'course' || 'next_class' => 'startCourseLiveView',
        'exam' => 'startExamLiveView',
        'competition' => 'startCompetitionDeadlineLiveView',
        _ => throw ArgumentError.value(type, 'type', '未知实况窗类型'),
      };

  String _routeForType(String type) => switch (type) {
        'course' || 'next_class' => 'campus://timetable',
        'exam' => 'sylulive://exams',
        'competition' => 'sylulive://competition/calendar',
        _ => 'sylulive://',
      };
}

/// 未对接平台的占位实现。鸿蒙 ArkTS 桥接验收通过后切换真实实现
/// （计划 14.5 末段将 `PlatformCapabilities.supportsLiveView` 置 true）。
class NoopLiveViewService implements LiveViewService {
  const NoopLiveViewService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<void> publish({
    required String type,
    required String businessId,
    required String title,
    required String body,
    required DateTime startTime,
    required DateTime endTime,
    String? extraJson,
  }) async {}

  @override
  Future<void> syncCourse(
    CourseLiveViewData? course, {
    DateTime? now,
  }) async {}

  @override
  Future<void> end({
    required String type,
    required String businessId,
  }) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> dispose() async {}
}

/// 课程实况窗的脱敏业务快照。
class CourseLiveViewData {
  const CourseLiveViewData({
    required this.businessId,
    required this.title,
    required this.location,
    required this.startTime,
    required this.endTime,
  });

  final String businessId;
  final String title;
  final String location;
  final DateTime startTime;
  final DateTime endTime;
}
