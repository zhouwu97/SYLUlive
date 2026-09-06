import 'dart:io';

import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

import '../helpers/queued_http_adapter.dart';

void main() {
  DioException error({
    required DioExceptionType type,
    Object? cause,
  }) {
    return DioException(
      requestOptions: RequestOptions(
        baseUrl: JiaowuEndpoints.defaultBaseUrl,
        path: JiaowuEndpoints.loginPage,
        headers: const {'Cookie': 'JSESSIONID=must-not-leak'},
        data: const {'mm': 'encrypted-secret-must-not-leak'},
      ),
      type: type,
      error: cause,
    );
  }

  test('TLS 握手异常映射为 TLS_HANDSHAKE_FAILED，并保留安全摘要', () {
    final mapped = TransportErrorMapper.map(
      error(
        type: DioExceptionType.connectionError,
        cause: HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      ),
      '获取 CSRF',
    );

    expect(mapped, isA<NetworkException>());
    expect(mapped.code, 'TLS_HANDSHAKE_FAILED');
    expect(mapped.message, contains('TLS'));
    expect(mapped.diagnostic?.host, 'jxw.sylu.edu.cn');
    expect(mapped.diagnostic?.innerType, 'HandshakeException');
    expect(mapped.diagnostic?.toDisplayString(), isNot(contains('JSESSIONID')));
    expect(mapped.diagnostic?.toDisplayString(),
        isNot(contains('encrypted-secret')));
  });

  test('DNS、不可达和拒绝连接分别映射为可操作错误码', () {
    final cases = <String, String>{
      'Failed host lookup: jxw.sylu.edu.cn': 'DNS_LOOKUP_FAILED',
      'Network is unreachable': 'NETWORK_UNREACHABLE',
      'Connection refused': 'CONNECTION_REFUSED',
    };

    for (final entry in cases.entries) {
      final mapped = TransportErrorMapper.map(
        error(
          type: DioExceptionType.connectionError,
          cause: SocketException(entry.key),
        ),
        'HTTPS 诊断',
      );
      expect(mapped.code, entry.value, reason: entry.key);
    }
  });

  test('TLS 证书错误只暴露白名单 reason/detail', () {
    final cases = <String, ({String reason, String? detail})>{
      'CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate': (
        reason: 'CERTIFICATE_VERIFY_FAILED',
        detail: 'UNKNOWN_CA',
      ),
      'hostname mismatch': (
        reason: 'CERTIFICATE_VERIFY_FAILED',
        detail: 'HOSTNAME_MISMATCH',
      ),
      'certificate has expired': (
        reason: 'CERTIFICATE_VERIFY_FAILED',
        detail: 'CERT_EXPIRED',
      ),
      'certificate is not yet valid': (
        reason: 'CERTIFICATE_VERIFY_FAILED',
        detail: 'CERT_NOT_YET_VALID',
      ),
      'tlsv1 alert protocol version': (
        reason: 'TLS_PROTOCOL_VERSION',
        detail: null,
      ),
      'handshake failure': (
        reason: 'TLS_HANDSHAKE_GENERIC',
        detail: null,
      ),
    };

    for (final entry in cases.entries) {
      final mapped = TransportErrorMapper.map(
        error(
          type: DioExceptionType.connectionError,
          cause: HandshakeException(entry.key),
        ),
        '网络诊断',
      );
      expect(mapped.diagnostic?.tlsReason, entry.value.reason,
          reason: entry.key);
      expect(mapped.diagnostic?.tlsDetail, entry.value.detail,
          reason: entry.key);
      expect(mapped.diagnostic?.toDisplayString(), isNot(contains(entry.key)));
    }
  });

  test('无法识别的 HandshakeException 回退到通用 TLS 原因', () {
    final mapped = TransportErrorMapper.map(
      error(
        type: DioExceptionType.connectionError,
        cause: HandshakeException('平台私有错误文本，不应显示'),
      ),
      '网络诊断',
    );

    expect(mapped.diagnostic?.tlsReason, 'TLS_HANDSHAKE_GENERIC');
    expect(mapped.diagnostic?.tlsDetail, isNull);
    expect(mapped.diagnostic?.toDisplayString(), isNot(contains('平台私有错误文本')));
  });

  test('超时保留 REQUEST_TIMEOUT 和原始 transport 摘要', () {
    final mapped = TransportErrorMapper.map(
      error(type: DioExceptionType.receiveTimeout),
      '获取成绩',
    );

    expect(mapped, isA<RequestTimeoutException>());
    expect(mapped.code, 'REQUEST_TIMEOUT');
    expect(mapped.diagnostic?.dioType, 'receiveTimeout');
  });

  test('网络探针在无账号情况下完成 DNS、HTTPS 和 CSRF 检查', () async {
    final dio = Dio()
      ..httpClientAdapter = QueuedHttpAdapter([
        const QueuedHttpResponse(
          statusCode: 200,
          body: '<input id="csrftoken" value="probe-csrf">',
        ),
      ]);
    final result = await JiaowuNetworkProbe(
      dio: dio,
      baseUrl: 'https://localhost',
    ).run();

    expect(result.dnsSucceeded, isTrue);
    expect(result.ipv4Count + result.ipv6Count, greaterThan(0));
    expect(result.httpsSucceeded, isTrue);
    expect(result.csrfSucceeded, isTrue);
    expect(result.succeeded, isTrue);
  });

  test('网络探针保留 HTTPS transport 的安全分类', () async {
    final dio = Dio()
      ..httpClientAdapter = QueuedHttpAdapter([
        QueuedHttpResponse(
          statusCode: 200,
          body: '',
          error: DioException(
            requestOptions: RequestOptions(
              baseUrl: 'https://localhost',
              path: JiaowuEndpoints.loginPage,
            ),
            type: DioExceptionType.connectionError,
            error: HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          ),
        ),
      ]);
    final result = await JiaowuNetworkProbe(
      dio: dio,
      baseUrl: 'https://localhost',
    ).run();

    expect(result.dnsSucceeded, isTrue);
    expect(result.httpsSucceeded, isFalse);
    expect(result.error?.code, 'TLS_HANDSHAKE_FAILED');
    expect(result.error?.diagnostic?.host, 'localhost');
  });
}
