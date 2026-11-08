import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/ai_model_provider.dart';
import 'package:shenliyuan/features/ai_runtime/ai_provider_storage.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/ai/ai_model_settings_screen.dart';
import 'package:shenliyuan/widgets/app_page_app_bar.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('模型操作保持透明，校验错误仍有底面 dark=$dark scale=$scale', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        AppPreferencesStore.setMockInitialValues({});
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(.75);
        final store = AIProviderSettingsStore(
            appUserId: 'fixture', secureStore: _MemoryProviderSecureStore());
        var probeCalls = 0;
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(scale),
              home: AIModelSettingsScreen(
                  appUserId: 'fixture',
                  settingsStore: store,
                  toolCallingProbe: (_, __) async {
                    probeCalls++;
                  })),
        ));
        await tester.pumpAndSettle();
        expect(
            find.ancestor(
                of: find.text('个人助手模型'),
                matching: find.byType(AppContentSurface)),
            findsNothing);
        expect(
            find.ancestor(
                of: find.textContaining('个人 Skill 仅使用这里配置的第三方模型'),
                matching: find.byType(AppContentSurface)),
            findsOneWidget);
        await tester.ensureVisible(find.text('测试连接'));
        final discoveryRect = tester.getRect(find.text('查询模型'));
        final probeRect = tester.getRect(find.text('测试连接'));
        for (final glass in [true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          for (final label in ['查询模型', '测试连接']) {
            expect(
                find.ancestor(
                    of: find.text(label),
                    matching: find.byType(AppContentSurface)),
                findsNothing);
          }
          expect(tester.getRect(find.text('查询模型')), discoveryRect);
          expect(tester.getRect(find.text('测试连接')), probeRect);
        }
        await tester.tap(find.text('测试连接'));
        await tester.pumpAndSettle();
        const error = '请先查询并选择模型，或手动填写模型名称';
        expect(find.text(error), findsOneWidget);
        expect(
            find.ancestor(
                of: find.text(error), matching: find.byType(AppContentSurface)),
            findsOneWidget);
        expect(probeCalls, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('旧配置缺少 wire_api 时默认自动识别', () {
    final config = AIModelProviderConfig.fromJson(const <String, dynamic>{
      'provider_config_id': 'default',
      'kind': 'openai_compatible',
      'endpoint': 'https://api.example.com',
      'model': 'example-model',
    });

    expect(config.wireApi, OpenAIWireApi.auto);
  });

  test('保存后会持久化所选请求协议', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemoryProviderSecureStore(),
    );
    await store.saveOpenAICompatible(
      endpoint: 'https://api.example.com',
      model: 'example-model',
      wireApi: OpenAIWireApi.responses,
      apiKey: 'secret',
    );

    expect((await store.readConfig())?.wireApi, OpenAIWireApi.responses);
  });

  test('Anthropic Messages 配置可兼容读取并持久化', () async {
    final legacy = AIModelProviderConfig.fromJson(const <String, dynamic>{
      'provider_config_id': 'default',
      'kind': 'openai_compatible',
      'endpoint': 'https://api.anthropic.com',
      'model': 'claude-sonnet-4-5',
      'wire_api': 'messages',
    });
    expect(legacy.wireApi, OpenAIWireApi.anthropicMessages);
    expect(legacy.toJson()['wire_api'], 'anthropic_messages');

    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemoryProviderSecureStore(),
    );
    await store.saveOpenAICompatible(
      endpoint: 'https://api.anthropic.com',
      model: 'claude-sonnet-4-5',
      wireApi: OpenAIWireApi.anthropicMessages,
      apiKey: 'secret',
    );
    expect(
      (await store.readConfig())?.wireApi,
      OpenAIWireApi.anthropicMessages,
    );
  });

  testWidgets('校园公益旧配置会引导用户配置个人助手模型', (tester) async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemoryProviderSecureStore(),
    );
    await store.saveCampusPublic();

    await tester.pumpWidget(
      MaterialApp(
        home: AIModelSettingsScreen(
          appUserId: '10001',
          settingsStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('个人助手模型'), findsOneWidget);
    expect(find.textContaining('不能执行个人 Skill'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<AIModelProviderKind>),
        findsNothing);
    expect(find.widgetWithText(TextField, 'HTTPS 服务地址'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'API Key'), findsOneWidget);
    expect(find.widgetWithText(TextField, '模型名称'), findsOneWidget);
  });

  testWidgets('查询模型与连接测试是两个独立动作', (tester) async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemoryProviderSecureStore(),
    );
    var discoveryCount = 0;
    var probeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AIModelSettingsScreen(
          appUserId: '10001',
          settingsStore: store,
          modelDiscovery: (config, apiKey) async {
            discoveryCount++;
            return const AIModelCapabilities(
              chatAvailability: AIModelChatAvailability.unknown,
              models: <String>['model-a', 'model-b'],
            );
          },
          toolCallingProbe: (config, apiKey) async {
            probeCount++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppPageAppBar), findsOneWidget);
    expect(find.text('查询模型'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'HTTPS 服务地址'),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'API Key'),
      'secret',
    );
    await tester.ensureVisible(find.text('查询模型'));
    await tester.tap(find.text('查询模型'));
    await tester.pumpAndSettle();

    expect(discoveryCount, 1);
    expect(probeCount, 0);
    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('model-a'), findsOneWidget);

    await tester.tap(find.text('model-a'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(discoveryCount, 1);
    expect(probeCount, 1);
    expect(find.text('连接成功，Tool Calling 验证通过'), findsOneWidget);
    expect(find.text('选择模型'), findsNothing);
  });

  testWidgets('请求协议下拉框包含 Anthropic Messages', (tester) async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemoryProviderSecureStore(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AIModelSettingsScreen(
          appUserId: '10001',
          settingsStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dropdown = find.byType(DropdownButtonFormField<OpenAIWireApi>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    expect(find.text('Anthropic Messages'), findsOneWidget);
  });
}

class _MemoryProviderSecureStore implements AppSecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
