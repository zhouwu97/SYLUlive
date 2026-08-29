import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// CachedNetworkImage（公开图片）在 widget 测试中的全链路 mock。
///
/// flutter_cache_manager 初始化依赖 path_provider：缺省时 MissingPluginException
/// 会把加载链路卡死在文件系统层（错误与结果都不会到达组件）。网络层需要经
/// HttpOverrides 接管 dart:io HttpClient（package:http 经 openUrl 进入）。
///
/// 路由规则：
/// - `/uploads/` 下 path 含 `missing` → 404（模拟脏记录：数据库有记录但文件丢失）
/// - 其余 `/uploads/` → 200 + 1x1 透明 PNG
/// - 传入 [apiHandler] 时，非 `/uploads/` 请求转交该处理器（复用 Dio FakeAdapter
///   的接口 mock，否则 Dio 请求会落进图片 mock）
///
/// 结束前必须调用 [flushMockPublicImageTimers]：flutter_cache_manager 会在
/// 首次访问缓存后安排一次性计时器（10s 清理 + 3s 防抖保存），不冲刷会触发
/// "Timer is still pending" 断言。
typedef MockApiHandler = Future<ResponseBody> Function(RequestOptions options);

Directory? _tempRoot;
MockApiHandler? _apiHandler;

Future<void> installMockPublicImageHttp({MockApiHandler? apiHandler}) async {
  _apiHandler = apiHandler;
  _tempRoot = await Directory.systemTemp.createTemp('mock_public_image');
  final tmpDir = await Directory('${_tempRoot!.path}/tmp').create(recursive: true);
  final supportDir =
      await Directory('${_tempRoot!.path}/support').create(recursive: true);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' => tmpDir.path,
      _ => supportDir.path,
    },
  );
  HttpOverrides.global = _MockImageHttpOverrides();
}

void uninstallMockPublicImageHttp() {
  HttpOverrides.global = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null);
  _apiHandler = null;
  final root = _tempRoot;
  _tempRoot = null;
  root?.delete(recursive: true).ignore();
}

/// 驱动真实时间窗，让缓存管理器文件 IO 与网络请求在测试中实际完成。
Future<void> driveMockPublicImageLoads(
  WidgetTester tester, {
  int windows = 15,
}) async {
  for (var i = 0; i < windows; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
}

/// 冲刷缓存管理器的一次性计时器（覆盖 fake zone 与 real zone 两种调度来源）。
Future<void> flushMockPublicImageTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 12));
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 12)));
  await tester.pump(const Duration(seconds: 1));
}

const _transparentImage = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

class _MockImageHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _MockImageHttpClient();
}

class _MockImageHttpClient extends Fake implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Duration idleTimeout = Duration.zero;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _MockImageHttpRequest(url);

  @override
  void close({bool force = false}) {}
}

class _MockImageHttpRequest extends Fake implements HttpClientRequest {
  _MockImageHttpRequest(this.uri);

  @override
  final Uri uri;

  @override
  String get method => 'GET';

  @override
  bool persistentConnection = true;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = 0;

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<HttpClientResponse> close() async {
    final path = uri.path;
    if (path.startsWith('/uploads/')) {
      return path.contains('missing')
          ? _MockImageHttpResponse(404, const [],
              contentType: 'image/jpeg')
          : _MockImageHttpResponse(200, _transparentImage,
              contentType: 'image/png');
    }
    final apiHandler = _apiHandler;
    if (apiHandler != null) {
      final body = await apiHandler(
        RequestOptions(path: path, method: method),
      );
      final chunks = <int>[];
      await for (final chunk in body.stream) {
        chunks.addAll(chunk);
      }
      return _MockImageHttpResponse(
        body.statusCode,
        chunks,
        contentType: body.headers[Headers.contentTypeHeader]?.first,
      );
    }
    throw UnimplementedError(
        'mock_public_image_http: 未预期的非图片请求 $uri（如需 mock API，'
        '请传入 apiHandler）');
  }
}

class _MockHttpHeaders extends Fake implements HttpHeaders {
  _MockHttpHeaders([Map<String, List<String>>? values])
      : _values = values ?? const {};

  final Map<String, List<String>> _values;

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  String? value(String? name) {
    final values = _values[name?.toLowerCase()];
    return (values == null || values.isEmpty) ? null : values.first;
  }
}

class _MockImageHttpResponse extends Fake implements HttpClientResponse {
  _MockImageHttpResponse(this.statusCode, this.body, {this.contentType});

  @override
  final int statusCode;

  final List<int> body;

  final String? contentType;

  @override
  int get contentLength => body.length;

  @override
  HttpHeaders get headers => _MockHttpHeaders(contentType == null
      ? const {}
      : {
          'content-type': [contentType!],
        });

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  String get reasonPhrase => '';

  @override
  bool get persistentConnection => true;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return Stream<List<int>>.value(body).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
