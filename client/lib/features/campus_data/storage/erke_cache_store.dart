import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';

class ErkeCacheStore {
  static const _boxName = 'erke_cache_box';
  static const _keySummary = 'summary';
  static const _keyActivities = 'activities';

  static const _keySnapshot = 'snapshot';

  /// Initializes the Hive box (must be called after Hive.init)
  Future<void> init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox<String>(_boxName);
    }
  }

  /// Saves both summary and activities atomically in a single snapshot.
  Future<void> saveSnapshot(
    ErkeSummary summary,
    List<ErkeActivity> activities,
  ) async {
    final box = Hive.box<String>(_boxName);
    await box.put(
      _keySnapshot,
      jsonEncode({
        'summary': summary.toJson(),
        'activities': activities.map((e) => e.toJson()).toList(),
      }),
    );
  }

  /// Retrieves the cached ErkeSummary, if any.
  ErkeSummary? getSummary() {
    final box = Hive.box<String>(_boxName);
    final snapshotData = box.get(_keySnapshot);
    if (snapshotData != null) {
      try {
        final map = jsonDecode(snapshotData) as Map<String, dynamic>;
        if (map['summary'] != null) {
          return ErkeSummary.fromJson(map['summary'] as Map<String, dynamic>);
        }
      } catch (_) {}
    }
    
    // Fallback to legacy key
    final data = box.get(_keySummary);
    if (data == null) return null;
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      return ErkeSummary.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Retrieves the cached activities, if any.
  List<ErkeActivity>? getActivities() {
    final box = Hive.box<String>(_boxName);
    final snapshotData = box.get(_keySnapshot);
    if (snapshotData != null) {
      try {
        final map = jsonDecode(snapshotData) as Map<String, dynamic>;
        if (map['activities'] != null) {
          final list = map['activities'] as List<dynamic>;
          return list
              .map((e) => ErkeActivity.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }

    // Fallback to legacy key
    final data = box.get(_keyActivities);
    if (data == null) return null;
    try {
      final list = jsonDecode(data) as List<dynamic>;
      return list
          .map((e) => ErkeActivity.fromJson(e as Map<String, dynamic>))
          .toList();
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
