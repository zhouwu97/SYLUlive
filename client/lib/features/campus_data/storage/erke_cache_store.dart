import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';

class ErkeCacheStore {
  static const _boxName = 'erke_cache_box';
  static const _keySummary = 'summary';
  static const _keyActivities = 'activities';

  /// Initializes the Hive box (must be called after Hive.init)
  Future<void> init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox<String>(_boxName);
    }
  }

  /// Saves the ErkeSummary.
  /// Converts to JSON string to avoid requiring Hive TypeAdapters, 
  /// ensuring we don't accidentally save complex objects incorrectly.
  Future<void> saveSummary(ErkeSummary summary) async {
    final box = Hive.box<String>(_boxName);
    await box.put(_keySummary, jsonEncode(summary.toJson()));
  }

  /// Retrieves the cached ErkeSummary, if any.
  ErkeSummary? getSummary() {
    final box = Hive.box<String>(_boxName);
    final data = box.get(_keySummary);
    if (data == null) return null;
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      return ErkeSummary.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Saves the list of ErkeActivity.
  Future<void> saveActivities(List<ErkeActivity> activities) async {
    final box = Hive.box<String>(_boxName);
    final list = activities.map((a) => a.toJson()).toList();
    await box.put(_keyActivities, jsonEncode(list));
  }

  /// Retrieves the cached activities, if any.
  List<ErkeActivity>? getActivities() {
    final box = Hive.box<String>(_boxName);
    final data = box.get(_keyActivities);
    if (data == null) return null;
    try {
      final list = jsonDecode(data) as List<dynamic>;
      return list.map((e) => ErkeActivity.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  /// Clears all cached Erke data.
  Future<void> clearAll() async {
    final box = Hive.box<String>(_boxName);
    await box.clear();
  }
}
