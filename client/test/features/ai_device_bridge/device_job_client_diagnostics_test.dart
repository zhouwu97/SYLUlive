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
}
