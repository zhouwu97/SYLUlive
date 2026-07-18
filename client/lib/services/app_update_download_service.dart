import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// APK 下载状态机。客户端 UI 按状态渲染按钮文案。
///
/// 任何失败都会进入 [failed]，调用方通过 [AppDownloadError.kind] 区分恢复策略。
enum AppDownloadStatus {
  idle,
  preparing,
  downloading,
  paused,
  verifying,
  ready,
  failed,
}

/// 下载进度。所有字段都是快照，调用方监听后立刻渲染即可。
class AppDownloadProgress {
  final int receivedBytes;
  final int totalBytes;
  final int bytesPerSecond;
  final int estimatedSecondsRemaining;

  AppDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.estimatedSecondsRemaining,
  });

  double get percent {
    if (totalBytes <= 0) return 0;
    final value = receivedBytes / totalBytes;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }
}

/// 下载错误类别。决定了 UI 提示文案和"是否值得重试"。
enum AppDownloadErrorKind {
  network,
  server,
  storage,
  checksumMismatch,
  installer,
  cancelled,
  unknown,
}

/// APK 下载错误。所有失败路径都封装成 [AppDownloadError]，
/// 调用方不需要捕获原始 DioException / FileSystemException。
class AppDownloadError implements Exception {
  final AppDownloadErrorKind kind;
  final String message;

  const AppDownloadError(this.kind, this.message);

  @override
  String toString() => 'AppDownloadError($kind): $message';
}

/// APK 下载服务。
///
/// 主要职责：
///   1. 把 APK 写入 App 私有 cache/app_updates 目录，不申请外部存储权限；
///   2. 已有 `.part` 文件时按已经下到的字节使用 Range 续传；
///   3. 流式计算 SHA-256，避免把整个 APK 装进内存；
///   4. 处理服务端"忽略 Range"返回 200 的情况，截断 `.part` 从 0 字节重写；
///   5. 处理服务端 416 Range Not Satisfiable：`.part` 长度等于预期则进入
///      校验，否则删除 `.part` 从头重新下载；
///   6. 完整性校验通过后原子改名 `.part` 为 `.apk`，由上层唤起安装。
class AppUpdateDownloadService {
  final Dio _dio;

