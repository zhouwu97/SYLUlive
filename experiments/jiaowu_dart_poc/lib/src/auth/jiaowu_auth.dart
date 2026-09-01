import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../error/jiaowu_exception.dart';
import '../model/login_result.dart';
import '../model/rsa_public_key.dart';
import '../network/transport_error_mapper.dart';
import '../parser/error_parser.dart';
import '../parser/profile_parser.dart';
import '../session/jiaowu_session.dart';
import 'csrf_parser.dart';
import 'login_page_detector.dart';
import 'rsa_encryptor.dart';

/// 登录编排器。它只使用传入的 Dio 和 CookieJar，不创建第二套会话。
final class JiaowuAuth {
  JiaowuAuth({
    required Dio dio,
    required CookieJar cookieJar,
    required JiaowuSession session,
  })  : _dio = dio,
        _cookieJar = cookieJar,
        _session = session;

  final Dio _dio;
  final CookieJar _cookieJar;
  final JiaowuSession _session;

  Future<String> getCsrfToken() async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        var response = await _dio.get<String>(
          JiaowuEndpoints.loginPage,
          options: _plainOptions(JiaowuHeaders.loginPage),
        );
        if (response.statusCode == 302) {
          response = await _dio.get<String>(
            JiaowuEndpoints.loginPage,
            options: _plainOptions(JiaowuHeaders.loginPage),
          );
        }

