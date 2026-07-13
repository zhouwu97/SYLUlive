import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _RecordedRequest {
  final String adapter;
  final RequestOptions options;

  const _RecordedRequest(this.adapter, this.options);
}

class _QueuedResponse {
  final int statusCode;
  final Object? data;
  final DioExceptionType? exceptionType;
  final Completer<void>? started;
  final Future<void>? release;

  const _QueuedResponse(
    this.statusCode,
    this.data, {
    this.exceptionType,
    this.started,
    this.release,
  });
}

/// 记录 Dio 最终发出的请求，并按顺序返回预设响应。
class _RecordingAdapter implements HttpClientAdapter {
  final String name;
  final List<_RecordedRequest> requests;
  final List<List<int>> requestBodies = [];
  final List<_QueuedResponse> _responses = [];

  _RecordingAdapter(this.name, this.requests);

  void enqueueJson(
    int statusCode,
    Object? data, {
    Completer<void>? started,
    Future<void>? release,
  }) {
    _responses.add(
      _QueuedResponse(
        statusCode,
        data,
        started: started,
        release: release,
      ),
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(_RecordedRequest(name, options));
    final requestBody = <int>[];
    await requestStream?.forEach(requestBody.addAll);
    requestBodies.add(requestBody);
    if (_responses.isEmpty) {
      throw StateError('$name 缺少预设响应: ${options.method} ${options.uri}');
    }
    final response = _responses.removeAt(0);
    response.started?.complete();
    if (response.release != null) await response.release;
    if (response.exceptionType != null) {
      throw DioException(
        requestOptions: options,
        type: response.exceptionType!,
        message: 'socket failed',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(response.data),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

void main() {
  test('创建会话期间认证切换会终止旧流程且新会话独立上传', () async {
    var scope = 1;
    final createStarted = Completer<void>();
    final releaseCreate = Completer<void>();
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(
        201,
        _uploadSessionJson(sessionID: 'auth-a'),
        started: createStarted,
        release: releaseCreate.future,
      )
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'auth-b'))
      ..enqueueJson(201, _paperJson(51, '认证切换'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'auth-b-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final file = _pdfPlatformFile('认证切换.pdf');
    final serviceA = ExamPaperService(
      apiDio,
      storageDio: storageDio,
      authSessionScope: 1,
      currentAuthSessionScope: () => scope,
    );

    final oldUpload = _uploadPaper(serviceA, file, courseName: '认证切换');
    await createStarted.future;
    scope = 2;
    releaseCreate.complete();
    await expectLater(oldUpload, throwsA(_authSessionChangedMatcher()));
    expect(requests.map((request) => request.adapter), ['api']);

    final serviceB = ExamPaperService(
      apiDio,
      storageDio: storageDio,
      authSessionScope: 2,
      currentAuthSessionScope: () => scope,
    );
    final paper = await _uploadPaper(serviceB, file, courseName: '认证切换');

    expect(paper.id, 51);
    expect(requests.map((request) => request.adapter), [
      'api',
      'api',
      'storage',
      'api',
    ]);
  });

  test('认证切换后旧服务不能复用待完成回执', () async {
    var scope = 1;
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'pending-a'))
      ..enqueueJson(500, {'code': 'internal_error', 'error': '完成 A 失败'})
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'pending-b'))
      ..enqueueJson(201, _paperJson(52, '待完成切换'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'pending-a-receipt'})
      ..enqueueJson(201, {'receipt': 'pending-b-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final file = _pdfPlatformFile('待完成切换.pdf');
    final serviceA = ExamPaperService(
      apiDio,
      storageDio: storageDio,
      authSessionScope: 1,
      currentAuthSessionScope: () => scope,
    );

    await expectLater(
      _uploadPaper(serviceA, file, courseName: '待完成切换'),
      throwsA(isA<ExamPaperApiException>()),
    );
    scope = 2;
    await expectLater(
      _uploadPaper(serviceA, file, courseName: '待完成切换'),
      throwsA(_authSessionChangedMatcher()),
    );
    final serviceB = ExamPaperService(
      apiDio,
      storageDio: storageDio,
      authSessionScope: 2,
      currentAuthSessionScope: () => scope,
    );
    final paper = await _uploadPaper(serviceB, file, courseName: '待完成切换');

    expect(paper.id, 52);
    expect(
      requests
          .where((request) => request.adapter == 'storage')
          .map((request) => request.options.path),
      [
        'https://139.196.148.174/v1/uploads/pending-a',
        'https://139.196.148.174/v1/uploads/pending-b',
      ],
    );
  });

  test('完成响应期间认证切换时旧 Future 不返回原账号试卷', () async {
    var scope = 1;
    final completeStarted = Completer<void>();
    final releaseComplete = Completer<void>();
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'complete-a'))
      ..enqueueJson(
        201,
        _paperJson(53, '旧账号试卷'),
        started: completeStarted,
        release: releaseComplete.future,
      );
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'complete-a-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(
      apiDio,
      storageDio: storageDio,
      authSessionScope: 1,
      currentAuthSessionScope: () => scope,
    );

    final upload = _uploadPaper(
      service,
      _pdfPlatformFile('旧账号试卷.pdf'),
      courseName: '旧账号试卷',
    );
    await completeStarted.future;
    scope = 2;
    releaseComplete.complete();

    await expectLater(upload, throwsA(_authSessionChangedMatcher()));
  });

