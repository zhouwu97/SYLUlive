import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/exam_schedule.dart';
import '../academic/storage/academic_persistence_gate.dart';
import '../campus_data/storage/academic_cache_store.dart';
import '../campus_data/storage/account_scoped_snapshot_store.dart';
import '../campus_data/storage/erke_cache_store.dart';
import '../campus_data/storage/personal_snapshot_models.dart';
import '../campus_data/storage/schedule_cache_store.dart';
import 'academic_transfer_crypto.dart';
import 'academic_transfer_payload.dart';

/// 读取「扫码同步」所需资料时的账号上下文。
class AcademicTransferContext {
  const AcademicTransferContext({
    required this.appUserId,
    required this.sourceAccountId,
    required this.provider,
    required this.currentYear,
    required this.currentSemester,
    required this.currentCourses,
    this.identityNamespace,
    this.currentTermStart,
    this.currentFetchedAt,
  });

  final String appUserId;

  /// 教务学号；课表、成绩、二课、体测的加密保险箱都按它分区。
  final String sourceAccountId;
  final String? identityNamespace;

  /// undergraduate / graduate，未知为空串。
  final String provider;
  final String currentYear;
  final int currentSemester;
  final DateTime? currentTermStart;
  final DateTime? currentFetchedAt;

  /// 课表页此刻显示的课程（已含自定义课程和本地调整），即用户「正在用的」那份。
  final List<Map<String, dynamic>> currentCourses;
}

/// 从本机加密缓存读取可同步的资料。每类单独容错：某一类读不出来只是不提供，
/// 不影响其他资料，也不会触发任何学校网络请求。
class AcademicTransferLoader {
  AcademicTransferLoader({
    Future<List<ExamModel>> Function()? loadExams,
    AccountScopedSnapshotStore Function(String appUserId, String? namespace)?
        snapshotStoreBuilder,
  })  : _loadExams = loadExams,
        _snapshotStoreBuilder = snapshotStoreBuilder;

  final Future<List<ExamModel>> Function()? _loadExams;
  final AccountScopedSnapshotStore Function(
      String appUserId, String? namespace)? _snapshotStoreBuilder;

  AccountScopedSnapshotStore _store(String appUserId, String? namespace) =>
      _snapshotStoreBuilder?.call(appUserId, namespace) ??
      AesGcmAccountScopedSnapshotStore(
          appUserId: appUserId, identityNamespace: namespace);

  Future<AcademicTransferBundle> load(AcademicTransferContext context) async {
    final hasAccount = context.appUserId.trim().isNotEmpty &&
        context.sourceAccountId.trim().isNotEmpty;
    final results = await Future.wait<Object?>(<Future<Object?>>[
      hasAccount ? _guard(() => _schedules(context)) : Future.value(null),
      hasAccount ? _guard(() => _grades(context)) : Future.value(null),
      _guard(() async =>
          (await (_loadExams?.call() ?? Future.value(const <ExamModel>[])))),
      hasAccount ? _guard<Object?>(() => _erke(context)) : Future.value(null),
      hasAccount
          ? _guard<Object?>(() => _physical(context))
          : Future.value(null),
    ]);
    final schedules = results[0] as List<AcademicTransferSchedule>? ??
        <AcademicTransferSchedule>[];
    // 账号缓存没读到时，课表页正在显示的课程依然可以同步。
    if (!schedules.any((item) => item.kind == 'current') &&
        context.currentCourses.isNotEmpty) {
      schedules.insert(0, _current(context));
    }
    final grades = results[1] as (List<Map<String, dynamic>>, DateTime?)?;
    final exams = (results[2] as List<ExamModel>? ?? const <ExamModel>[])
        .map((exam) => <String, dynamic>{
              'id': 'app:${exam.name}:${exam.startTime.toIso8601String()}',
              'name': exam.name,
              'startTime': exam.startTime.toUtc().toIso8601String(),
              'endTime': exam.endTime.toUtc().toIso8601String(),
              'room': exam.location,
              'semester': exam.semester,
            })
        .toList();
    return AcademicTransferBundle(
      schedules: schedules,
      grades: grades?.$1 ?? const <Map<String, dynamic>>[],
      gradesFetchedAt: grades?.$2,
      exams: exams,
      erke: results[3] as Map<String, dynamic>?,
      physical: results[4] as Map<String, dynamic>?,
    );
  }