        final status = response.statusCode ?? 0;
        if (status != 200) {
          throw NetworkException(
            message: '获取 CSRF 失败，学校返回状态码 $status',
            code: 'CSRF_FETCH_FAILED',
          );
        }
        return CsrfParser.parse(_responseText(response));
      } on DioException catch (error) {
        if (TransportErrorMapper.isTimeout(error) && attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        throw TransportErrorMapper.map(error, '获取 CSRF');
      }
    }
    throw const NetworkException(message: '获取 CSRF 失败');
  }

  Future<RsaPublicKeyData> getPublicKey() async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await _dio.get<String>(
        JiaowuEndpoints.publicKey,
        queryParameters: <String, String>{'time': timestamp, '_': timestamp},
        options: _plainOptions(JiaowuHeaders.base),
      );
      final status = response.statusCode ?? 0;
      if (status != 200) {
        throw NetworkException(
          message: '获取教务登录公钥失败，学校返回状态码 $status',
          code: 'PUBLIC_KEY_FETCH_FAILED',
        );
      }

      final decoded = jsonDecode(_responseText(response));
      if (decoded is! Map<String, dynamic>) {
        throw const LoginPageChangedException(
          message: '学校登录公钥响应结构发生变化',
        );
      }
      final modulus = decoded['modulus'];
      final exponent = decoded['exponent'];
      if (modulus is! String ||
          exponent is! String ||
          modulus.isEmpty ||
          exponent.isEmpty) {
        throw const LoginPageChangedException(
          message: '学校登录公钥参数缺失，请稍后重试或联系管理员',
        );
      }
      return RsaPublicKeyData(modulus: modulus, exponent: exponent);
    } on JiaowuException {
      rethrow;
    } on DioException catch (error) {
      throw TransportErrorMapper.map(error, '获取登录公钥');
    } on FormatException catch (error) {
      throw LoginPageChangedException(
        message: '学校登录公钥响应无法解析，请稍后重试或联系管理员',
        cause: error,
      );
    }
  }

  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    // 每次显式 login 都是 fresh login，避免账号切换或重复登录复用旧 Cookie。
    await _session.resetSession(_cookieJar);
    _session.beginLogin(studentId);
    try {
      final csrfToken = await getCsrfToken();
      final publicKey = await getPublicKey();
      final encryptedPassword = RsaEncryptor.encryptWithKey(
        password: password,
        key: publicKey,
      );
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await _dio.post<String>(
        JiaowuEndpoints.loginPage,
        queryParameters: {'time': timestamp},
        data: <String, String>{
          'csrftoken': csrfToken,
          'language': 'zh_CN',
          'yhm': studentId,
          'mm': encryptedPassword,
        },
        options: _plainOptions({
          ...JiaowuHeaders.base,
          'Accept': JiaowuHeaders.htmlAccept,
        }),
      );

      final body = _responseText(response);
      final alert = ErrorParser.alertMessage(body);
      if (ErrorParser.captchaRequired(body)) {
        throw const CaptchaRequiredException();
      }
      if (ErrorParser.credentialErrorMessage(alert ?? body) != null) {
        throw const InvalidCredentialsException();
      }
      if (alert != null && alert.isNotEmpty) {
        throw const LoginPageChangedException(
          message: '学校登录流程返回未识别提示，请稍后重试或联系管理员',
        );
      }

      final status = response.statusCode ?? 0;
      if (status == 901) {
        throw const LoginPageChangedException(message: '学校登录流程返回 901');
      }
      if (status != 200 && status != 302) {
        throw NetworkException(
          message: '登录请求失败，学校返回状态码 $status',
          code: 'LOGIN_REQUEST_FAILED',
        );
      }

      // 302 只能说明发生了跳转；最终成功必须由同一 CookieJar 的探活确认。
      final cookieNames = await _cookieNames();
      final probeSucceeded = await _verifyLoginCookie(studentId);
      if (probeSucceeded && cookieNames.isNotEmpty) {
        _session.markAuthenticated();
        return LoginSuccess(
          studentId: studentId,
          cookieNames: cookieNames,
        );
      }

      throw const LoginPageChangedException(
        message: '教务登录会话建立失败，请稍后重试',
      );
    } on InvalidCredentialsException catch (error) {
      await _session.resetSession(_cookieJar);
      return InvalidCredentials(message: error.message);
    } on CaptchaRequiredException catch (error) {
      // 验证码后续流程需要保留当前 Cookie 绑定，仅清理内存状态。
      _session.clearState();
      return CaptchaRequired(message: error.message);
    } on DioException catch (error) {
      _session.clearState();
      final mapped = TransportErrorMapper.map(error, '登录');
      return NetworkUnavailable(message: mapped.message, cause: mapped);
    } on NetworkException catch (error) {
      _session.clearState();
      return NetworkUnavailable(message: error.message, cause: error);
    } on JiaowuException catch (error) {
      _session.clearState();
      return LoginPageChanged(message: error.message, cause: error);
    }
  }

  Future<bool> _verifyLoginCookie(String studentId) async {
    final cookieNames = await _cookieNames();
    if (cookieNames.isEmpty) return false;

    try {
      final profileResponse = await _dio.get<String>(
        JiaowuEndpoints.studentInfo,
        queryParameters: {
          'gnmkdm': 'N100801',
          'layout': 'default',
          'su': studentId,
        },
        options: _plainOptions(JiaowuHeaders.profile),
      );
      final profileBody = _responseText(profileResponse);
      if (profileResponse.statusCode == 200 &&
          !LoginPageDetector.isLoginPage(profileBody) &&
          ProfileParser.hasAnyFields(profileBody)) {
        return true;
      }

      final menuResponse = await _dio.get<String>(
        JiaowuEndpoints.initMenu,
        options: _plainOptions({
          ...JiaowuHeaders.menu,
          'Referer': '${_dio.options.baseUrl}${JiaowuEndpoints.loginPage}',
        }),
      );
      final menuBody = _responseText(menuResponse);
      if (menuResponse.statusCode == 200 &&
          !LoginPageDetector.isLoginPage(menuBody) &&
          _hasHomepageFields(menuBody)) {
        return true;
      }
      if (menuResponse.statusCode == 302) {
        final location = menuResponse.headers.value('location') ?? '';
        return _isSuccessfulLocation(location);
      }
    } on DioException catch (error) {
      throw TransportErrorMapper.map(error, '登录探活');
    }
    return false;
  }

  Future<Set<String>> _cookieNames() async {
    final baseUrl = _dio.options.baseUrl;
    final uri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    final cookies = await _cookieJar.loadForRequest(uri);
    return cookies.map((cookie) => cookie.name).toSet();
  }

  static Options _plainOptions(Map<String, String> headers) => Options(
        headers: headers,
        responseType: ResponseType.plain,
        followRedirects: false,
      );

  static String _responseText(Response<String> response) => response.data ?? '';

  static bool _isSuccessfulLocation(String location) {
    final lower = location.toLowerCase();
    return (lower.contains('index_initmenu') || lower.contains('/index')) &&
        !lower.contains('login_slogin');
  }

  static bool _hasHomepageFields(String body) {
    if (LoginPageDetector.isLoginPage(body)) return false;
    const tokens = [
      '退出',
      '个人信息',
      '学生',
      '课表',
      '成绩',
      '学籍',
      'index_initMenu',
      'gnmkdm'
    ];
    return tokens.where(body.contains).length >= 2;
  }
}
