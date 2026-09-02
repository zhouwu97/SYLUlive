import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../error/jiaowu_exception.dart';
import '../model/captcha_challenge.dart';
import '../model/login_result.dart';
import '../model/rsa_public_key.dart';
import '../network/transport_error_mapper.dart';
import '../parser/error_parser.dart';
import '../parser/profile_parser.dart';
import '../session/jiaowu_session.dart';
import '../session/session_state.dart';
import 'csrf_parser.dart';
import 'login_page_detector.dart';
import 'pending_login.dart';
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
  static const _captchaTtl = Duration(minutes: 3);
  PendingLogin? _pendingLogin;

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

  /// 获取当前 pending 登录会话绑定的验证码图片。
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    final pending = await _requirePendingLogin();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await _dio.get<List<int>>(
        JiaowuEndpoints.captcha,
        queryParameters: <String, String>{'time': timestamp},
        options: Options(
          headers: JiaowuHeaders.loginPage,
          responseType: ResponseType.bytes,
          followRedirects: false,
        ),
      );
      final bytes = Uint8List.fromList(response.data ?? const <int>[]);
      final status = response.statusCode ?? 0;
      if (status == 302 || _looksLikeLoginPage(bytes)) {
        await cancelPendingLogin();
        throw const CaptchaExpiredException();
      }
      if (status != 200 || bytes.isEmpty || !_looksLikeImage(response, bytes)) {
        throw const LoginPageChangedException(
          message: '验证码图片响应无法识别，请稍后重试',
        );
      }

      // 刷新验证码会延长当前 pending challenge 的短 TTL，但不会刷新 Session。
      _pendingLogin = pending.refreshedAt(DateTime.now());
      return CaptchaChallenge(imageBytes: bytes);
    } on JiaowuException {
      rethrow;
    } on DioException catch (error) {
      throw TransportErrorMapper.map(error, '获取验证码');
    }
  }

  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    // 每次显式 login 都是 fresh login，避免账号切换或重复登录复用旧 Cookie。
    await _session.resetSession(_cookieJar);
    _pendingLogin = null;
    _session.beginLogin(studentId);
    try {
      final csrfToken = await getCsrfToken();
      final publicKey = await getPublicKey();
      final response = await _postLogin(
        studentId: studentId,
        password: password,
        csrfToken: csrfToken,
        publicKey: publicKey,
      );
      final body = _responseText(response);
      if (ErrorParser.captchaRequired(body)) {
        _pendingLogin = PendingLogin(
          studentId: studentId,
          password: password,
          csrfToken: csrfToken,
          createdAt: DateTime.now(),
        );
        _session.awaitCaptcha(studentId);
        return CaptchaRequired(message: ErrorParser.captchaMessage(body));
      }
      return await _finishLoginResponse(response, studentId);
    } on InvalidCredentialsException catch (error) {
      await _session.resetSession(_cookieJar);
      _pendingLogin = null;
      return InvalidCredentials(message: error.message);
    } on DioException catch (error) {
      _session.clearState();
      _pendingLogin = null;
      final mapped = TransportErrorMapper.map(error, '登录');
      return NetworkUnavailable(message: mapped.message, cause: mapped);
    } on NetworkException catch (error) {
      _session.clearState();
      _pendingLogin = null;
      return NetworkUnavailable(message: error.message, cause: error);
    } on JiaowuException catch (error) {
      _session.clearState();
      _pendingLogin = null;
      return LoginPageChanged(message: error.message, cause: error);
    }
  }

  /// 在不清除当前 CookieJar 的前提下提交验证码。
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    final pending = await _pendingForContinuation();
    if (pending == null) {
      return const CaptchaExpired(message: '验证码会话已失效，请重新登录');
    }
    final normalizedCode = code.trim();
    if (normalizedCode.isEmpty) {
      _session.awaitCaptcha(pending.studentId);
      return const CaptchaRequired(message: '请输入验证码');
    }

    _session.beginLogin(pending.studentId);
    try {
      // 公钥可轮换，续登重新获取公钥，但不重新 GET 登录页、不清 Cookie。
      final publicKey = await getPublicKey();
      final response = await _postLogin(
        studentId: pending.studentId,
        password: pending.password,
        csrfToken: pending.csrfToken,
        publicKey: publicKey,
        captchaCode: normalizedCode,
      );
      final body = _responseText(response);
      if (ErrorParser.captchaRequired(body)) {
        _pendingLogin = pending.refreshedAt(DateTime.now());
        _session.awaitCaptcha(pending.studentId);
        return CaptchaRequired(message: ErrorParser.captchaMessage(body));
      }
      return await _finishLoginResponse(response, pending.studentId);
    } on InvalidCredentialsException catch (error) {
      await cancelPendingLogin();
      return InvalidCredentials(message: error.message);
    } on DioException catch (error) {
      _session.awaitCaptcha(pending.studentId);
      final mapped = TransportErrorMapper.map(error, '提交验证码');
      return NetworkUnavailable(message: mapped.message, cause: mapped);
    } on NetworkException catch (error) {
      _session.awaitCaptcha(pending.studentId);
      return NetworkUnavailable(message: error.message, cause: error);
    } on JiaowuException catch (error) {
      _session.awaitCaptcha(pending.studentId);
      return LoginPageChanged(message: error.message, cause: error);
    }
  }

  /// 取消验证码流程并清理整套教务 Session。
  Future<void> cancelPendingLogin() async {
    _pendingLogin = null;
    await _session.resetSession(_cookieJar);
  }

  Future<Response<String>> _postLogin({
    required String studentId,
    required String password,
    required String csrfToken,
    required RsaPublicKeyData publicKey,
    String? captchaCode,
  }) {
    final encryptedPassword = RsaEncryptor.encryptWithKey(
      password: password,
      key: publicKey,
    );
    final data = <String, String>{
      'csrftoken': csrfToken,
      'language': 'zh_CN',
      'yhm': studentId,
      'mm': encryptedPassword,
    };
    if (captchaCode != null) data['yzm'] = captchaCode;
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    return _dio.post<String>(
      JiaowuEndpoints.loginPage,
      queryParameters: {'time': timestamp},
      data: data,
      options: _plainOptions({
        ...JiaowuHeaders.base,
        'Accept': JiaowuHeaders.htmlAccept,
      }),
    );
  }

  Future<LoginResult> _finishLoginResponse(
    Response<String> response,
    String studentId,
  ) async {
    final body = _responseText(response);
    final alert = ErrorParser.alertMessage(body);
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
      _pendingLogin = null;
      _session.markAuthenticated();
      return LoginSuccess(studentId: studentId, cookieNames: cookieNames);
    }

    throw const LoginPageChangedException(
      message: '教务登录会话建立失败，请稍后重试',
    );
  }

  Future<PendingLogin?> _pendingForContinuation() async {
    final pending = _pendingLogin;
    if (pending == null || _session.state != SessionState.awaitingCaptcha) {
      return null;
    }
    if (DateTime.now().difference(pending.createdAt) > _captchaTtl) {
      await cancelPendingLogin();
      return null;
    }
    return pending;
  }

  Future<PendingLogin> _requirePendingLogin() async {
    final pending = await _pendingForContinuation();
    if (pending == null) {
      throw const CaptchaExpiredException();
    }
    return pending;
  }

  static bool _looksLikeLoginPage(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final text = utf8.decode(bytes, allowMalformed: true);
    return LoginPageDetector.isLoginPage(text);
  }

  static bool _looksLikeImage(Response<List<int>> response, Uint8List bytes) {
    final contentType = response.headers.value(Headers.contentTypeHeader);
    if (contentType != null && contentType.toLowerCase().startsWith('image/')) {
      return true;
    }
    return _hasImageSignature(bytes);
  }

  static bool _hasImageSignature(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return true;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return true;
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return true;
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
      return true;
    }
    return bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
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