  test('同一上传指纹的并发调用共享一套上传流程', () async {
    final sessionStarted = Completer<void>();
    final releaseSession = Completer<void>();
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(
        201,
        _uploadSessionJson(sessionID: 'singleflight-session'),
        started: sessionStarted,
        release: releaseSession.future,
      )
      ..enqueueJson(201, _paperJson(31, '并发上传'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'singleflight-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);
    final firstFile = _pdfPlatformFile('并发上传.pdf');
    final secondFile = _pdfPlatformFile('并发上传.pdf');

    final first = _uploadPaper(service, firstFile, courseName: '并发上传');
    await sessionStarted.future;
    final second = _uploadPaper(service, secondFile, courseName: '并发上传');
    releaseSession.complete();
    final papers = await Future.wait([first, second]);

    expect(papers.map((paper) => paper.id), [31, 31]);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
    ]);
  });

  test('不同文件完成失败后分别保留回执并只重试各自完成请求', () async {
    final firstCompleteStarted = Completer<void>();
    final releaseFirstComplete = Completer<void>();
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'session-a'))
      ..enqueueJson(
        500,
        {'code': 'internal_error', 'error': '完成 A 失败'},
        started: firstCompleteStarted,
        release: releaseFirstComplete.future,
      )
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'session-b'))
      ..enqueueJson(500, {'code': 'internal_error', 'error': '完成 B 失败'})
      ..enqueueJson(201, _paperJson(41, '交错上传'))
      ..enqueueJson(201, _paperJson(42, '交错上传'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'receipt-a'})
      ..enqueueJson(201, {'receipt': 'receipt-b'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);
    final firstFile = _pdfPlatformFileWithMarker('交错上传.pdf', 1);
    final secondFile = _pdfPlatformFileWithMarker('交错上传.pdf', 2);

    final first = _uploadPaper(service, firstFile, courseName: '交错上传');
    await firstCompleteStarted.future;
    await expectLater(
      _uploadPaper(service, secondFile, courseName: '交错上传'),
      throwsA(isA<ExamPaperApiException>()),
    );
    releaseFirstComplete.complete();
    await expectLater(first, throwsA(isA<ExamPaperApiException>()));

    final firstPaper =
        await _uploadPaper(service, firstFile, courseName: '交错上传');
    final secondPaper =
        await _uploadPaper(service, secondFile, courseName: '交错上传');

    expect([firstPaper.id, secondPaper.id], [41, 42]);
    expect(
      requests
          .where((request) => request.adapter == 'storage')
          .map((request) => request.options.path),
      [
        'https://139.196.148.174/v1/uploads/session-a',
        'https://139.196.148.174/v1/uploads/session-b',
      ],
    );
    final completes = requests
        .where((request) => request.options.path.endsWith('/complete'))
        .toList();
    expect(completes.map((request) => request.options.path), [
      '/exam-papers/upload-sessions/session-a/complete',
      '/exam-papers/upload-sessions/session-b/complete',
      '/exam-papers/upload-sessions/session-a/complete',
      '/exam-papers/upload-sessions/session-b/complete',
    ]);
    expect(completes.map((request) => request.options.data), [
      {'receipt': 'receipt-a'},
      {'receipt': 'receipt-b'},
      {'receipt': 'receipt-a'},
      {'receipt': 'receipt-b'},
    ]);
  });

  test('pending 超限时不淘汰仍在完成请求中的上传', () async {
    const uploadCount = 17;
    final completeStarted = List.generate(
      uploadCount,
      (_) => Completer<void>(),
    );
    final releaseComplete = List.generate(
      uploadCount,
      (_) => Completer<void>(),
    );
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests);
    final storageAdapter = _RecordingAdapter('storage', requests);
    for (var index = 0; index < uploadCount; index++) {
      apiAdapter
        ..enqueueJson(
          201,
          _uploadSessionJson(sessionID: 'active-$index'),
        )
        ..enqueueJson(
          500,
          {'code': 'internal_error', 'error': '完成 $index 失败'},
          started: completeStarted[index],
          release: releaseComplete[index].future,
        );
      storageAdapter.enqueueJson(201, {'receipt': 'active-receipt-$index'});
    }
    apiAdapter.enqueueJson(201, _paperJson(71, '活跃缓存 0'));
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);
    final files = List.generate(
      uploadCount,
      (index) => _pdfPlatformFileWithMarker('活跃缓存.pdf', index),
    );
    final failures = <Future<ExamPaperApiException>>[];

    for (var index = 0; index < uploadCount; index++) {
      final upload = _uploadPaper(
        service,
        files[index],
        courseName: '活跃缓存 $index',
      );
      failures.add(
        upload.then<ExamPaperApiException>(
          (_) => throw StateError('测试上传应当完成失败'),
          onError: (Object error) => error as ExamPaperApiException,
        ),
      );
      await completeStarted[index].future;
    }
    for (final barrier in releaseComplete) {
      barrier.complete();
    }
    await Future.wait(failures);

    final retried = await _uploadPaper(
      service,
      files.first,
      courseName: '活跃缓存 0',
    );

    expect(retried.id, 71);
    expect(
      requests.where((request) => request.adapter == 'storage').length,
      uploadCount,
    );
    expect(requests.last.options.path,
        '/exam-papers/upload-sessions/active-0/complete');
    expect(requests.last.options.data, {'receipt': 'active-receipt-0'});
  });

  test('上传先创建会话，再直传文件，最后完成会话', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, {
        'session_id': 'session-1',
        'upload_url': 'https://139.196.148.174/v1/uploads/session-1',
        'upload_token': 'signed-upload-token',
        'expires_at': '2026-07-13T10:10:00Z',
      })
      ..enqueueJson(201, _paperJson(9, '高等数学'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'signed-receipt'});
    final apiDio = Dio(
      BaseOptions(
        baseUrl: 'https://couqie.ccwu.cc/api',
        headers: {
          'Authorization': 'Bearer main-jwt',
          'Cookie': 'session=main-cookie',
        },
      ),
    )..httpClientAdapter = apiAdapter;
    apiDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['X-Main-Interceptor'] = 'present';
          handler.next(options);
        },
      ),
    );
    final storageDio = Dio()..httpClientAdapter = storageAdapter;

    final paper = await ExamPaperService(
      apiDio,
      storageDio: storageDio,
    ).upload(
      file: PlatformFile(
        name: '高等数学.pdf',
        size: 8,
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.4')),
      ),
      courseName: ' 高等数学 ',
      academicYear: '2025-2026',
      semester: 'first',
      examType: 'final',
      privacyConfirmed: true,
    );

    expect(paper.id, 9);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
    ]);
    expect(requests[0].options.path, '/exam-papers/upload-sessions');
    expect(requests[0].options.data, {
      'course_name': '高等数学',
      'academic_year': '2025-2026',
      'semester': 'first',
      'exam_type': 'final',
      'privacy_confirmed': true,
      'file_size': 8,
    });
    expect(requests[1].options.uri.host, '139.196.148.174');
    expect(
      requests[1].options.headers['Authorization'],
      'Bearer signed-upload-token',
    );
    expect(requests[1].options.headers['Cookie'], isNull);
    expect(requests[1].options.headers['X-Main-Interceptor'], isNull);
    expect(requests[1].options.followRedirects, isFalse);
    expect(requests[2].options.path,
        '/exam-papers/upload-sessions/session-1/complete');
    expect(requests[2].options.data, {'receipt': 'signed-receipt'});
  });

  test('完成请求失败后重试只重新完成会话，不重复上传文件', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson())
      ..enqueueJson(500, {
        'code': 'internal_error',
        'error': '完成试卷投稿失败',
      })
      ..enqueueJson(201, _paperJson(10, '数据结构'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'receipt-for-retry'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);
    final file = _pdfPlatformFile('数据结构.pdf');

    await expectLater(
      _uploadPaper(service, file, courseName: '数据结构'),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'internal_error'),
      ),
    );
    final paper = await _uploadPaper(service, file, courseName: '数据结构');

    expect(paper.id, 10);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
      'api',
    ]);
    expect(
      requests.last.options.path,
      '/exam-papers/upload-sessions/session-1/complete',
    );
  });

  test('上传进度只由文件服务器请求产生', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson())
      ..enqueueJson(201, _paperJson(11, '离散数学'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'receipt-with-progress'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final progressRequestCounts = <int>[];

    await _uploadPaper(
      ExamPaperService(apiDio, storageDio: storageDio),
      _pdfPlatformFile('离散数学.pdf'),
      courseName: '离散数学',
      onSendProgress: (sent, total) {
        progressRequestCounts.add(requests.length);
      },
    );

    expect(progressRequestCounts, isNotEmpty);
    expect(progressRequestCounts, everyElement(2));
  });

  test('path 文件可以完成两阶段直传', () async {
    final directory = await Directory.systemTemp.createTemp('paper-upload-');
    addTearDown(() => directory.delete(recursive: true));
    final localFile = File('${directory.path}${Platform.pathSeparator}试卷.pdf');
    await localFile.writeAsBytes(utf8.encode('%PDF-1.4'));
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson())
      ..enqueueJson(201, _paperJson(12, '大学物理'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'path-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;

    final paper = await _uploadPaper(
      ExamPaperService(apiDio, storageDio: storageDio),
      PlatformFile(
        name: '试卷.pdf',
        size: await localFile.length(),
        path: localFile.path,
      ),
      courseName: '大学物理',
    );

    expect(paper.id, 12);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
    ]);
  });

  test('同路径同大小同修改时间但内容变化时生成新上传指纹', () async {
    final directory = await Directory.systemTemp.createTemp('paper-hash-');
    addTearDown(() => directory.delete(recursive: true));
    final localFile = File('${directory.path}${Platform.pathSeparator}碰撞.pdf');
    final fixedModified = DateTime.utc(2026, 7, 13, 12);
    await localFile.writeAsBytes(utf8.encode('%PDF-A01'));
    await localFile.setLastModified(fixedModified);
    final platformFile = PlatformFile(
      name: '碰撞.pdf',
      size: await localFile.length(),
      path: localFile.path,
    );
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'path-a'))
      ..enqueueJson(500, {'code': 'internal_error', 'error': '完成 A 失败'})
      ..enqueueJson(201, _uploadSessionJson(sessionID: 'path-b'))
      ..enqueueJson(201, _paperJson(61, '路径内容'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'path-a-receipt'})
      ..enqueueJson(201, {'receipt': 'path-b-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);

    await expectLater(
      _uploadPaper(service, platformFile, courseName: '路径内容'),
      throwsA(isA<ExamPaperApiException>()),
    );
    await localFile.writeAsBytes(utf8.encode('%PDF-B02'));
    await localFile.setLastModified(fixedModified);

    final paper = await _uploadPaper(service, platformFile, courseName: '路径内容');

    expect(paper.id, 61);
    expect(
      requests
          .where((request) => request.adapter == 'storage')
          .map((request) => request.options.path),
      [
        'https://139.196.148.174/v1/uploads/path-a',
        'https://139.196.148.174/v1/uploads/path-b',
      ],
    );
  });

  test('路径文件完成指纹后被替换仍上传本次读取的原始字节', () async {
    final directory = await Directory.systemTemp.createTemp('paper-snapshot-');
    addTearDown(() => directory.delete(recursive: true));
    final localFile = File(
      '${directory.path}${Platform.pathSeparator}snapshot.pdf',
    );
    final originalBytes = utf8.encode('%PDF-ORIGINAL-CONTENT');
    final replacementBytes = utf8.encode('%PDF-REPLACED-CONTENT');
    expect(replacementBytes.length, originalBytes.length);
    await localFile.writeAsBytes(originalBytes);
    final platformFile = PlatformFile(
      name: 'snapshot.pdf',
      size: originalBytes.length,
      path: localFile.path,
    );
    final createStarted = Completer<void>();
    final releaseCreate = Completer<void>();
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(
        201,
        _uploadSessionJson(sessionID: 'snapshot-session'),
        started: createStarted,
        release: releaseCreate.future,
      )
      ..enqueueJson(201, _paperJson(62, '文件快照'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'snapshot-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);

    final upload = _uploadPaper(service, platformFile, courseName: '文件快照');
    await createStarted.future;
    await localFile.writeAsBytes(replacementBytes, flush: true);
    releaseCreate.complete();
    final paper = await upload;

    expect(paper.id, 62);
    final multipartBody = storageAdapter.requestBodies.single;
    expect(_containsBytes(multipartBody, originalBytes), isTrue);
    expect(_containsBytes(multipartBody, replacementBytes), isFalse);
  });

  test('拒绝把上传令牌发送到非文件服务域名', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(
          201,
          _uploadSessionJson(
            uploadURL: 'https://attacker.example/v1/uploads/session-1',
          ));
    final storageAdapter = _RecordingAdapter('storage', requests);
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;

    await expectLater(
      _uploadPaper(
        ExamPaperService(apiDio, storageDio: storageDio),
        _pdfPlatformFile('恶意地址.pdf'),
      ),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'invalid_storage_url'),
      ),
    );
    expect(requests.map((request) => request.adapter), ['api']);
  });

  test('拒绝非标准端口和不匹配会话的文件服务地址', () async {
    for (final uploadURL in [
      'https://139.196.148.174:8443/v1/uploads/session-1',
      'https://139.196.148.174/v1/uploads/another-session',
      'http://139.196.148.174/v1/uploads/session-1',
    ]) {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests)
        ..enqueueJson(201, _uploadSessionJson(uploadURL: uploadURL));
      final storageAdapter = _RecordingAdapter('storage', requests);
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;

      await expectLater(
        _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('地址约束.pdf'),
        ),
        throwsA(
          isA<ExamPaperApiException>()
              .having((error) => error.code, 'code', 'invalid_storage_url'),
        ),
        reason: uploadURL,
      );
      expect(requests.map((request) => request.adapter), ['api']);
    }
  });

  test('三阶段服务错误均转换为可判断的上传异常', () async {
    Future<ExamPaperApiException> runFailure({
      required List<_QueuedResponse> apiResponses,
      required List<_QueuedResponse> storageResponses,
    }) async {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests);
      final storageAdapter = _RecordingAdapter('storage', requests);
      for (final response in apiResponses) {
        apiAdapter.enqueueJson(response.statusCode, response.data);
      }
      for (final response in storageResponses) {
        storageAdapter.enqueueJson(response.statusCode, response.data);
      }
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;
      try {
        await _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('错误映射.pdf'),
        );
      } on ExamPaperApiException catch (error) {
        return error;
      }
      throw StateError('测试请求应当失败');
    }

    final upgrade = await runFailure(
      apiResponses: const [
        _QueuedResponse(426, {
          'code': 'client_upgrade_required',
          'error': '请升级客户端后上传试卷',
        }),
      ],
      storageResponses: const [],
    );
    expect(upgrade.code, 'client_upgrade_required');
    expect(upgrade.message, contains('升级'));

    final storage = await runFailure(
      apiResponses: [_QueuedResponse(201, _uploadSessionJson())],
      storageResponses: const [
        _QueuedResponse(507, {
          'error': 'insufficient storage',
        }),
      ],
    );
    expect(storage.code, 'insufficient_storage');
    expect(storage.message, '文件服务器空间不足，请稍后重试');

    final expired = await runFailure(
      apiResponses: [
        _QueuedResponse(201, _uploadSessionJson()),
        const _QueuedResponse(410, {
          'code': 'upload_session_expired',
          'error': '上传会话已过期，请重新上传',
        }),
      ],
      storageResponses: const [
        _QueuedResponse(201, {'receipt': 'expired-receipt'}),
      ],
    );
    expect(expired.code, 'upload_session_expired');
    expect(expired.message, contains('过期'));

    final storageNetwork = await runFailure(
      apiResponses: [_QueuedResponse(201, _uploadSessionJson())],
      storageResponses: const [
        _QueuedResponse(
          0,
          null,
          exceptionType: DioExceptionType.connectionError,
        ),
      ],
    );
    expect(storageNetwork.code, 'storage_upload_failed');
    expect(storageNetwork.message, '文件上传失败，请检查网络后重试');

    final completeNetwork = await runFailure(
      apiResponses: [
        _QueuedResponse(201, _uploadSessionJson()),
        const _QueuedResponse(
          0,
          null,
          exceptionType: DioExceptionType.connectionError,
        ),
      ],
      storageResponses: const [
        _QueuedResponse(201, {'receipt': 'network-receipt'}),
      ],
    );
    expect(completeNetwork.code, 'upload_complete_failed');
    expect(completeNetwork.message, contains('文件已上传'));
  });

  test('文件服务真实错误串映射为稳定错误码和中文提示', () async {
    final cases = <({
      String serverError,
      int statusCode,
      String expectedCode,
      String expectedMessage,
    })>[
      (
        serverError: 'unauthorized',
        statusCode: 401,
        expectedCode: 'upload_session_expired',
        expectedMessage: '上传凭证已失效，请重新上传',
      ),
      (
        serverError: 'upload_session_expired',
        statusCode: 410,
        expectedCode: 'upload_session_expired',
        expectedMessage: '上传会话已过期，请重新上传',
      ),
      (
        serverError: 'upload_session_invalid',
        statusCode: 409,
        expectedCode: 'upload_session_invalid',
        expectedMessage: '上传会话已失效，请重新上传',
      ),
      (
        serverError: 'upload_retry_exhausted',
        statusCode: 429,
        expectedCode: 'upload_retry_exhausted',
        expectedMessage: '该文件上传失败次数过多，请重新选择文件',
      ),
      (
        serverError: 'upload_unclaimed_quota_exceeded',
        statusCode: 429,
        expectedCode: 'upload_storage_quota_exceeded',
        expectedMessage: '未完成的上传过多，请稍后重试',
      ),
      (
        serverError: 'upload_session_in_progress',
        statusCode: 409,
        expectedCode: 'upload_session_in_progress',
        expectedMessage: '该文件正在上传，请稍后重试',
      ),
      (
        serverError: 'file_size_mismatch',
        statusCode: 422,
        expectedCode: 'file_size_mismatch',
        expectedMessage: '文件大小发生变化，请重新选择 PDF',
      ),
      (
        serverError: 'file too large',
        statusCode: 413,
        expectedCode: 'file_too_large',
        expectedMessage: 'PDF 不能超过 20 MiB',
      ),
      (
        serverError: 'invalid pdf',
        statusCode: 422,
        expectedCode: 'invalid_pdf',
        expectedMessage: 'PDF 文件无效或已加密，请更换文件',
      ),
      (
        serverError: 'encrypted pdf',
        statusCode: 422,
        expectedCode: 'invalid_pdf',
        expectedMessage: 'PDF 文件无效或已加密，请更换文件',
      ),
      (
        serverError: 'insufficient storage',
        statusCode: 507,
        expectedCode: 'insufficient_storage',
        expectedMessage: '文件服务器空间不足，请稍后重试',
      ),
      (
        serverError: 'validation busy',
        statusCode: 503,
        expectedCode: 'validation_busy',
        expectedMessage: '文件校验繁忙，请稍后重试',
      ),
      (
        serverError: 'storage unavailable',
        statusCode: 500,
        expectedCode: 'storage_unavailable',
        expectedMessage: '文件服务器暂不可用，请稍后重试',
      ),
    ];

    for (final testCase in cases) {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests)
        ..enqueueJson(201, _uploadSessionJson());
      final storageAdapter = _RecordingAdapter('storage', requests)
        ..enqueueJson(testCase.statusCode, {'error': testCase.serverError});
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;

      await expectLater(
        _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('错误映射.pdf'),
        ),
        throwsA(
          isA<ExamPaperApiException>()
              .having(
                (error) => error.code,
                'code',
                testCase.expectedCode,
              )
              .having(
                (error) => error.message,
                'message',
                testCase.expectedMessage,
              )
              .having(
                (error) => error.statusCode,
                'statusCode',
                testCase.statusCode,
              ),
        ),
        reason: testCase.serverError,
      );
    }
  });

  test('文件服务未知或非对象错误响应不回显原始内容', () async {
    for (final response in const [
      _QueuedResponse(500, {'error': 'private backend detail'}),
      _QueuedResponse(502, <Object>['private', 'backend', 'detail']),
      _QueuedResponse(400, 'private backend detail'),
    ]) {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests)
        ..enqueueJson(201, _uploadSessionJson());
      final storageAdapter = _RecordingAdapter('storage', requests)
        ..enqueueJson(response.statusCode, response.data);
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;

      await expectLater(
        _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('未知错误.pdf'),
        ),
        throwsA(
          isA<ExamPaperApiException>()
              .having(
                (error) => error.code,
                'code',
                'storage_upload_failed',
              )
              .having(
                (error) => error.message,
                'message',
                '文件上传失败，请稍后重试',
              )
              .having(
                (error) => error.statusCode,
                'statusCode',
                response.statusCode,
              ),
        ),
      );
    }
  });

  test('拒绝字段类型错误的会话、文件服务和完成响应', () async {
    Future<String> invalidResponseCode({
      required List<_QueuedResponse> apiResponses,
      required List<_QueuedResponse> storageResponses,
    }) async {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests);
      final storageAdapter = _RecordingAdapter('storage', requests);
      for (final response in apiResponses) {
        apiAdapter.enqueueJson(response.statusCode, response.data);
      }
      for (final response in storageResponses) {
        storageAdapter.enqueueJson(response.statusCode, response.data);
      }
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;
      try {
        await _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('响应校验.pdf'),
        );
      } on ExamPaperApiException catch (error) {
        return error.code;
      }
      throw StateError('测试响应应当被拒绝');
    }

    expect(
      await invalidResponseCode(
        apiResponses: [
          _QueuedResponse(201, {
            ..._uploadSessionJson(),
            'session_id': 1,
          }),
        ],
        storageResponses: const [],
      ),
      'invalid_upload_session_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: [_QueuedResponse(201, _uploadSessionJson())],
        storageResponses: const [
          _QueuedResponse(201, {'receipt': 1}),
        ],
      ),
      'invalid_storage_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: [
          _QueuedResponse(201, _uploadSessionJson()),
          _QueuedResponse(201, {
            ..._paperJson(13, '严格校验'),
            'id': '13',
          }),
        ],
        storageResponses: const [
          _QueuedResponse(201, {'receipt': 'strict-receipt'}),
        ],
      ),
      'invalid_complete_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: const [_QueuedResponse(201, <Object>[])],
        storageResponses: const [],
      ),
      'invalid_upload_session_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: [
          _QueuedResponse(201, _uploadSessionJson()),
          _QueuedResponse(201, {
            ..._paperJson(14, '布尔校验'),
            'reward_revocable': 'false',
          }),
        ],
        storageResponses: const [
          _QueuedResponse(201, {'receipt': 'boolean-receipt'}),
        ],
      ),
      'invalid_complete_response',
    );
  });

  test('列表服务传递筛选参数并解析分页响应', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': <dynamic>[],
                'page': 2,
                'page_size': 10,
                'total': 11,
                'academic_years': ['2025-2026', '2024-2025'],
              },
            ),
          );
        },
      ),
    );

    final service = ExamPaperService(dio);
    final result = await service.list(
      keyword: '高数',
      academicYear: '2025-2026',
      semester: 'first',
      examType: 'final',
      sort: 'downloads',
      page: 2,
      pageSize: 10,
    );

    expect(result.page, 2);
    expect(result.hasMore, isFalse);
    expect(result.academicYears, ['2025-2026', '2024-2025']);
    expect(captured?.path, '/exam-papers');
    expect(captured?.queryParameters['keyword'], '高数');
    expect(captured?.queryParameters['sort'], 'downloads');
    expect(captured?.queryParameters['page_size'], 10);
  });

  test('服务端机器错误码转换为可判断的异常', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 403,
                data: {
                  'error': '完成教务认证后才能使用试卷库',
                  'code': 'edu_verification_required',
                },
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    final service = ExamPaperService(dio);
    expect(
      service.list(),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'edu_verification_required')
            .having((error) => error.message, 'message', '完成教务认证后才能使用试卷库'),
      ),
    );
  });

  test('PDF 二进制接口仍能解析服务端 JSON 错误码', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 403,
                data: Uint8List.fromList(
                  utf8.encode(
                    jsonEncode({
                      'error': '无权预览该试卷',
                      'code': 'exam_paper_forbidden',
                    }),
                  ),
                ),
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    final service = ExamPaperService(dio);
    expect(
      service.downloadPreview(_paper(1, '待审核试卷')),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'exam_paper_forbidden')
            .having((error) => error.message, 'message', '无权预览该试卷'),
      ),
    );
  });

  test('管理员列表自动加载全部分页', () async {
    final requestedPages = <int>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final page = options.queryParameters['page'] as int;
          requestedPages.add(page);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': [
                  _paperJson(page, '试卷$page'),
                ],
                'page': page,
                'page_size': 1,
                'total': 2,
              },
            ),
          );
        },
      ),
    );

    final result = await ExamPaperService(dio).adminListAll(
      status: 'published',
      pageSize: 1,
    );

    expect(requestedPages, [1, 2]);
    expect(result.map((paper) => paper.title), ['试卷1', '试卷2']);
  });

  test('我的投稿传递状态并解析全量状态计数', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': <dynamic>[],
                'page': 1,
                'page_size': 20,
                'total': 1,
                'status_counts': {
                  'all': 3,
                  'pending': 1,
                  'published': 1,
                  'unpublished': 1,
                },
              },
            ),
          );
        },
      ),
    );

    final result = await ExamPaperService(dio).mySubmissions(
      status: 'unpublished',
    );

    expect(captured?.queryParameters['status'], 'unpublished');
    expect(result.statusCounts['all'], 3);
    expect(result.statusCounts['unpublished'], 1);

    await ExamPaperService(dio).mySubmissions(status: 'all');
    expect(captured?.queryParameters['status'], 'all');
  });

  test('管理员列表传递关键词、投稿人与排序参数', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': <dynamic>[],
                'page': 1,
                'page_size': 20,
                'total': 0,
              },
            ),
          );
        },
      ),
    );

    await ExamPaperService(dio).adminList(
      status: 'pending',
      keyword: '高等数学',
      contributor: '张同学',
      sort: 'latest',
    );

    expect(captured?.queryParameters['keyword'], '高等数学');
    expect(captured?.queryParameters['contributor'], '张同学');
    expect(captured?.queryParameters['sort'], 'latest');
  });

  test('删除投稿发送 DELETE 并解析经验撤销结果', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'message': '投稿已永久删除',
                'exp_revoked': true,
              },
            ),
          );
        },
      ),
    );

    final result = await ExamPaperService(dio).deleteSubmission(12);

    expect(captured?.method, 'DELETE');
    expect(captured?.path, '/exam-papers/my-submissions/12');
    expect(result.message, '投稿已永久删除');
    expect(result.expRevoked, isTrue);
  });

  test('删除投稿的 Dio 错误转换为接口异常', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 403,
                data: {
                  'error': '无权删除该投稿',
                  'code': 'exam_paper_delete_forbidden',
                },
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    expect(
      ExamPaperService(dio).deleteSubmission(12),
      throwsA(
        isA<ExamPaperApiException>()
            .having(
              (error) => error.code,
              'code',
              'exam_paper_delete_forbidden',
            )
            .having((error) => error.message, 'message', '无权删除该投稿'),
      ),
    );
  });

  test('删除结果缺失字段时使用默认值', () {
    final result = ExamPaperDeleteResult.fromJson(const <String, dynamic>{});

    expect(result.message, '操作成功');
    expect(result.expRevoked, isFalse);
  });

  test('withdraw 保持兼容并发送同一 DELETE', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );

    await ExamPaperService(dio).withdraw(27);

    expect(captured?.method, 'DELETE');
    expect(captured?.path, '/exam-papers/my-submissions/27');
  });
}

