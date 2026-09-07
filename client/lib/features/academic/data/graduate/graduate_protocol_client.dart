import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/parser.dart' show parse, parseFragment;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';

/// 研究生系统固定目标，禁止由调用方传入任意 base URL。
const graduatePortalBaseUrl = 'https://yjsgl.sylu.edu.cn';
const graduateProtocolVersion = 1;
const graduateScheduleParserVersion = 1;
const _aesKey = 'southsoft12345!#';

abstract interface class GraduateProtocolGateway {
  Future<GraduateCaptcha> prepareLogin();
  Future<GraduateCaptcha> refreshCaptcha();
  Future<void> login({
    required String studentId,
    required String password,
    required String captchaCode,
  });
  Future<List<GraduateTerm>> fetchTerms();
  Future<GraduateSchedule> fetchSchedule(String termCode);
  Future<GraduateProfile> fetchProfile();
  Future<GraduateSessionState> probe();
  Future<GraduateSessionArtifactState?> exportSession();
  Future<void> restoreSession(GraduateSessionArtifactState artifact);
  Future<void> reset();
  void close();
}

final class GraduatePortalException implements Exception {
  const GraduatePortalException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'GraduatePortalException($code)';
}

final class GraduateCaptcha {
  GraduateCaptcha(Uint8List imageBytes, {this.challengeId})
      : imageBytes = Uint8List.fromList(imageBytes);

  final Uint8List imageBytes;
  final String? challengeId;
}

final class GraduateTerm {
  const GraduateTerm({
    required this.code,
    required this.name,
    required this.selected,
  });

  final String code;
  final String name;
  final bool selected;

  factory GraduateTerm.fromJson(Map<String, dynamic> json) {
    final code = json['termcode']?.toString().trim() ?? '';
    if (code.isEmpty) {
      throw const GraduatePortalException('TERM_FORMAT_CHANGED', '学期列表缺少 termcode');
    }
    return GraduateTerm(
      code: code,
      name: (json['termname'] ?? json['mc'] ?? code).toString().trim(),
      selected: _isTrue(json['selected']),
    );
  }
}

final class GraduateSchedule {
  const GraduateSchedule({required this.slots});

  final List<GraduateCourseSlot> slots;
}

final class GraduateCourseSlot {
  const GraduateCourseSlot({
    required this.dayOfWeek,
    required this.periodOrder,
    required this.periodLabel,
    required this.courses,
  });

  final int dayOfWeek;
  final int periodOrder;
  final String periodLabel;
  final List<GraduateCourse> courses;
}

final class GraduateCourse {
  const GraduateCourse({
    required this.name,
    required this.weeks,
    required this.teacher,
    required this.location,
  });

  final String name;
  final String weeks;
  final String teacher;
  final String location;
}

final class GraduateSessionState {
  const GraduateSessionState({required this.authenticated, this.studentId});

  final bool authenticated;
  final String? studentId;
}

final class GraduateProfile {
  const GraduateProfile({this.studentId, this.name});

  final String? studentId;
  final String? name;

  /// 解析学校已验证的个人资料响应。当前接口返回单元素数组，兼容同一
  /// 资料在少数部署中直接返回对象的形式；身份字段只认学校返回的 xh。
  factory GraduateProfile.fromDecoded(dynamic decoded) {
    final profileMap = decoded is List && decoded.length == 1
        ? decoded.first
        : decoded;
    if (profileMap is! Map) {
      throw const GraduatePortalException(
        'PROFILE_RESPONSE_INVALID',
        '学校学生信息格式已变化',
      );
    }
    final data = Map<String, dynamic>.from(profileMap);
    String? text(String key) {
      final value = data[key]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }
    return GraduateProfile(studentId: text('xh'), name: text('xm'));
  }
}

/// Cookie 和 URL Session Prefix 都属于会话能力材料，统一作为不可读 opaque
/// state 交给上层加密存储；此类型不提供日志或明文导出接口。
final class GraduateSessionArtifactState {
  const GraduateSessionArtifactState({
    required this.cookies,
    required this.sessionPathPrefix,
    required this.createdAt,
    this.validatedAt,
  });

  final List<String> cookies;
  final String sessionPathPrefix;
  final DateTime createdAt;
  final DateTime? validatedAt;
}

/// 研究生协议客户端，每个实例绑定一个身份并独占 Dio/CookieJar。
final class GraduateProtocolClient implements GraduateProtocolGateway {
  GraduateProtocolClient({Dio? dio, CookieJar? cookieJar})
      : _dio = dio ?? _newDio(),
        _cookieJar = cookieJar ?? CookieJar() {
    _dio.interceptors.add(CookieManager(_cookieJar));
  }

