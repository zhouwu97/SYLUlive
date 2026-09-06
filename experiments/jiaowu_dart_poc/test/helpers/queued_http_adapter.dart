import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

final class QueuedHttpResponse {
  const QueuedHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, List<String>>{},
    this.bodyBytes,
    this.error,
  });

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;
  final Uint8List? bodyBytes;
  final Object? error;
}

final class QueuedHttpAdapter implements HttpClientAdapter {
  QueuedHttpAdapter(Iterable<QueuedHttpResponse> responses)
      : _responses = List<QueuedHttpResponse>.of(responses);

  final List<QueuedHttpResponse> _responses;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    requests.add(options);
    if (_responses.isEmpty) {
      throw StateError('没有为 ${options.method} ${options.path} 准备响应');
    }
    final response = _responses.removeAt(0);
    if (response.error != null) {
      throw response.error!;
    }
    return ResponseBody(
      Stream.value(
        response.bodyBytes ?? Uint8List.fromList(utf8.encode(response.body)),
      ),
      response.statusCode,
      headers: response.headers,
    );
  }
}

String requestHeader(RequestOptions options, String name) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return '${entry.value}';
    }
  }
  return '';
}
