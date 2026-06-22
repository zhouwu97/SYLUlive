import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:hive/hive.dart';
import 'dart:io';

void main() {
  group('ErkeCacheStore', () {
    late ErkeCacheStore store;

    setUpAll(() {
      final path = Directory.systemTemp.createTempSync('hive_test');
      Hive.init(path.path);
    });

    setUp(() async {
      store = ErkeCacheStore();
      await store.init();
      await store.clearAll();
    });

    tearDownAll(() async {
      await Hive.close();
    });

    test('saves and retrieves summary', () async {
      final summary = ErkeSummary(
        categoryA: 1.0,
        categoryB: 2.0,
        categoryC: 3.0,
        categoryD: 4.0,
        categoryE: 5.0,
        total: 15.0,
      );

      expect(store.getSummary(), isNull);
      await store.saveSummary(summary);

      final retrieved = store.getSummary();
      expect(retrieved, isNotNull);
      expect(retrieved!.total, 15.0);
    });

    test('saves and retrieves activities', () async {
      final activity = ErkeActivity(
        name: 'test',
        organizer: 'org',
        date: '2026',
        category: 'cat',
        role: 'role',
        participantCount: 10,
        score: 1.0,
      );

      expect(store.getActivities(), isNull);
      await store.saveActivities([activity]);

      final retrieved = store.getActivities();
      expect(retrieved, isNotNull);
      expect(retrieved!.length, 1);
      expect(retrieved.first.name, 'test');
    });
  });
}