ExamPaper _paper(int id, String title) {
  return ExamPaper.fromJson(_paperJson(id, title));
}

Map<String, dynamic> _paperJson(int id, String title) {
  return {
    'id': id,
    'status': 'published',
    'source': 'user',
    'course_name': title,
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': title,
    'file_size': 1024,
    'download_count': 0,
    'reward_revocable': false,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  };
}

Map<String, dynamic> _uploadSessionJson({
  String sessionID = 'session-1',
  String? uploadURL,
}) {
  return {
    'session_id': sessionID,
    'upload_url': uploadURL ?? 'https://139.196.148.174/v1/uploads/$sessionID',
    'upload_token': 'signed-upload-token',
    'expires_at': '2026-07-13T10:10:00Z',
  };
}

PlatformFile _pdfPlatformFile(String name) {
  final bytes = Uint8List.fromList(utf8.encode('%PDF-1.4'));
  return PlatformFile(name: name, size: bytes.length, bytes: bytes);
}

PlatformFile _pdfPlatformFileWithMarker(String name, int marker) {
  final bytes = Uint8List.fromList([...utf8.encode('%PDF-1.'), marker]);
  return PlatformFile(name: name, size: bytes.length, bytes: bytes);
}

Future<ExamPaper> _uploadPaper(
  ExamPaperService service,
  PlatformFile file, {
  String courseName = '高等数学',
  ProgressCallback? onSendProgress,
}) {
  return service.upload(
    file: file,
    courseName: courseName,
    academicYear: '2025-2026',
    semester: 'first',
    examType: 'final',
    privacyConfirmed: true,
    onSendProgress: onSendProgress,
  );
}

Matcher _authSessionChangedMatcher() {
  return isA<ExamPaperApiException>()
      .having((error) => error.code, 'code', 'auth_session_changed')
      .having((error) => error.message, 'message', '登录状态已变化，请重新上传');
}

bool _containsBytes(List<int> source, List<int> pattern) {
  if (pattern.isEmpty) return true;
  for (var index = 0; index <= source.length - pattern.length; index++) {
    var matches = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (source[index + offset] != pattern[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
