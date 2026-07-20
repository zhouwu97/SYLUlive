import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/features/ai_runtime/ai_provider_storage.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/openai_tool_calling_model.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_call_models.dart';

void main() {
  test('只使用非流式 Tool Calling 并解析单一完整调用', () async {
    Map<String, dynamic>? requestPayload;
    final model = await _model((options) {
      requestPayload = Map<String, dynamic>.from(options.data as Map);
      return _response(
          options,
          _message(<String, dynamic>{
            'content': null,
            'tool_calls': <Object>[
              <String, dynamic>{
                'id': 'call-1',
                'function': <String, dynamic>{
                  'name': 'personal.academic.overview',
                  'arguments': '{}',
                },
              },
            ],
          }));
    });

    final turn = await model.nextTurn(
      messages: const <ToolConversationMessage>[
        ToolConversationMessage(role: ToolMessageRole.user, content: '成绩'),
      ],
      tools: <ToolDefinition>[
        ToolDefinition(
          id: 'personal.academic.overview',
          description: '测试',
          parameters: const <String, dynamic>{
            'type': 'object',
            'additionalProperties': false,
          },
        ),
      ],
    );

    expect(requestPayload?['stream'], isFalse);
    expect(turn.toolCall?.id, 'call-1');
    expect(turn.toolCall?.tool, 'personal.academic.overview');
  });

  test('拒绝文本与 Tool Call 混合、多调用及缺失 call id', () async {
    final invalidMessages = <Map<String, dynamic>>[
      <String, dynamic>{
        'content': '先泄露一段文本',
        'tool_calls': <Object>[
          _call('call-1'),
        ],
      },
      <String, dynamic>{
        'content': null,
        'tool_calls': <Object>[_call('call-1'), _call('call-2')],
      },
      <String, dynamic>{
        'content': null,
        'tool_calls': <Object>[_call('')],
      },
    ];

    for (final message in invalidMessages) {
      final model = await _model(
        (options) => _response(options, _message(message)),
      );
      await expectLater(
        model.nextTurn(
          messages: const <ToolConversationMessage>[
            ToolConversationMessage(
              role: ToolMessageRole.user,
              content: '测试',
            ),
          ],
          tools: const <ToolDefinition>[],
        ),
        throwsA(isA<Exception>()),
      );
    }
  });
}

Map<String, dynamic> _call(String id) => <String, dynamic>{
      'id': id,
      'function': <String, dynamic>{
        'name': 'personal.academic.overview',
        'arguments': '{}',
      },
    };

Map<String, dynamic> _message(Map<String, dynamic> message) =>
    <String, dynamic>{
      'choices': <Object>[
        <String, dynamic>{'message': message},
      ],
    };

Response<dynamic> _response(
  RequestOptions options,
  Map<String, dynamic> data,
) =>
    Response<dynamic>(
      requestOptions: options,
      statusCode: 200,
      data: data,
    );

Future<OpenAIToolCallingModel> _model(
  Response<dynamic> Function(RequestOptions options) response,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = AIProviderSettingsStore(
    appUserId: '10001',
    secureStore: _MemorySecureStore(),
  );
  await store.saveOpenAICompatible(
    endpoint: 'https://models.example.test/v1',
    model: 'tool-model',
    apiKey: 'test-key',
  );
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(response(options)),
    ),
  );
  return OpenAIToolCallingModel.create(settingsStore: store, dio: dio);
}

class _MemorySecureStore implements AIProviderSecureStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