  static Future<T?> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (_) {
      return null;
    }
  }

  AcademicTransferSchedule _current(AcademicTransferContext context) =>
      AcademicTransferSchedule(
        id: 'current',
        kind: 'current',
        label: transferTermLabel(context.currentYear, context.currentSemester),
        provider: context.provider,
        year: context.currentYear,
        semester: context.currentSemester,
        termStart: context.currentTermStart,
        fetchedAt: context.currentFetchedAt,
        courses: transferCourses(context.currentCourses),
      );

  Future<List<AcademicTransferSchedule>> _schedules(
      AcademicTransferContext context) async {
    final store = ScheduleCacheStore(
      appUserId: context.appUserId,
      sourceAccountId: context.sourceAccountId,
      identityNamespace: context.identityNamespace,
      snapshotStore: _snapshotStoreBuilder?.call(
          context.appUserId, context.identityNamespace),
      persistenceGate: RegistryAcademicPersistenceGate(context.appUserId),
    );
    try {
      final vault = await store.readSnapshot();
      final currentId = '${context.currentYear}_${context.currentSemester}';
      final result = <AcademicTransferSchedule>[_current(context)];
      final archives = <AcademicTransferSchedule>[];
      final terms = vault?.terms.entries.toList() ??
          const <MapEntry<String, ScheduleTermSnapshot>>[];
      terms.sort((left, right) => right.key.compareTo(left.key));
      for (final entry in terms) {
        final separator = entry.key.lastIndexOf('_');
        final year = entry.key.substring(0, separator);
        final semester = int.tryParse(entry.key.substring(separator + 1)) ?? 0;
        final term = entry.value;
        if (entry.key != currentId && term.courses.isNotEmpty) {
          result.add(AcademicTransferSchedule(
            id: 'term:${entry.key}',
            kind: 'term',
            label: transferTermLabel(year, semester),
            provider: context.provider,
            year: year,
            semester: semester,
            termStart: term.semesterStart?.toLocal(),
            fetchedAt: vault?.fetchedAt,
            courses: transferCourses(term.courses),
          ));
        }
        for (final archive in term.archives) {
          archives.add(AcademicTransferSchedule(
            id: 'archive:${archive.id}',
            kind: 'archive',
            label: archive.name,
            provider: context.provider,
            year: year,
            semester: semester,
            termStart: term.semesterStart?.toLocal(),
            fetchedAt: archive.createdAt,
            courses: transferCourses(archive.courses),
          ));
        }
      }
      return <AcademicTransferSchedule>[...result, ...archives];
    } finally {
      await store.close();
    }
  }

  Future<(List<Map<String, dynamic>>, DateTime?)> _grades(
      AcademicTransferContext context) async {
    final store = AcademicCacheStore(
      appUserId: context.appUserId,
      sourceAccountId: context.sourceAccountId,
      identityNamespace: context.identityNamespace,
      snapshotStore: _snapshotStoreBuilder?.call(
          context.appUserId, context.identityNamespace),
      persistenceGate: RegistryAcademicPersistenceGate(context.appUserId),
    );
    try {
      final vault = await store.readSnapshot();
      if (vault == null) return (const <Map<String, dynamic>>[], null);
      final grades = <Map<String, dynamic>>[];
      DateTime? latest;
      final terms = vault.terms.values.toList()
        ..sort((left, right) => right.termId.compareTo(left.termId));
      for (final term in terms) {
        final label = transferTermLabel(term.year, term.semester);
        if (latest == null || term.fetchedAt.isAfter(latest)) {
          latest = term.fetchedAt;
        }
        var index = 0;
        for (final raw in term.grades) {
          final grade = transferGrade(raw, label, index++);
          if (grade != null) grades.add(grade);
        }
      }
      return (grades, latest);
    } finally {
      await store.close();
    }
  }

  Future<Map<String, dynamic>?> _erke(AcademicTransferContext context) async {
    final snapshotStore = _store(context.appUserId, null);
    try {
      final snapshot = await ErkeCacheStore(
        appUserId: context.appUserId,
        sourceAccountId: context.sourceAccountId,
        snapshotStore: snapshotStore,
      ).loadSnapshot();
      return snapshot == null ? null : transferErke(snapshot.toJson());
    } finally {
      await snapshotStore.close();
    }
  }

  Future<Map<String, dynamic>?> _physical(
      AcademicTransferContext context) async {
    final snapshotStore = _store(context.appUserId, null);
    try {
      final snapshot = await snapshotStore.read(
        type: PersonalDataType.physical,
        sourceSystem: 'physical',
        sourceAccountId: context.sourceAccountId,
      );
      return snapshot == null
          ? null
          : transferPhysical(snapshot.payload, snapshot.fetchedAt);
    } finally {
      await snapshotStore.close();
    }
  }
}

