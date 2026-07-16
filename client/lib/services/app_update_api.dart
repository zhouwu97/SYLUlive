import 'package:dio/dio.dart';

import '../config/api_constants.dart';
import '../models/app_update_info.dart';

/// 应用更新检查 API 客户端。
///
/// 使用独立的 [Dio] 实例而不是项目共享的 [AuthProvider.dio]，原因：
///   1. 更新检查必须在用户登录之前就能跑（启动门禁阶段）；
///   2. 不需要 Authorization 头，也不应该被 401 拦截逻辑覆盖；
///   3. 超时时间更短（5 秒），避免冷启动阶段被慢响应阻塞；
///   4. 任何 426/401 拦截器都不应打断未登录时的版本检查。
///
/// 调用方应该捕获 [AppUpdateApiException] 和 [DioException]：
///   - [DioException] 表示网络层失败（断网、5xx、超时）；
///   - [AppUpdateApiException] 表示服务端响应未通过协议校验（非 200、协议
///     字段缺失、JSON 解析失败等）。
class AppUpdateApi {
  static const String _updatePath = '/app/update';

  final Dio _dio;

  /// 构造 API 客户端。如不传入 [Dio]，则按更新检查专用策略创建独立实例。
  ///
  /// 测试可通过构造函数注入 mock Dio；生产代码使用默认实例。
  AppUpdateApi({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: ApiConstants.baseUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 5),
                sendTimeout: const Duration(seconds: 5),
                // 服务端默认返回 application/json；这里保持 dio 自动解析。
                responseType: ResponseType.json,
                validateStatus: (status) =>
                    status != null && status >= 200 && status < 300,
              ),
            );

  /// 查询当前客户端版本的更新策略。
  ///
  /// 服务端同时接受 query 和请求头，这里同时发送两者，让中间链路（CDN、
  /// 反代日志）任何一处都能读到 versionCode，便于排障。
  Future<AppUpdateInfo> checkUpdate({
    required String platform,
    required String channel,
    required String versionName,
    required int versionCode,
  }) async {
    if (platform.isEmpty) {
      throw const AppUpdateApiException('platform 不能为空');
    }
    if (channel.isEmpty) {
      throw const AppUpdateApiException('channel 不能为空');
    }
    if (versionName.isEmpty) {
      throw const AppUpdateApiException('version_name 不能为空');
    }
    if (versionCode <= 0) {
      throw AppUpdateApiException('version_code 必须为正，收到: $versionCode');
    }

    final versionCodeString = versionCode.toString();

    try {
      final response = await _dio.get(
        _updatePath,
        queryParameters: {
          'platform': platform,
          'channel': channel,
          'version_name': versionName,
          'version_code': versionCodeString,
        },
        options: Options(
          headers: {
            'X-App-Platform': platform,
            'X-App-Channel': channel,
            'X-App-Version-Name': versionName,
            'X-App-Version-Code': versionCodeString,
          },
          // 不携带 Authorization 头；更新检查是公开接口。
          // 也不走全局 426 兜底拦截器，由调用方按响应内容判断。
          extra: const {'skip_app_version_interceptor': true},
        ),
      );

      if (response.statusCode != 200) {
        throw AppUpdateApiException(
          '版本检查失败: HTTP ${response.statusCode}',
        );
      }
      if (response.data is! Map<String, dynamic>) {
        throw AppUpdateApiException(
          '版本检查响应格式错误: ${response.data.runtimeType}',
        );
      }
      // 服务端 400 直接通过状态码拦截；走到这里说明 HTTP 已 200，把 JSON
      // 解析交由 AppUpdateInfo.fromJson 的严格校验完成。
      try {
        return AppUpdateInfo.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
      } on FormatException catch (e) {
        throw AppUpdateApiException('版本检查响应字段非法: ${e.message}');
      }
    } on DioException catch (e) {
      // 5xx / 超时 / 断网 — 上层按更新策略区分处理，不打成 "无更新"。
      throw AppUpdateApiException.dio(e);
    }
  }
}

/// 应用更新 API 错误。区分于 [DioException] 的存在意义：
/// 调用方需要根据"网络异常"和"协议异常"采用不同的降级策略。
class AppUpdateApiException implements Exception {
  /// 错误类别。便于调用方按分支决策。
  final AppUpdateApiErrorKind kind;

  /// 用户可读的错误信息。
  final String message;

  /// 原始 Dio 异常（如果有）。
  final DioException? dioException;

  const AppUpdateApiException(
    this.message, {
    this.kind = AppUpdateApiErrorKind.protocol,
    this.dioException,
  });

  AppUpdateApiException.dio(DioException e)
      : kind = _dioKindOf(e),
        message = _dioMessageOf(e),
        dioException = e;

  @override
  String toString() => 'AppUpdateApiException($kind): $message';
}

/// 应用更新 API 错误分类。
enum AppUpdateApiErrorKind {
  /// 协议级错误：非 200 状态码、字段非法、JSON 解析失败。
  protocol,

  /// 网络层错误：连接超时、读超时、断网。
  network,

  /// 服务端错误：5xx（包括 503 update_check_unavailable）。
  server,

  /// 客户端请求错误：4xx（理论上不应发生，调用方传参错）。
  client,
}

AppUpdateApiErrorKind _dioKindOf(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return AppUpdateApiErrorKind.network;
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode ?? 0;
      if (status >= 500) return AppUpdateApiErrorKind.server;
      return AppUpdateApiErrorKind.client;
    case DioExceptionType.cancel:
    case DioExceptionType.badCertificate:
    case DioExceptionType.unknown:
    case DioExceptionType.transformTimeout:
      return AppUpdateApiErrorKind.protocol;
  }
}

String _dioMessageOf(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
      return '连接超时，请检查网络后重试';
    case DioExceptionType.sendTimeout:
      return '请求发送超时';
    case DioExceptionType.receiveTimeout:
      return '响应超时，请稍后重试';
    case DioExceptionType.connectionError:
      return '网络连接失败';
    case DioExceptionType.badResponse:
      return '服务端返回 HTTP ${e.response?.statusCode ?? 0}';
    case DioExceptionType.cancel:
      return '请求已取消';
    case DioExceptionType.badCertificate:
    case DioExceptionType.unknown:
    case DioExceptionType.transformTimeout:
      return e.message?.isNotEmpty == true ? e.message! : '未知错误';
  }
}