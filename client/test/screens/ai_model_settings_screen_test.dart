import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/features/ai_runtime/ai_model_provider.dart';
import 'package:shenliyuan/features/ai_runtime/ai_provider_storage.dart';
import 'package:shenliyuan/screens/ai/ai_model_settings_screen.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';

void main() {
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
    SharedPreferences.setMockInitialValues(<String, Object>{});
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

  testWidgets('校园公益旧配置会引导用户配置个人助手模型', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
