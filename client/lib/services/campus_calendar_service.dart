import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/campus_calendar.dart';

/// 校历读取服务：本地缓存优先，网络数据仅在校验通过后替换缓存。
class CampusCalendarService {
  CampusCalendarService(this._dio);

  static const _boxName = 'campus_calendar_cache';
  static const _currentCacheKey = 'current';
  static const _fallbackAsset = 'assets/data/campus_calendar_fallback.json';

  final Dio _dio;

  Future<CampusCalendar?> loadCached() async {
    final box = await Hive.openBox<String>(_boxName);
    final value = box.get(_currentCacheKey);
    if (value == null || value.isEmpty) return null;
    return _decode(value);
  }

  Future<CampusCalendar> loadFallback() async {
    final raw = await rootBundle.loadString(_fallbackAsset);
    final calendar = _decode(raw);
    if (calendar == null) throw const FormatException('内置校历格式无效');
    return calendar;
  }

  Future<CampusCalendar?> fetchCurrent() async {
    final response = await _dio.get('/campus-calendars/current');
    if (response.statusCode != 200 || response.data is! Map) {
      throw const CampusCalendarServiceException('校历数据格式错误');
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    final payload = data['calendar'] ?? data['data'] ?? data;
    if (payload is! Map) return null;
    final calendar =
        CampusCalendar.fromJson(Map<String, dynamic>.from(payload));
    _validate(calendar);
    return calendar;
  }

  Future<void> saveCached(CampusCalendar calendar) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.put(_currentCacheKey, calendar.encode());
  }

  CampusCalendar? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final calendar =
          CampusCalendar.fromJson(Map<String, dynamic>.from(decoded));
      _validate(calendar);
      return calendar;
    } catch (_) {
      return null;
    }
  }

  void _validate(CampusCalendar calendar) {
    if (calendar.schemaVersion != 1 ||
        calendar.academicYear.isEmpty ||
        calendar.semesters.isEmpty) {
      throw const FormatException('校历缺少必要字段');
    }
    for (final semester in calendar.semesters) {
      if (semester.endDate.isBefore(semester.startDate)) {
        throw const FormatException('学期日期范围无效');
      }
      DateTime? previousEnd;
      for (final week in semester.teachingWeeks) {
        if (week.endDate.isBefore(week.startDate) ||
            (previousEnd != null && !week.startDate.isAfter(previousEnd))) {
          throw const FormatException('教学周日期范围重叠或无效');
        }
        previousEnd = week.endDate;
      }
    }
  }
}

class CampusCalendarServiceException implements Exception {
  final String message;
  const CampusCalendarServiceException(this.message);

  @override
  String toString() => message;
}
