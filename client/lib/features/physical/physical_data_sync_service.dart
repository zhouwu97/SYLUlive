import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../utils/sign_utils.dart';
import '../campus_data/storage/physical_cache_store.dart';

class PhysicalDataSyncResult {
  const PhysicalDataSyncResult._({
    required this.success,
    required this.errorCode,
  });

  const PhysicalDataSyncResult.success()
      : this._(success: true, errorCode: null);

  const PhysicalDataSyncResult.failure(String code)
      : this._(success: false, errorCode: code);

  final bool success;
  final String? errorCode;
}

/// 体测设备刷新器，只写入当前账号的 AES-GCM 快照。
///
/// 密码仅存在于本次调用内存中；是否持久化由上层系统安全存储策略决定。
class PhysicalDataSyncService {
  PhysicalDataSyncService({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                headers: _headers,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
              ),
            ) {
    if (_ownsDio) _dio.interceptors.add(CookieManager(CookieJar()));
  }

  static const String _baseUrl = 'http://47.92.231.221';
  static const Map<String, String> _headers = <String, String>{
    'X-Requested-With': 'com.wisedu.cpdaily',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.43 Mobile Safari/537.36',
    'Content-Type': 'application/json;charset=UTF-8',
  };

  final Dio _dio;
  final bool _ownsDio;

  Future<PhysicalDataSyncResult> syncLatest({
    required String appUserId,
    required String sourceAccountId,
    required String password,
  }) async {
    if (appUserId.trim().isEmpty ||
        sourceAccountId.trim().isEmpty ||
        password.isEmpty) {
      return const PhysicalDataSyncResult.failure('credential_unavailable');
    }
    _PhysicalLogin? login;
    try {
      login = await _login(sourceAccountId.trim(), password);
    } on DioException {
      return const PhysicalDataSyncResult.failure('network_unavailable');
    } catch (_) {
      return const PhysicalDataSyncResult.failure('physical_refresh_failed');
    }
    if (login == null) {
      return const PhysicalDataSyncResult.failure(
        'physical_credential_invalid',
      );
    }

    final now = DateTime.now();
    final fallbackYear = (now.month >= 9 ? now.year + 1 : now.year).toString();
    final year = login.schoolYear?.trim().isNotEmpty == true
        ? login.schoolYear!.trim()
        : fallbackYear;
    try {
      final request = <String, dynamic>{
        'user_id': login.userId,
        'school_year': year,
      };
      request['sign'] = SignUtils.generateSign(request);
      final response = await _dio.post<dynamic>(
        '/service/mobile/gymResult/selectUserPlanScore',
        data: request,
        options: Options(
          headers: <String, String>{
            'Authorization': login.token,
            'Cookie': 'userid=${login.userId}',
          },
        ),
      );
      final body = _decodeMap(response.data);
      final data = body?['data'];
      if (response.statusCode != 200 || data is! Map) {
        return const PhysicalDataSyncResult.failure('physical_refresh_failed');
      }
      final rawScores = data['data_arr'];
      final scores = rawScores is List
          ? rawScores.whereType<Map>().map(_normalizeScore).toList()
          : <Map<String, dynamic>>[];
      await PhysicalCacheStore(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ).writeYear(year, <String, dynamic>{
        'total_grade': data['total_grade']?.toString() ?? '',
        'total_score': _number(data['total_score']),
        'scores': scores,
      });
      return const PhysicalDataSyncResult.success();
    } on DioException {
      return const PhysicalDataSyncResult.failure('network_unavailable');
    } catch (_) {
      return const PhysicalDataSyncResult.failure('physical_refresh_failed');
    }
  }

  Future<_PhysicalLogin?> _login(String username, String password) async {
    final request = <String, dynamic>{
      'username': username,
      'password': md5.convert(utf8.encode(password)).toString(),
      'sys_id': 'iscpMobile',
      'nonceStr': '',
      'captchaValue': '',
    };
    request['sign'] = SignUtils.generateSign(request);
    try {
      final response = await _dio.post<dynamic>(
        '/service/login/mobile/check',
        data: request,
      );
      if (response.statusCode != 200) return null;
      final body = _decodeMap(response.data);
      if (body == null) return null;
      final nested = body['data'] is Map
          ? Map<String, dynamic>.from(body['data'] as Map)
          : const <String, dynamic>{};
      String? userId;
      for (final key in const <String>['user_id', 'userId', 'id']) {
        userId ??= body[key]?.toString();
        userId ??= nested[key]?.toString();
      }
      if (userId == null || userId.trim().isEmpty) {
        for (final cookie
            in response.headers['set-cookie'] ?? const <String>[]) {
          userId ??= RegExp(r'userid=([^;]+)').firstMatch(cookie)?.group(1);
        }
      }
      if (userId == null || userId.trim().isEmpty) return null;
      final token = (body['token'] ?? nested['token'])?.toString().trim();
      final schoolYear =
          (body['school_date'] ?? nested['school_date'])?.toString();
      return _PhysicalLogin(
        userId: userId,
        token: token == null || token.isEmpty ? userId : token,
        schoolYear: schoolYear,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        return null;
      }
      rethrow;
    }
  }

  static Map<String, dynamic>? _decodeMap(Object? value) {
    Object? decoded = value;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return null;
      }
    }
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  static Map<String, dynamic> _normalizeScore(Map<dynamic, dynamic> raw) {
    String name = raw['sub_name']?.toString() ?? '';
    if (name == '1000') name = '1000 米跑';
    if (name == '800') name = '800 米跑';
    name = name.replaceAll('50米跑', '50 米跑');
    var result = '${raw['result'] ?? ''} ${raw['unit'] ?? ''}'.trim();
    result = result
        .replaceAll('ml', 'mL')
        .replaceAll('times', '次')
        .replaceAll(' min', ' 分钟');
    return <String, dynamic>{
      'sub_name': name,
      'result': result,
      'grade': raw['grade']?.toString() ?? '',
      'score': _number(raw['score']).round(),
    };
  }

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  void close() {
    if (_ownsDio) _dio.close(force: true);
  }
}

class _PhysicalLogin {
  const _PhysicalLogin({
    required this.userId,
    required this.token,
    this.schoolYear,
  });

  final String userId;
  final String token;
  final String? schoolYear;
}
