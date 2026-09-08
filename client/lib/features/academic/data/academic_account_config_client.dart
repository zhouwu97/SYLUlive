import 'package:dio/dio.dart';
import '../domain/academic_provider.dart';
import '../storage/local_academic_account_store.dart';

/// 共享 App 鉴权网络栈，只传账号配置；密码与学校认证材料没有入参。
final class AcademicAccountConfigClient {
  AcademicAccountConfigClient(this.dio);
  final Dio dio;
  Future<void>? _running;

  Future<void> sync(LocalAcademicAccountStore store, bool Function() current) {
    final running = _running;
    if (running != null) return running;
    final operation = _sync(store, current);
    _running = operation;
    return operation.whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
  }

  Future<void> _sync(
      LocalAcademicAccountStore store, bool Function() current) async {
    for (final provider in AcademicProviderId.values) {
      while (current()) {
        final entry = store.entry(provider);
        final queue = entry['outbox'] as List? ?? [];
        if (queue.isEmpty || entry['conflict'] == true) break;
        final op = Map<String, dynamic>.from(queue.first as Map);
        try {
          final response = await dio.request<Map<String, dynamic>>(
            '/academic-account-configs/${provider.value}',
            data: {
              'expected_revision': op['base_revision'],
              if (op['deleted'] != true) 'student_id': op['student_id']
            },
            options: Options(
                method: op['deleted'] == true ? 'DELETE' : 'PUT',
                headers: {
                  'Idempotency-Key': op['operation_id'],
                  'X-Expected-App-User': store.userId
                },
                sendTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 12)),
          );
          if (!current()) return;
          await store.acknowledge(provider, op['operation_id'] as String,
              Map<String, dynamic>.from(response.data!['config'] as Map));
        } on DioException catch (error) {
          if (!current()) return;
          if (error.response?.data is Map &&
              error.response?.data['code'] == 'APP_USER_CHANGED') {
            return;
          }
          if (error.response?.statusCode == 409) {
            await store.markConflict(provider);
          } else {
            rethrow;
          }
          break;
        }
      }
    }
    if (!current()) return;
    final response = await dio.get<Map<String, dynamic>>(
        '/academic-account-configs',
        options: Options(
            headers: {'X-Expected-App-User': store.userId},
            receiveTimeout: const Duration(seconds: 12)));
    if (!current()) return;
    for (final config in response.data!['configs'] as List) {
      if (!current()) return;
      await store.mergeSnapshot(Map<String, dynamic>.from(config as Map));
    }
  }
}
