import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_job_client.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_job_models.dart';

void main() {
  test('设备任务请求失败包含阶段、网络类型和重试上下文', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 502,
                data: const <String, dynamic>{'code': 'upstream_unavailable'},
              ),
              type: DioExceptionType.connectionTimeout,
            ),
          );
        },
      ),
    );
    DeviceJobApiException? recorded;
    final client = DioDeviceJobClient(
      dio,
      diagnosticWriter: (error) async => recorded = error,
    );

    final error = await client.pending('installation-1').then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        ) as DeviceJobApiException;

    expect(error.operation, 'pending');
    expect(error.statusCode, 502);
    expect(error.dioType, 'connectionTimeout');
    expect(error.retryable, isTrue);
    expect(error.route, '/device/jobs/pending');
    expect(error.method, 'GET');
    expect(recorded, same(error));
  });

  test('waitForUser 请求指向 waiting_user 路由并携带状态版本', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          options.headers['X-Device-Installation-ID'] = 'installation-1';
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'job': <String, dynamic>{
                  'id': 'job-1',
                  'tool_name': 'device.erke.ensure_fresh_overview',
                  'arguments': <String, dynamic>{
                    'max_age_seconds': 300,
                    'allow_upload': false,
                  },
                  'required_data_types': <String>['erke'],
                  'status': 'waiting_user',
                  'state_version': 2,
                  'expires_at': '2026-08-29T12:00:00Z',
                },
              },
            ),
          );
        },
      ),
    );
    final client = DioDeviceJobClient(dio, diagnosticWriter: (_) async {});

    final job = await client.waitForUser('installation-1', 'job-1', 1);

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.uri.path, '/device/jobs/job-1/waiting_user');
    expect(requests.single.data, <String, dynamic>{'state_version': 1});
    expect(job.status, 'waiting_user');
    expect(job.stateVersion, 2);
  });
}
