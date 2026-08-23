import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/ai_endpoint_policy.dart';
import 'package:shenliyuan/features/ai_runtime/ai_model_provider.dart';
import 'package:shenliyuan/features/ai_runtime/ai_model_runtime.dart';
import 'package:shenliyuan/features/ai_runtime/ai_provider_storage.dart';
import 'package:shenliyuan/features/ai_runtime/campus_public_provider.dart';
import 'package:shenliyuan/features/ai_runtime/openai_compatible_provider.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_conversation.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/models/ai_run.dart';
import 'package:shenliyuan/models/ai_run_event.dart';
import 'package:shenliyuan/models/agent_context.dart';
import 'package:shenliyuan/services/ai_assistant_service.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class _MemorySecureStore implements AppSecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FailingDeleteSecureStore extends _MemorySecureStore {
  @override
  Future<void> delete(String key) => Future<void>.error(StateError('删除失败'));
}

class _CampusServiceStub extends AiAssistantService {
  _CampusServiceStub({
    required this.events,
    required this.finalRun,
    this.eventStream,
  }) : super(Dio());

  final List<AiRunEvent> events;
  final AiRun finalRun;
  final Stream<AiRunEvent>? eventStream;
  int getRunCalls = 0;
  int cancelRunCalls = 0;

  @override
  Future<AiCapabilities> getCapabilities() async => const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 3, windowSeconds: 3600),
        maxMessageChars: 20,
      );

  @override
  Future<AiConversation> createConversation({String title = ''}) async =>
      const AiConversation(id: 'conversation-1', title: '新会话');

  @override
  Future<AiRunCreation> createRun({
    required String conversationId,
    required String clientRequestId,
    required String message,
    AgentLaunchContext? launchContext,
  }) async =>
      const AiRunCreation(
        run: AiRun(
          id: 'run-1',
          conversationId: 'conversation-1',
          state: 'running',
          lastEventSeq: 0,
        ),
        duplicate: false,
      );

  @override
  Stream<AiRunEvent> streamRunEvents(String runId, {int lastEventId = 0}) =>
      eventStream ?? Stream<AiRunEvent>.fromIterable(events);

  @override
  Future<AiRun> getRun(String runId) async {
    getRunCalls++;
    return finalRun;
  }

  @override
  Future<AiRun> cancelRun(String runId) async {
    cancelRunCalls++;
    return AiRun(
      id: runId,
      conversationId: 'conversation-1',
      state: 'cancelled',
      lastEventSeq: 0,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AIEndpointPolicy', () {
    test('只接受不带查询参数的 HTTPS 基础地址', () {
      expect(
        AIEndpointPolicy.parseBaseEndpoint('https://models.example.com/v1'),
        Uri.parse('https://models.example.com/v1/'),
      );
      expect(
        () =>
            AIEndpointPolicy.parseBaseEndpoint('http://models.example.com/v1'),
        throwsA(isA<AIModelProviderException>()),
      );
      expect(
        () => AIEndpointPolicy.parseBaseEndpoint(
            'https://models.example.com/v1?k=x'),
        throwsA(isA<AIModelProviderException>()),
      );
      expect(
        () => AIEndpointPolicy.parseBaseEndpoint(
            'https://models.example.com/v1/../other'),
        throwsA(isA<AIModelProviderException>()),
      );
    });

    test('DeepSeek 官方地址兼容历史 /v1 别名', () {
      final deepSeekBase =
          AIEndpointPolicy.parseBaseEndpoint('https://api.deepseek.com/v1');
      expect(
        AIEndpointPolicy.endpointFor(deepSeekBase, 'chat/completions'),
        Uri.parse('https://api.deepseek.com/chat/completions'),
      );
      expect(
        AIEndpointPolicy.endpointFor(
          Uri.parse('https://models.example.com/v1/'),
          'chat/completions',
        ),
        Uri.parse('https://models.example.com/v1/chat/completions'),
      );
    });

    test('带版本的 Anthropic 基础地址不会重复生成 /v1', () {
      expect(
        AIEndpointPolicy.versionedEndpointFor(
          Uri.parse('https://api.anthropic.com/'),
          version: 'v1',
          relativePath: 'messages',
        ),
        Uri.parse('https://api.anthropic.com/v1/messages'),
      );
      expect(
        AIEndpointPolicy.versionedEndpointFor(
          Uri.parse('https://api.anthropic.com/v1/'),
          version: 'v1',
          relativePath: 'messages',
        ),
        Uri.parse('https://api.anthropic.com/v1/messages'),
      );
    });

    test('重定向响应被拒绝，不允许自动跟随', () {
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/models'),
        statusCode: 308,
      );
      expect(
        () => AIEndpointPolicy.ensureDirectResponse(response),
        throwsA(isA<AIModelProviderException>()),
      );
    });

    test('直连请求只接受 2xx 与待检查的 3xx 状态', () {
      final options = AIEndpointPolicy.directRequestOptions(const {});
      expect(options.followRedirects, isFalse);
      expect(options.maxRedirects, 0);
      expect(options.validateStatus!(204), isTrue);
      expect(options.validateStatus!(302), isTrue);
      expect(options.validateStatus!(400), isFalse);
    });
  });

  test('模型配置和 API Key 均按账号与配置 ID 隔离', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final secureStore = _MemorySecureStore();
    final primaryStore = AIProviderSettingsStore(
      appUserId: '10001',
      providerConfigId: 'primary',
      secureStore: secureStore,
    );
    final otherUserStore = AIProviderSettingsStore(
      appUserId: '10002',
      providerConfigId: 'primary',
      secureStore: secureStore,
    );

    await primaryStore.saveOpenAICompatible(
      endpoint: 'https://models.example.com/v1',
      model: 'demo-chat',
      apiKey: 'secret-key',
    );

    final preferences = await AppPreferencesStore.getInstance();
    expect(
      preferences.getKeys().map(preferences.getString).whereType<String>(),
      isNot(contains('secret-key')),
    );
    expect(secureStore.values.values, contains('secret-key'));
    expect(
      secureStore.values.keys.every((key) =>
          key.startsWith('ai_provider_key/') &&
          !key.contains('10001') &&
          key.endsWith('/primary')),
      isTrue,
    );
    expect(
      (await primaryStore.readConfig())?.endpoint,
      'https://models.example.com/v1',
    );
    expect((await primaryStore.readConfig())?.id, 'primary');
    expect(await primaryStore.readApiKey(), 'secret-key');
    expect(await otherUserStore.readConfig(), isNull);
    expect(await otherUserStore.readApiKey(), isNull);

    await primaryStore.clear();
    expect(await primaryStore.readConfig(), isNull);
    expect(await primaryStore.readApiKey(), isNull);
    expect(secureStore.values, isEmpty);
  });

  test('未知 Provider 类型失败关闭，不回退到校园公益 AI', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemorySecureStore(),
    );
    await store.saveCampusPublic();
    final preferences = await AppPreferencesStore.getInstance();
    final configKey = preferences
        .getKeys()
        .singleWhere((key) => key.startsWith('ai_provider_config/'));
    await preferences.setString(
        configKey,
        jsonEncode(<String, String>{
          'provider_config_id': 'default',
          'kind': 'future_provider',
          'endpoint': 'https://models.example.com/v1',
          'model': 'test',
        }));

    await expectLater(
      store.readConfig(),
      throwsA(isA<AIModelProviderException>()),
    );
  });

  test('密钥删除失败时保留普通配置供用户重试清理', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final secureStore = _FailingDeleteSecureStore();
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: secureStore,
    );
    await store.saveOpenAICompatible(
      endpoint: 'https://models.example.com/v1',
      model: 'demo-chat',
      apiKey: 'secret-key',
    );

    await expectLater(store.clear(), throwsA(isA<StateError>()));

    expect((await store.readConfig())?.model, 'demo-chat');
    expect(await store.readApiKey(), 'secret-key');
  });

  group('CampusPublicProvider', () {
    test('SSE 意外结束时必须以 Run 最终状态确认答案', () async {
      final service = _CampusServiceStub(
        events: const <AiRunEvent>[
          AiRunEvent(type: AiRunEventType.delta, text: '不完整'),
        ],
        finalRun: const AiRun(
          id: 'run-1',
          conversationId: 'conversation-1',
          state: 'running',
          lastEventSeq: 1,
        ),
      );
      final provider = CampusPublicProvider(service);

      await expectLater(
        provider.complete(const <AIModelChatMessage>[
          AIModelChatMessage(
            role: AIModelMessageRole.user,
            content: '测试',
          ),
        ]),
        throwsA(isA<AIModelProviderException>()),
      );
      expect(service.getRunCalls, 1);
    });

    test('完成事件可直接返回已接收的完整 SSE 文本', () async {
      final service = _CampusServiceStub(
        events: const <AiRunEvent>[
          AiRunEvent(type: AiRunEventType.delta, text: '完整回答'),
          AiRunEvent(type: AiRunEventType.completed),
        ],
        finalRun: const AiRun(
          id: 'run-1',
          conversationId: 'conversation-1',
          state: 'completed',
          lastEventSeq: 2,
        ),
      );
      final provider = CampusPublicProvider(service);

      final result = await provider.complete(const <AIModelChatMessage>[
        AIModelChatMessage(
          role: AIModelMessageRole.user,
          content: '测试',
        ),
      ]);

      expect(result.content, '完整回答');
      expect(service.getRunCalls, 0);
    });

    test('取消当前公益 Run 会调用服务端取消接口', () async {
      final events = StreamController<AiRunEvent>();
      addTearDown(events.close);
      final service = _CampusServiceStub(
        events: const <AiRunEvent>[],
        eventStream: events.stream,
        finalRun: const AiRun(
          id: 'run-1',
          conversationId: 'conversation-1',
          state: 'running',
          lastEventSeq: 0,
        ),
      );
      final provider = CampusPublicProvider(service);

      final completion = provider.complete(const <AIModelChatMessage>[
        AIModelChatMessage(
          role: AIModelMessageRole.user,
          content: '测试',
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      final completionExpectation = expectLater(
        completion,
        throwsA(isA<AIModelProviderException>()),
      );

      await provider.cancelActiveRequest();
      expect(service.cancelRunCalls, 1);
      await events.close();
      await completionExpectation;
    });
  });

  group('OpenAICompatibleProvider', () {
    test('默认客户端设置连接、发送和接收超时', () {
      final dio = OpenAICompatibleProvider.createDio();
      expect(dio.options.connectTimeout, const Duration(seconds: 10));
      expect(dio.options.sendTimeout, const Duration(seconds: 15));
      expect(dio.options.receiveTimeout, const Duration(seconds: 60));
    });

    test('能力探测直连 /models，并保留 HTTPS 基础路径', () async {
      final dio = Dio();
      late RequestOptions request;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'data': <Map<String, String>>[
                <String, String>{'id': 'z-model'},
                <String, String>{'id': 'a-model'},
              ],
            },
          ));
        },
      ));
      final provider = OpenAICompatibleProvider(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://models.example.com/v1',
          model: 'a-model',
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      final capabilities = await provider.discoverCapabilities();

      expect(request.uri, Uri.parse('https://models.example.com/v1/models'));
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(request.headers['Authorization'], 'Bearer test-key');
      expect(capabilities.models, <String>['a-model', 'z-model']);
      expect(capabilities.chatAvailability, AIModelChatAvailability.unknown);
      expect(capabilities.supportsStreaming, isFalse);
      expect(capabilities.supportsToolCalling, isFalse);
      expect(capabilities.supportsStreamingToolCalling, isFalse);
    });

    test('普通聊天不发送工具参数，并读取标准文本响应', () async {
      final dio = Dio();
      late RequestOptions request;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'model': 'chat-model',
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, String>{'content': '普通回答'},
                },
              ],
            },
          ));
        },
      ));
      final provider = OpenAICompatibleProvider(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://models.example.com/v1/',
          model: 'chat-model',
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      final result = await provider.complete(const <AIModelChatMessage>[
        AIModelChatMessage(
          role: AIModelMessageRole.user,
          content: '你好',
        ),
      ]);

      final data = Map<String, dynamic>.from(request.data as Map);
      expect(request.uri.path, '/v1/chat/completions');
      expect(data['stream'], isFalse);
      expect(data['tools'], isEmpty);
      expect(data['messages'], <Map<String, String>>[
        <String, String>{'role': 'user', 'content': '你好'},
      ]);
      expect(result.content, '普通回答');
      expect(result.model, 'chat-model');
    });

    test('Claude 官方地址使用 Anthropic 模型列表端点和鉴权头', () async {
      final dio = Dio();
      late RequestOptions request;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'data': <Map<String, String>>[
                <String, String>{'id': 'claude-sonnet-4-5'},
              ],
            },
          ));
        },
      ));
      final provider = OpenAICompatibleProvider(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.anthropic.com/v1',
          model: 'claude-sonnet-4-5',
        ),
        apiKey: 'claude-key',
        dio: dio,
      );

      final capabilities = await provider.discoverCapabilities();

      expect(request.uri.path, '/v1/models');
      expect(request.headers['x-api-key'], 'claude-key');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(capabilities.models, <String>['claude-sonnet-4-5']);
    });

    test('Claude 普通聊天发送 Messages 请求并解析文本块', () async {
      final dio = Dio();
      late RequestOptions request;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'model': 'claude-sonnet-4-5',
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': 'Claude 回答'},
              ],
            },
          ));
        },
      ));
      final provider = OpenAICompatibleProvider(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.anthropic.com',
          model: 'claude-sonnet-4-5',
        ),
        apiKey: 'claude-key',
        dio: dio,
      );

      final result = await provider.complete(const <AIModelChatMessage>[
        AIModelChatMessage(
          role: AIModelMessageRole.user,
          content: '你好',
        ),
      ]);

      final data = Map<String, dynamic>.from(request.data as Map);
      expect(request.uri.path, '/v1/messages');
      expect(data['max_tokens'], 4096);
      expect(data.containsKey('tools'), isFalse);
      expect(data['messages'], <Map<String, String>>[
        <String, String>{'role': 'user', 'content': '你好'},
      ]);
      expect(result.content, 'Claude 回答');
      expect(result.model, 'claude-sonnet-4-5');
    });

    test('重定向响应不会继续请求目标地址', () async {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: 302,
          headers: Headers.fromMap(<String, List<String>>{
            'location': <String>['https://other.example.com/v1/models'],
          }),
        )),
      ));
      final provider = OpenAICompatibleProvider(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://models.example.com/v1',
          model: 'chat-model',
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      await expectLater(
        provider.discoverCapabilities(),
        throwsA(isA<AIModelProviderException>()),
      );
    });

    test('取消当前请求会取消绑定的 CancelToken', () async {
      final dio = Dio();
      final requestSeen = Completer<CancelToken>();
      final continueRequest = Completer<void>();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) async {
          requestSeen.complete(options.cancelToken!);
          await continueRequest.future;
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{'data': <Object>[]},
          ));
        },
      ));
      final provider = OpenAICompatibleProvider(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://models.example.com/v1',
          model: 'chat-model',
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      final discovery = provider.discoverCapabilities();
      final token = await requestSeen.future;
      await provider.cancelActiveRequest();
      expect(token.isCancelled, isTrue);
      continueRequest.complete();

      await expectLater(
        discovery,
        throwsA(isA<AIModelProviderException>()),
      );
    });
  });

  test('聊天控制器关闭上下文时取消公益 Run 并限制内存历史', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    final store = AIProviderSettingsStore(
      appUserId: '10001',
      secureStore: _MemorySecureStore(),
    );
    await store.saveCampusPublic();
    final events = StreamController<AiRunEvent>();
    addTearDown(events.close);
    final service = _CampusServiceStub(
      events: const <AiRunEvent>[],
      eventStream: events.stream,
      finalRun: const AiRun(
        id: 'run-1',
        conversationId: 'conversation-1',
        state: 'running',
        lastEventSeq: 0,
      ),
    );
    final controller = AIModelChatController(
      settingsStore: store,
      providerFactory: AIModelProviderFactory(
        settingsStore: store,
        campusService: service,
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final send = controller.send('测试');
    await Future<void>.delayed(Duration.zero);
    final close = controller.closeAccountContext();
    expect(controller.messages, isEmpty);
    expect(controller.sending, isFalse);
    await close;
    expect(service.cancelRunCalls, 1);
    await events.close();
    await send;

    final completedService = _CampusServiceStub(
      events: const <AiRunEvent>[
        AiRunEvent(type: AiRunEventType.delta, text: '答'),
        AiRunEvent(type: AiRunEventType.completed),
      ],
      finalRun: const AiRun(
        id: 'run-1',
        conversationId: 'conversation-1',
        state: 'completed',
        lastEventSeq: 2,
      ),
    );
    final boundedController = AIModelChatController(
      settingsStore: store,
      providerFactory: AIModelProviderFactory(
        settingsStore: store,
        campusService: completedService,
      ),
    );
    addTearDown(boundedController.dispose);
    await boundedController.load();
    final longMessage = List<String>.filled(8000, 'x').join();
    for (var index = 0; index < 6; index++) {
      await boundedController.send(longMessage);
    }

    expect(boundedController.messages.length, lessThanOrEqualTo(20));
    expect(
      boundedController.messages
          .fold<int>(0, (sum, message) => sum + message.content.length),
      lessThanOrEqualTo(40000),
    );
  });
}