  final Dio _dio;
  final CookieJar _cookieJar;
  final Uri _baseUri = Uri.parse(graduatePortalBaseUrl);
  String _loginPageUrl = '$graduatePortalBaseUrl/home/stulogin';
  String _sessionPathPrefix = '';
  String? _publicKeyPem;
  bool _authenticated = false;
  bool _closed = false;

  static Dio _newDio() => Dio(
        BaseOptions(
          baseUrl: graduatePortalBaseUrl,
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          followRedirects: false,
          validateStatus: (status) => status != null && status >= 200 && status < 500,
          headers: const {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
            'Accept-Language': 'zh-CN,zh;q=0.9',
          },
        ),
      );

  @override
  Future<GraduateCaptcha> prepareLogin() async {
    _ensureOpen();
    await _cookieJar.deleteAll();
    _publicKeyPem = null;
    _sessionPathPrefix = '';
    _authenticated = false;
    _loginPageUrl = '$graduatePortalBaseUrl/home/stulogin';
    final response = await _openLoginPage();
    final pem = parse(response.data ?? '').querySelector('#pubkey')?.attributes['value']?.trim();
    if (pem == null ||
        !RegExp(r'-----BEGIN (RSA )?PUBLIC KEY-----').hasMatch(pem)) {
      throw const GraduatePortalException('LOGIN_PAGE_CHANGED', '登录页未找到 RSA 公钥');
    }
    _publicKeyPem = pem;
    return refreshCaptcha();
  }

