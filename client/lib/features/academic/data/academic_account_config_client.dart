import 'package:dio/dio.dart';
import '../domain/academic_provider.dart';
import '../storage/local_academic_account_store.dart';

/// 共享 App 鉴权网络栈，只传账号配置；密码与学校认证材料没有入参。
final class AcademicAccountConfigClient {
  AcademicAccountConfigClient(this.dio);
  final Dio dio;
  final Map<LocalAcademicAccountStore, Future<Set<AcademicProviderId>?>>
      _running = {};

  Future<void> sync(
      LocalAcademicAccountStore store, bool Function() current) async {
    await syncWithPresence(store, current);
  }

  Future<Set<AcademicProviderId>?> syncWithPresence(
      LocalAcademicAccountStore store, bool Function() current) {
    final running = _running[store];
    if (running != null) return running;
    final operation = _sync(store, current);
    _running[store] = operation;
    return operation.whenComplete(() {
      if (identical(_running[store], operation)) _running.remove(store);
    });
  }

  Future<Set<AcademicProviderId>?> _sync(
      LocalAcademicAccountStore store, bool Function() current) async {
    final presentProviders = <AcademicProviderId>{};
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
          if (!current()) return null;
          await store.acknowledge(provider, op['operation_id'] as String,
              _parseConfig(response.data!['config']),
              current: current);
        } on DioException catch (error) {
          if (!current()) return null;
          if (error.response?.data is Map &&
              error.response?.data['code'] == 'APP_USER_CHANGED') {
            return null;
          }
          if (error.response?.statusCode == 409) {
            await store.markConflict(provider, current: current);
          } else {
            rethrow;
          }
          break;
        }
      }
    }
    if (!current()) return null;
    final response = await dio.get<Map<String, dynamic>>(
        '/academic-account-configs',
        options: Options(
            headers: {'X-Expected-App-User': store.userId},
            receiveTimeout: const Duration(seconds: 12)));
    if (!current()) return null;
    // 先完整解析再合并，畸形响应不能被解释成某个 Provider 从未登记。
    final snapshots =
        (response.data!['configs'] as List).map(_parseConfig).toList();
    for (final snapshot in snapshots) {
      if (!current()) return null;
      final provider = AcademicProviderId.tryParse(snapshot['provider_id'])!;
      if (!presentProviders.add(provider)) {
        throw const FormatException('教务配置列表包含重复 Provider');
      }
      await store.mergeSnapshot(snapshot, current: current);
      await store.resolveSatisfiedConflict(provider, current: current);
    }
    return current() ? presentProviders : null;
  }

  Map<String, dynamic> _parseConfig(dynamic value) {
    final config = Map<String, dynamic>.from(value as Map);
    final revision = config['revision'];
    final student = config['student_id'];
    if (AcademicProviderId.tryParse(config['provider_id'] as String? ?? '') ==
            null ||
        revision is! int ||
        revision <= 0 ||
        student is! String ||
        (config['state'] != 'active' && config['state'] != 'deleted') ||
        (config['state'] == 'active' && student.trim().isEmpty)) {
      throw const FormatException('教务配置响应无效');
    }
    return config;
  }
}