/// 扫码同步失败的分类，界面据此给出下一步。
enum AcademicTransferFailure {
  expired,
  accountMismatch,
  alreadyUploaded,
  tooLarge,
  busy,
  network,
  invalid,
  unknown
}

class AcademicTransferException implements Exception {
  const AcademicTransferException(this.failure, this.message);
  final AcademicTransferFailure failure;
  final String message;
  @override
  String toString() => message;
}

/// 服务端只接受 600 KiB 以内的密文；提前在本机拦下，给出可操作的提示。
const int academicTransferMaxPlaintextBytes = 590 * 1024;

class AcademicTransferApi {
  AcademicTransferApi(this._dio, {required this.appUserId});

  final Dio _dio;
  final String appUserId;

  String _path(String sessionId, [String suffix = '']) =>
      '/api/academic-transfer/sessions/${Uri.encodeComponent(sessionId)}$suffix';

  Options get _options =>
      Options(headers: <String, String>{'X-Expected-App-User': appUserId});

  Future<void> claim(String sessionId) => _send(
      () => _dio.post<dynamic>(_path(sessionId, '/claim'), options: _options));

  Future<void> upload(AcademicTransferLink link, List<int> plaintext) async {
    if (plaintext.length > academicTransferMaxPlaintextBytes) {
      throw const AcademicTransferException(
        AcademicTransferFailure.tooLarge,
        '选中的资料太多，超过单次同步上限。请少选几项（例如二课活动明细较多时先不选二课）后重试。',
      );
    }
    final envelope = encryptAcademicTransfer(
      webPublicKey: link.webPublicKey,
      sessionId: link.sessionId,
      plaintext: plaintext,
    );
    await _send(() => _dio.put<dynamic>(_path(link.sessionId, '/payload'),
        data: jsonEncode(envelope.toJson()),
        options: _options.copyWith(contentType: Headers.jsonContentType)));
  }

  /// 用户在手机上取消时作废会话，网页随即显示二维码失效。失败不影响用户继续操作。
  Future<void> cancel(String sessionId) async {
    try {
      await _dio.delete<dynamic>(_path(sessionId), options: _options);
    } catch (_) {}
  }

  Future<void> _send(Future<Response<dynamic>> Function() request) async {
    try {
      await request();
    } on DioException catch (error) {
      throw _classify(error);
    }
  }

  static AcademicTransferException _classify(DioException error) {
    final status = error.response?.statusCode;
    final data = error.response?.data;
    final code = data is Map ? data['code']?.toString() : null;
    final message = data is Map ? data['message']?.toString() : null;
    if (status == null) {
      return const AcademicTransferException(
          AcademicTransferFailure.network, '网络连接失败，请检查网络后重试。');
    }
    return switch (code) {
      'TRANSFER_SESSION_NOT_FOUND' => AcademicTransferException(
          AcademicTransferFailure.expired, message ?? '二维码已失效，请在网页重新生成'),
      'TRANSFER_ACCOUNT_MISMATCH' ||
      'APP_USER_CHANGED' =>
        AcademicTransferException(AcademicTransferFailure.accountMismatch,
            message ?? 'App 与网页登录的不是同一个账号'),
      'TRANSFER_ALREADY_UPLOADED' => AcademicTransferException(
          AcademicTransferFailure.alreadyUploaded,
          message ?? '这张二维码已经同步过，请在网页重新生成'),
      'TRANSFER_PAYLOAD_TOO_LARGE' => AcademicTransferException(
          AcademicTransferFailure.tooLarge, message ?? '资料超过单次同步上限，请减少同步内容'),
      'TRANSFER_BUSY' => AcademicTransferException(
          AcademicTransferFailure.busy, message ?? '同步服务繁忙，请稍后重试'),
      'INVALID_TRANSFER_PAYLOAD' ||
      'TRANSFER_NOT_CLAIMED' =>
        AcademicTransferException(
            AcademicTransferFailure.invalid, message ?? '同步内容格式不正确，请重新扫码'),
      _ when status == 404 => const AcademicTransferException(
          AcademicTransferFailure.expired, '二维码已失效，或服务器暂不支持扫码同步，请在网页重新生成'),
      _ when status == 401 => const AcademicTransferException(
          AcademicTransferFailure.accountMismatch, '登录已失效，请重新登录 App 后再扫码'),
      _ => AcademicTransferException(
          AcademicTransferFailure.unknown, message ?? '同步没有完成（$status），请稍后重试'),
    };
  }
}
