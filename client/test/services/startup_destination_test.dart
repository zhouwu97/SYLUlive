import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  group('StartupDestinationStore', () {
    test('新安装默认为 home', () {
      final prefs = MemoryPreferencesStore();
      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.home,
      );
    });

    test('旧 start_on_timetable=true 迁移为 timetable', () async {
      final prefs = MemoryPreferencesStore();
      await prefs.setBool(StartupDestinationStore.legacyKey, true);

      await StartupDestinationStore.migrateFromLegacy(prefs);

      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.timetable,
      );
    });

    test('旧 start_on_timetable=false 迁移为 home', () async {
      final prefs = MemoryPreferencesStore();
      await prefs.setBool(StartupDestinationStore.legacyKey, false);

      await StartupDestinationStore.migrateFromLegacy(prefs);

      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.home,
      );
    });

    test('新 key 已存在时不覆盖', () async {
      final prefs = MemoryPreferencesStore();
      await prefs.setBool(StartupDestinationStore.legacyKey, true);
      await prefs.setString(
        StartupDestinationStore.key,
        StartupDestinationMode.lastPage.name,
      );

      await StartupDestinationStore.migrateFromLegacy(prefs);

      // 应该保持 lastPage，不被旧 true 覆盖为 timetable
      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.lastPage,
      );
    });

    test('无旧 key 也无新 key 时不崩溃', () async {
      final prefs = MemoryPreferencesStore();
      await StartupDestinationStore.migrateFromLegacy(prefs);
      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.home,
      );
    });

    test('三种 mode 互斥存储', () async {
      final prefs = MemoryPreferencesStore();

      for (final mode in StartupDestinationMode.values) {
        await StartupDestinationStore.write(prefs, mode);
        expect(StartupDestinationStore.read(prefs), mode);
      }
    });

    test('write 后 read 返回相同值', () async {
      final prefs = MemoryPreferencesStore();

      await StartupDestinationStore.write(
        prefs,
        StartupDestinationMode.timetable,
      );
      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.timetable,
      );

      await StartupDestinationStore.write(
        prefs,
        StartupDestinationMode.lastPage,
      );
      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.lastPage,
      );
    });

    test('损坏的存储值回退到 home', () async {
      final prefs = MemoryPreferencesStore();
      await prefs.setString(StartupDestinationStore.key, 'invalid_mode');
      expect(
        StartupDestinationStore.read(prefs),
        StartupDestinationMode.home,
      );
    });
  });
}