  @override
  Future<GraduateCaptcha> refreshCaptcha() async {
    _ensureOpen();
    if (_publicKeyPem == null) {
      throw const GraduatePortalException('LOGIN_NOT_PREPARED', '请先获取验证码');
    }
    final response = await _dio.get<List<int>>(
      _portalPath('/home/verificationcode'),
      queryParameters: {'codetype': 'stucode', 't': DateTime.now().millisecondsSinceEpoch},
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Referer': _loginPageUrl},
      ),
    );
    _requireSuccess(response, '获取验证码');
    final bytes = response.data;
    final contentType = response.headers.value(Headers.contentTypeHeader) ?? '';
    if (bytes == null || bytes.length < 100 || !contentType.toLowerCase().contains('image')) {
      throw const GraduatePortalException('CAPTCHA_RESPONSE_INVALID', '学校未返回有效验证码图片');
    }
    return GraduateCaptcha(Uint8List.fromList(bytes));
  }

  @override
  Future<void> login({
    required String studentId,
    required String password,
    required String captchaCode,
  }) async {
    _ensureOpen();
    final publicKey = _publicKeyPem;
    final id = studentId.trim();
    final captcha = captchaCode.trim();
    if (publicKey == null) throw const GraduatePortalException('LOGIN_NOT_PREPARED', '请先获取验证码');
    if (id.isEmpty || password.isEmpty || captcha.isEmpty) {
      throw const GraduatePortalException('LOGIN_INPUT_INVALID', '请填写学号、密码和验证码');
    }
    final body = jsonEncode({
      'UserId': id,
      'Password': GraduateAuthCodec.encryptPassword(password, publicKey),
      'VeriCode': int.tryParse(captcha) ?? captcha,
      'url': '',
      'city': '',
    });
    final response = await _dio.post<String>(
      _portalPath('/home/stulogin_do'),
      data: {'json': body},
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Referer': _loginPageUrl, 'X-Requested-With': 'XMLHttpRequest'},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    _requireSuccess(response, '登录');
    final decoded = GraduateResponseCodec.decode(response.data ?? '');
    if (decoded is! Map) throw const GraduatePortalException('LOGIN_RESPONSE_INVALID', '学校登录响应格式无法识别');
    final result = Map<String, dynamic>.from(decoded);
    if (result['jg']?.toString() != '1') {
      final message = result['msg']?.toString().trim() ?? '';
      throw GraduatePortalException(
        GraduateAuthDetector.classify(message).code,
        message.isEmpty ? '账号、密码或验证码错误' : message,
      );
    }
    _authenticated = true;
  }

  @override
  Future<List<GraduateTerm>> fetchTerms() async {
    final decoded = await _getDecoded('/student/default/bindterm', '获取学期列表');
    if (decoded is! List) throw const GraduatePortalException('TERM_RESPONSE_INVALID', '学校学期列表格式已变化');
    final terms = decoded.whereType<Map>().map((item) => GraduateTerm.fromJson(Map<String, dynamic>.from(item))).toList(growable: false);
    if (terms.isEmpty) throw const GraduatePortalException('TERM_RESPONSE_EMPTY', '学校未返回可用学期');
    return terms;
  }

  @override
  Future<GraduateSchedule> fetchSchedule(String termCode) async {
    final code = termCode.trim();
    if (code.isEmpty) throw const GraduatePortalException('TERM_REQUIRED', '请选择学期');
    final response = await _dio.post<String>(
      _portalPath('/student/pygl/py_kbcx_ew'),
      data: {'kblx': 'xs', 'termcode': code},
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Referer': _loginPageUrl, 'X-Requested-With': 'XMLHttpRequest'},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    _requireSuccess(response, '拉取课表');
    return GraduateScheduleParser.parse(GraduateResponseCodec.decode(response.data ?? ''));
  }

  @override
  Future<GraduateProfile> fetchProfile() async {
    dynamic decoded;
    try {
      decoded = await _getDecoded('/student/default/getxscardinfo', '获取学生信息');
    } on GraduatePortalException {
      // 学校当前版本在 POST 空表单时也返回同一资料；仅用于兼容已验证的
      // GET/POST 差异，仍然经过同一 Cookie 和响应解码器。
      decoded = await _postDecoded('/student/default/getxscardinfo', '获取学生信息');
    }
    // 研究生探针已确认 xh/xm 是当前个人资料契约，其他字段不作为身份
    // 证据，避免把登录请求中的本地学号误当作学校确认结果。
    return GraduateProfile.fromDecoded(decoded);
  }

  @override
  Future<GraduateSessionState> probe() async {
    _ensureOpen();
    if (!_authenticated) return const GraduateSessionState(authenticated: false);
    try {
      // 只有学校返回的已认证个人资料才可通过身份门；本地保存的学号不构成证明。
      final profile = await fetchProfile();
      final confirmedId = profile.studentId?.trim();
      return GraduateSessionState(
        authenticated: confirmedId != null && confirmedId.isNotEmpty,
        studentId: confirmedId,
      );
    } on GraduatePortalException catch (error) {
      if (error.code.startsWith('LOGIN_') || error.code == 'SESSION_EXPIRED') {
        _authenticated = false;
        return const GraduateSessionState(authenticated: false);
      }
      rethrow;
    }
  }

  @override
  Future<GraduateSessionArtifactState?> exportSession() async {
    _ensureOpen();
    if (!_authenticated) return null;
    final cookies = await _cookieJar.loadForRequest(_baseUri);
    return GraduateSessionArtifactState(
      cookies: cookies.map((cookie) => cookie.toString()).toList(growable: false),
      sessionPathPrefix: _sessionPathPrefix,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> restoreSession(GraduateSessionArtifactState artifact) async {
    _ensureOpen();
    await _cookieJar.deleteAll();
    final cookies = <Cookie>[];
    for (final value in artifact.cookies) {
      try {
        cookies.add(Cookie.fromSetCookieValue(value));
      } on FormatException {
        throw const GraduatePortalException('SESSION_ARTIFACT_INVALID', '研究生会话材料格式无效');
      }
    }
    await _cookieJar.saveFromResponse(_baseUri, cookies);
    _sessionPathPrefix = _validateSessionPrefix(artifact.sessionPathPrefix);
    _loginPageUrl = '$_baseUri$_sessionPathPrefix/home/stulogin';
    // 临时允许 probe 发起学校请求；只有 profile 返回的真实学号通过后才保留认证状态。
    _authenticated = true;
    final state = await probe();
    if (!state.authenticated) {
      _authenticated = false;
      throw const GraduatePortalException('SESSION_EXPIRED', '研究生教务会话已失效');
    }
    _authenticated = true;
  }

  @override
  Future<void> reset() async {
    _publicKeyPem = null;
    _sessionPathPrefix = '';
    _loginPageUrl = '$graduatePortalBaseUrl/home/stulogin';
    _authenticated = false;
    await _cookieJar.deleteAll();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _dio.close(force: true);
  }

  Future<Response<String>> _openLoginPage() async {
    var current = _baseUri.resolve('/home/stulogin');
    for (var hop = 0; hop < 5; hop++) {
      final response = await _dio.getUri<String>(current, options: Options(responseType: ResponseType.plain));
      if (!_isRedirect(response.statusCode)) {
        _requireSuccess(response, '打开登录页');
        _loginPageUrl = response.realUri.toString();
        _captureSessionPath(response.realUri);
        return response;
      }
      final location = response.headers.value('location');
      if (location == null || location.trim().isEmpty) throw GraduatePortalException('REMOTE_HTTP_${response.statusCode}', '学校返回登录重定向，但没有提供目标地址');
      final next = response.realUri.resolve(location);
      if (!_sameOrigin(_baseUri, next)) throw const GraduatePortalException('LOGIN_REDIRECT_REJECTED', '学校登录页跳转到了非教务域名，已停止请求');
      current = next;
    }
    throw const GraduatePortalException('LOGIN_REDIRECT_LOOP', '学校登录页重定向次数过多');
  }

  Future<dynamic> _getDecoded(String path, String operation) async {
    _ensureAuthenticated();
    final response = await _dio.get<String>(
      _portalPath(path),
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
      options: Options(responseType: ResponseType.plain, headers: {'Referer': _loginPageUrl}),
    );
    _requireSuccess(response, operation);
    return GraduateResponseCodec.decode(response.data ?? '');
  }

  Future<dynamic> _postDecoded(String path, String operation) async {
    _ensureAuthenticated();
    final response = await _dio.post<String>(
      _portalPath(path),
      data: const <String, String>{},
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Referer': _loginPageUrl, 'X-Requested-With': 'XMLHttpRequest'},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    _requireSuccess(response, operation);
    return GraduateResponseCodec.decode(response.data ?? '');
  }

  void _ensureAuthenticated() {
    _ensureOpen();
    if (!_authenticated) throw const GraduatePortalException('SESSION_EXPIRED', '研究生教务会话已失效');
  }

  void _ensureOpen() {
    if (_closed) throw const GraduatePortalException('CLIENT_CLOSED', '本次教务会话已关闭，请重新登录');
  }

  void _requireSuccess(Response<dynamic> response, String operation) {
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) throw GraduatePortalException('REMOTE_HTTP_$status', '$operation失败，请稍后重试');
  }

  void _captureSessionPath(Uri uri) {
    _sessionPathPrefix = _validateSessionPrefix(RegExp(r'^/\(S\([^)]+\)\)', caseSensitive: false).firstMatch(uri.path)?.group(0) ?? '');
  }

  String _portalPath(String path) => '$_sessionPathPrefix${path.startsWith('/') ? path : '/$path'}';

  String _validateSessionPrefix(String value) {
    if (value.isEmpty) return '';
    if (!RegExp(r'^/\(S\([A-Za-z0-9_-]+\)\)$').hasMatch(value)) throw const GraduatePortalException('SESSION_ARTIFACT_INVALID', '研究生会话路径格式无效');
    return value;
  }

  bool _sameOrigin(Uri a, Uri b) => a.scheme.toLowerCase() == b.scheme.toLowerCase() && a.host.toLowerCase() == b.host.toLowerCase() && a.port == b.port;
  bool _isRedirect(int? status) => status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
}

abstract final class GraduateResponseCodec {
  static dynamic decode(String responseText) {
    final trimmed = responseText.trim();
    if (trimmed.isEmpty) throw const GraduatePortalException('EMPTY_RESPONSE', '学校返回为空');
    final direct = _tryJson(trimmed);
    if (direct is Map || direct is List) return direct;
    final encrypted = direct is String ? direct : trimmed;
    try {
      final cipher = PaddedBlockCipher('AES/ECB/PKCS7')
        ..init(false, PaddedBlockCipherParameters<KeyParameter, Null>(KeyParameter(Uint8List.fromList(utf8.encode(_aesKey))), null));
      final decrypted = utf8.decode(cipher.process(Uint8List.fromList(base64Decode(encrypted))));
      return _tryJson(decrypted) ?? decrypted;
    } catch (_) {
      throw const GraduatePortalException('ENCRYPTED_RESPONSE_INVALID', '学校响应无法解密，登录协议可能已变化');
    }
  }

  static dynamic _tryJson(String source) {
    try {
      return jsonDecode(source);
    } on FormatException {
      return null;
    }
  }
}

abstract final class GraduateAuthCodec {
  static String encryptPassword(String password, String pem) {
    try {
      final encoded = pem.replaceAll(RegExp(r'-----BEGIN (RSA )?PUBLIC KEY-----'), '').replaceAll(RegExp(r'-----END (RSA )?PUBLIC KEY-----'), '').replaceAll(RegExp(r'\s+'), '');
      final topLevel = ASN1Parser(base64Decode(encoded)).nextObject() as ASN1Sequence;
      final elements = topLevel.elements;
      if (elements.length < 2) throw const FormatException('RSA sequence is incomplete');
      final keySequence = elements.first is ASN1Integer ? topLevel : ASN1Parser((elements[1] as ASN1BitString).contentBytes()).nextObject() as ASN1Sequence;
      final keyElements = keySequence.elements;
      if (keyElements.length < 2) throw const FormatException('RSA public key is incomplete');
      final key = RSAPublicKey((keyElements[0] as ASN1Integer).valueAsBigInteger, (keyElements[1] as ASN1Integer).valueAsBigInteger);
      final cipher = PKCS1Encoding(RSAEngine())..init(true, PublicKeyParameter<RSAPublicKey>(key));
      return base64Encode(cipher.process(Uint8List.fromList(utf8.encode(password))));
    } on FormatException {
      throw const GraduatePortalException('PUBLIC_KEY_INVALID', '学校登录公钥格式已变化');
    } on ArgumentError {
      throw const GraduatePortalException('PASSWORD_ENCRYPTION_FAILED', '密码加密失败，请重新获取验证码');
    } on TypeError {
      throw const GraduatePortalException('PUBLIC_KEY_INVALID', '学校登录公钥格式已变化');
    }
  }
}

final class GraduateAuthClassification {
  const GraduateAuthClassification(this.code);

  final String code;
}

abstract final class GraduateAuthDetector {
  /// 默认向模糊失败收敛；只有真实 Fixture 认可的明确文案才提升分类。
  static GraduateAuthClassification classify(String message) {
    final value = message.trim();
    if (value.isEmpty) return const GraduateAuthClassification('AUTH_REJECTED_AMBIGUOUS');
    if (RegExp(r'^(验证码|校验码)(错误|不正确|有误)$').hasMatch(value)) return const GraduateAuthClassification('CHALLENGE_REJECTED');
    if (RegExp(r'^(密码)(错误|不正确|有误)$').hasMatch(value)) return const GraduateAuthClassification('CREDENTIAL_REJECTED');
    if (RegExp(r'^(账号|用户名)(不存在|未注册)$').hasMatch(value)) return const GraduateAuthClassification('ACCOUNT_REJECTED');
    if (RegExp(r'冻结|未开通|无访问权限').hasMatch(value)) return const GraduateAuthClassification('ACCOUNT_RESTRICTED');
    return const GraduateAuthClassification('AUTH_REJECTED_AMBIGUOUS');
  }
}

abstract final class GraduateScheduleParser {
  static GraduateSchedule parse(dynamic response) {
    if (response is! Map || response['rows'] is! List) throw const GraduatePortalException('SCHEDULE_RESPONSE_INVALID', '学校课表缺少 rows');
    final slots = <GraduateCourseSlot>[];
    final rows = response['rows'] as List;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final raw = rows[rowIndex];
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final period = row['mc']?.toString().trim();
      for (var day = 1; day <= 7; day++) {
        final cell = row['z$day']?.toString().trim() ?? '';
        if (cell.isEmpty) continue;
        final courses = parseCell(cell);
        if (courses.isEmpty) continue;
        slots.add(GraduateCourseSlot(dayOfWeek: day, periodOrder: rowIndex, periodLabel: period == null || period.isEmpty ? '第${row['jcid'] ?? ''}节' : period, courses: courses));
      }
    }
    return GraduateSchedule(slots: List.unmodifiable(slots));
  }

  static List<GraduateCourse> parseCell(String html) {
    final source = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    final lines = (parseFragment(source).text ?? '').split(RegExp(r'\n+')).map((item) => item.replaceAll(RegExp(r'\s+'), ' ').trim()).where((item) => item.isNotEmpty);
    final pattern = RegExp(r'^(.+?)\s*\[([^\]]+)\]\s*(.+?)\s*\[([^\]]+)\]\s*$');
    return lines.map((line) {
      final match = pattern.firstMatch(line);
      if (match == null) return GraduateCourse(name: line, weeks: '', teacher: '', location: '');
      return GraduateCourse(name: match.group(1)!.trim(), weeks: match.group(2)!.trim(), teacher: match.group(3)!.trim(), location: match.group(4)!.trim());
    }).toList(growable: false);
  }
}

bool _isTrue(Object? value) => value == true || value == 1 || value?.toString().toLowerCase() == 'true' || value == '1';
