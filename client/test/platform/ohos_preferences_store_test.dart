import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> log;
  Map<dynamic, dynamic>? mockedGetAllResult;
  bool shouldThrowOnMethodCall = false;

  setUp(() {
    log = [];
    mockedGetAllResult = {};
    shouldThrowOnMethodCall = false;

    // Reset singletons for testing
    AppPreferencesStore.setMockInitialValues({});
    
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('shenliyuan/preferences'),
      (MethodCall methodCall) async {
        log.add(methodCall);
        if (shouldThrowOnMethodCall) {
          throw PlatformException(code: 'ERROR', message: 'Simulated error');
        }
        if (methodCall.method == 'getAll') {
          return mockedGetAllResult;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('shenliyuan/preferences'), null);
  });

  test('getAll successfully initializes cache', () async {
    mockedGetAllResult = {
      'test_string': 'value',
      'test_bool': true,
      'test_int': 42,
      'test_double': 3.14,
      'test_list': ['a', 'b'],
    };

    final store = OhosPreferencesStore();
    await store.init();

    expect(store.getString('test_string'), 'value');
    expect(store.getBool('test_bool'), isTrue);
    expect(store.getInt('test_int'), 42);
    expect(store.getDouble('test_double'), 3.14);
    expect(store.getStringList('test_list'), ['a', 'b']);
    expect(log.length, 1);
    expect(log.first.method, 'getAll');
  });

  test('init throws StateError if getAll returns null', () async {
    mockedGetAllResult = null;
    final store = OhosPreferencesStore();

    expect(() => store.init(), throwsStateError);
  });

  test('getInstance concurrency race condition protection', () async {
    // Override platform for test to trigger OHOS creation
    AppPlatforms.currentOverrides = AppPlatform.ohos;

    try {
      final futures = <Future<AppPreferencesStore>>[];
      for (int i = 0; i < 5; i++) {
        futures.add(AppPreferencesStore.getInstance());
      }
      
      final results = await Future.wait(futures);
      
      // All results should be the same instance
      final first = results.first;
      for (final result in results) {
        expect(identical(result, first), isTrue);
      }
      
      // getAll should only be called once
      expect(log.length, 1);
      expect(log.first.method, 'getAll');
    } finally {
      AppPlatforms.currentOverrides = null;
    }
  });

  test('method channel exception does not update cache', () async {
    mockedGetAllResult = {'test_key': 'old_value'};
    final store = OhosPreferencesStore();
    await store.init();

    shouldThrowOnMethodCall = true;

    final result = await store.setString('test_key', 'new_value');
    expect(result, isFalse);
    expect(store.getString('test_key'), 'old_value'); // Unchanged
    
    final resultInt = await store.setInt('new_int', 10);
    expect(resultInt, isFalse);
    expect(store.getInt('new_int'), isNull); // Was never set
    
    final resultRemove = await store.remove('test_key');
    expect(resultRemove, isFalse);
    expect(store.getString('test_key'), 'old_value'); // Still there
  });

  test('int/double type fallback and num casting', () async {
    mockedGetAllResult = {
      'double_as_int': 42.0, // Dart maps it as double sometimes
      'int_as_double': 100, // Dart maps it as int
    };
    final store = OhosPreferencesStore();
    await store.init();

    // getInt should gracefully cast 42.0 to 42
    expect(store.getInt('double_as_int'), 42);
    
    // getDouble should gracefully cast 100 to 100.0
    expect(store.getDouble('int_as_double'), 100.0);
  });

  test('getStringList returns a new copy', () async {
    mockedGetAllResult = {
      'my_list': ['a'],
    };
    final store = OhosPreferencesStore();
    await store.init();

    final list = store.getStringList('my_list');
    list?.add('b'); // Modify the returned list

    // Should not affect internal cache
    final list2 = store.getStringList('my_list');
    expect(list2, ['a']);
  });
}