  AppUpdateDownloadService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 60),
              sendTimeout: const Duration(seconds: 30),
              // 大文件必须用流，避免 dio 把整个 APK 装进内存。
              responseType: ResponseType.stream,
              // 接受 200/206/416 都是正常流程，由业务逻辑分支处理。
              validateStatus: (status) =>
                  status != null &&
                  (status == 200 || status == 206 || status == 416),
            ),
          );

  /// 下载 APK 到 App 私有目录，校验 SHA-256 后返回最终文件路径。
  ///
  /// 成功返回 [File]；失败抛 [AppDownloadError]。
  Future<File> download({
    required String url,
    required int expectedSize,
    required String expectedSha256,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (url.isEmpty) {
      throw const AppDownloadError(
        AppDownloadErrorKind.unknown,
        'download_url 为空',
      );
    }
    if (expectedSize <= 0) {
      throw const AppDownloadError(
        AppDownloadErrorKind.unknown,
        'file_size 非正',
      );
    }
    _validateSha256Hex(expectedSha256);

    final baseDir = await _resolveDownloadDir();
    final partFile = File(p.join(baseDir.path, _partFileName(expectedSha256)));
    final finalFile = File(p.join(baseDir.path, _apkFileName(expectedSha256)));

    // 如果最终文件已完整且 hash 一致，直接复用（用户重试同一版本）。
    if (await finalFile.exists()) {
      final size = await finalFile.length();
      if (size == expectedSize &&
          await _sha256OfFile(finalFile) == expectedSha256) {
        return finalFile;
      }
      // 已损坏：删除后走完整流程。
      await finalFile.delete();
    }

    int startByte = 0;
    if (await partFile.exists()) {
      startByte = await partFile.length();
      if (startByte >= expectedSize) {
        // .part 大小已超过预期：上次写入错乱。重头开始。
        await partFile.delete();
        startByte = 0;
      }
    }

    IOSink? sink;
    try {
      final received = await _streamDownload(
        url: url,
        expectedSize: expectedSize,
        startByte: startByte,
        partFile: partFile,
        onProgress: onProgress,
        cancelToken: cancelToken,
        openSink: (truncate) async {
          if (truncate) {
            sink = partFile.openWrite(mode: FileMode.write);
          } else {
            sink = partFile.openWrite(mode: FileMode.writeOnlyAppend);
          }
          return sink!;
        },
      );

      await sink!.flush();
      await sink!.close();
      sink = null;

      if (received != expectedSize) {
        throw AppDownloadError(
          AppDownloadErrorKind.server,
          '下载数据长度不符，预期 $expectedSize 实收 $received',
        );
      }

      // 流式校验。
      final actualSha = await _sha256OfFile(partFile);
      if (actualSha != expectedSha256) {
        // 校验失败必须删 .part，避免下次续传继续追加坏数据。
        await partFile.delete();
        throw AppDownloadError(
          AppDownloadErrorKind.checksumMismatch,
          'SHA-256 校验失败: expected=$expectedSha256 actual=$actualSha',
        );
      }

      // 原子改名到 .apk。
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await partFile.rename(finalFile.path);
      return finalFile;
    } catch (e) {
      try {
        final openedSink = sink;
        if (openedSink != null) {
          await openedSink.close();
        }
      } catch (_) {
        // 忽略 sink 关闭错误，保留原始异常。
      }
      if (e is AppDownloadError) rethrow;
      if (e is DioException) {
        throw _wrapDioException(e);
      }
      if (e is FileSystemException) {
        throw AppDownloadError(
          AppDownloadErrorKind.storage,
          '存储读写失败: ${e.message}',
        );
      }
      if (e is FormatException) {
        throw AppDownloadError(
          AppDownloadErrorKind.unknown,
          '数据格式异常: ${e.message}',
        );
      }
      throw AppDownloadError(AppDownloadErrorKind.unknown, e.toString());
    }
  }

  /// 流式下载。处理 200/206/416 三种响应与是否截断 `.part`。
  ///
  /// [openSink] 由调用方提供，便于测试注入 mock sink。返回最终下载到的
  /// 总字节数（包含上次已有的字节）。
  Future<int> _streamDownload({
    required String url,
    required int expectedSize,
    required int startByte,
    required File partFile,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
    required Future<IOSink> Function(bool truncate) openSink,
  }) async {
    final Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        url,
        options: _rangeOptions(startByte),
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      // 416 也可能在这里被 dio 视为 badResponse；统一包装为 AppDownloadError。
      throw _wrapDioException(e);
    }

    final status = response.statusCode ?? 0;
    if (status == 416) {
      // 服务端告诉我们 Range 不合适。如果本地 .part 已经写到预期大小，
      // 不再发请求，直接进入校验流程（由调用方对 partFile 校验）。
      if (startByte == expectedSize) {
        return startByte;
      }
      // 否则视为损坏：删除 .part 后重新发一次不带 Range 的请求。
      await partFile.delete();
      final Response<ResponseBody> fresh;
      try {
        fresh = await _dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(minutes: 60),
          ),
          cancelToken: cancelToken,
        );
      } on DioException catch (e) {
        throw _wrapDioException(e);
      }
      return await _pullStream(
        response: fresh,
        truncate: true,
        startByte: 0,
        expectedSize: expectedSize,
        onProgress: onProgress,
        cancelToken: cancelToken,
        openSink: openSink,
      );
    }

    final bool serverHonoredRange;
    if (startByte > 0 && status == 206) {
      // 服务器接受 Range 并返回了部分内容。
      serverHonoredRange = true;
    } else if (status == 200) {
      // 服务器忽略 Range 返回完整文件：必须截断 `.part` 从 0 字节重写。
      serverHonoredRange = false;
    } else {
      throw AppDownloadError(AppDownloadErrorKind.server, '非预期状态码: $status');
    }

    final effectiveStart = serverHonoredRange ? startByte : 0;
    return await _pullStream(
      response: response,
      truncate: !serverHonoredRange,
      startByte: effectiveStart,
      expectedSize: expectedSize,
      onProgress: onProgress,
      cancelToken: cancelToken,
      openSink: openSink,
    );
  }

  /// 把 [response] 流写到 sink，回调进度事件，并处理取消中断。
  Future<int> _pullStream({
    required Response<ResponseBody> response,
    required bool truncate,
    required int startByte,
    required int expectedSize,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
    required Future<IOSink> Function(bool truncate) openSink,
  }) async {
    final sink = await openSink(truncate);
    final stream = response.data;
    if (stream == null) {
      throw const AppDownloadError(AppDownloadErrorKind.server, '响应体为空');
    }

    var received = startByte;
    final speedTracker = _SpeedTracker();
    final completer = Completer<int>();

    late StreamSubscription<List<int>> subscription;
    subscription = stream.stream.listen(
      (List<int> chunk) {
        if (cancelToken?.isCancelled ?? false) {
          subscription.cancel();
          if (!completer.isCompleted) {
            completer.completeError(
              const AppDownloadError(AppDownloadErrorKind.cancelled, '下载已被取消'),
            );
          }
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        final snapshot = speedTracker.tick(received);
        if (onProgress != null) {
          final remaining = expectedSize > 0 ? (expectedSize - received) : 0;
          final eta = snapshot.bytesPerSecond > 0
              ? (remaining ~/ snapshot.bytesPerSecond)
              : 0;
          onProgress(
            AppDownloadProgress(
              receivedBytes: received,
              totalBytes: expectedSize,
              bytesPerSecond: snapshot.bytesPerSecond,
              estimatedSecondsRemaining: eta,
            ),
          );
        }
      },
      onError: (Object error) {
        if (error is DioException) {
          if (!completer.isCompleted) {
            completer.completeError(_wrapDioException(error));
          }
        } else if (!completer.isCompleted) {
          completer.completeError(
            AppDownloadError(AppDownloadErrorKind.network, error.toString()),
          );
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(received);
      },
      cancelOnError: true,
    );

    if (cancelToken != null) {
      cancelToken.whenCancel.whenComplete(() {
        if (!completer.isCompleted) {
          subscription.cancel();
          completer.completeError(
            const AppDownloadError(AppDownloadErrorKind.cancelled, '下载已被取消'),
          );
        }
      });
    }

    return completer.future;
  }

  Options _rangeOptions(int startByte) {
    final headers = <String, dynamic>{};
    if (startByte > 0) {
      headers['Range'] = 'bytes=$startByte-';
    }
    return Options(
      headers: headers,
      responseType: ResponseType.stream,
      receiveTimeout: const Duration(minutes: 60),
    );
  }

  Future<Directory> _resolveDownloadDir() async {
    final cacheDir = await getTemporaryDirectory();
    final dir = Directory(p.join(cacheDir.path, 'app_updates'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _partFileName(String sha) => 'shenliyuan-$sha.part';

  String _apkFileName(String sha) => 'shenliyuan-$sha.apk';

  /// 流式计算文件 SHA-256。绝不把 APK 装进内存。
  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  void _validateSha256Hex(String value) {
    if (value.length != 64) {
      throw AppDownloadError(
        AppDownloadErrorKind.unknown,
        'expectedSha256 长度非 64: ${value.length}',
      );
    }
    final lower = value.toLowerCase();
    for (final codeUnit in lower.codeUnits) {
      final isDigit = codeUnit >= 0x30 && codeUnit <= 0x39;
      final isHex = codeUnit >= 0x61 && codeUnit <= 0x66;
      if (!isDigit && !isHex) {
        throw AppDownloadError(
          AppDownloadErrorKind.unknown,
          'expectedSha256 含非法字符: $value',
        );
      }
    }
  }

  AppDownloadError _wrapDioException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return AppDownloadError(
          AppDownloadErrorKind.network,
          e.message?.isNotEmpty == true ? e.message! : '网络超时或不可达',
        );
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        if (status == 404 || status == 410) {
          return const AppDownloadError(
            AppDownloadErrorKind.server,
            'APK 已下架或不存在',
          );
        }
        return AppDownloadError(
          AppDownloadErrorKind.server,
          '服务端返回 HTTP $status',
        );
      case DioExceptionType.cancel:
        return const AppDownloadError(AppDownloadErrorKind.cancelled, '下载已被取消');
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
      case DioExceptionType.transformTimeout:
        return AppDownloadError(
          AppDownloadErrorKind.unknown,
          e.message?.isNotEmpty == true ? e.message! : '未知网络错误',
        );
    }
  }
}

/// 计算瞬时下载速度的简易滑动窗口采样器。
///
/// 每 250ms 抽一次"自上次以来的字节数"，估算 bytes/sec。
class _SpeedTracker {
  static const Duration _window = Duration(milliseconds: 250);

  DateTime _lastSampleAt = DateTime.now();
  int _lastBytes = 0;
  int _bytesPerSecond = 0;

  _SpeedSample tick(int currentReceived) {
    final now = DateTime.now();
    final deltaUs = now.difference(_lastSampleAt).inMicroseconds;
    if (deltaUs < _window.inMicroseconds) {
      // 不到采样窗口：不更新估计速度，只返回当前值。
      return _SpeedSample(_bytesPerSecond);
    }
    final deltaSeconds = deltaUs / 1000000.0;
    final deltaBytes = currentReceived - _lastBytes;
    if (deltaSeconds > 0) {
      _bytesPerSecond = (deltaBytes / deltaSeconds).round();
    }
    _lastSampleAt = now;
    _lastBytes = currentReceived;
    return _SpeedSample(_bytesPerSecond);
  }
}

class _SpeedSample {
  final int bytesPerSecond;
  _SpeedSample(this.bytesPerSecond);
}
