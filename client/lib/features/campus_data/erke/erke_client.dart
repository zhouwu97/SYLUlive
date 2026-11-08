import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' show Document;
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import '../common/erke_endpoints.dart';
import 'erke_models.dart';
import 'erke_parser.dart';

/// 二课把多种上游故障统一提示为密码错误，不能据此删除本机凭据。
class ErkeLoginException implements Exception {
  const ErkeLoginException();
  String get message => '二课平台未能完成登录，可能是学校服务或会话异常，请重试；若持续失败，可修改密码后重试';
}

/// 二课系统客户端
///
/// 复用 WebVpnService 提供的 dio/cookieJar 完成:
///   - 二课 ASP.NET WebForms 登录 (RSA + 伪验证码)
///   - WebVPN 目标 URL 构造 (AES-CFB128)
///   - GBK/UTF-8 响应解码
///   - 毕业要求 / 学年要求 / 活动明细页面获取
class ErkeClient {
  final Dio _dio;

  /// WebVPN 加密的 Key 和 IV (固定)
  static const String _vpnKeyIvStr = 'wrdvpnisthebest!';

  /// 目标域名
  static const String _targetDomain = 'xg.sylu.edu.cn';

  /// WebVPN 入口
  static const String _vpnHost = 'https://webvpn.sylu.edu.cn';

  ErkeClient({required Dio dio}) : _dio = dio;

  // ====================================================================
  //  URL 构造
  // ====================================================================

  /// 构造 WebVPN 加密后的代理 URL
  String buildVpnUrl(String innerPath) {
    final keyBytes = utf8.encode(_vpnKeyIvStr);
    final ivBytes = utf8.encode(_vpnKeyIvStr);
    final plainBytes = utf8.encode(_targetDomain);

    final cipher = pc.CFBBlockCipher(pc.AESEngine(), 16);
    cipher.init(true, pc.ParametersWithIV(pc.KeyParameter(keyBytes), ivBytes));

    final cipherBytes = Uint8List(plainBytes.length);
    int offset = 0;
    while (offset < plainBytes.length) {
      final remaining = plainBytes.length - offset;
      final chunkSize = remaining < 16 ? remaining : 16;
      final block = Uint8List(16);
      block.setRange(0, chunkSize, plainBytes.skip(offset).take(chunkSize));
      final outBlock = Uint8List(16);
      cipher.processBlock(block, 0, outBlock, 0);
      cipherBytes.setRange(
          offset, offset + chunkSize, outBlock.take(chunkSize));
      offset += chunkSize;
    }

    final keyHex = _bytesToHex(keyBytes);
    final encryptedHostHex = _bytesToHex(cipherBytes);

    final path = innerPath.startsWith('/') ? innerPath : '/$innerPath';

    return '$_vpnHost/http/$keyHex$encryptedHostHex$path';
  }

  static String _bytesToHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write('${b < 16 ? '0' : ''}${b.toRadixString(16)}');
    }
    return buffer.toString().toLowerCase();
  }

  // ====================================================================
  //  响应解码
  // ====================================================================

  String decodeResponseBytes(List<int> bytes, Headers headers) {
    try {
      final contentType = headers.value('content-type') ?? '';
      if (contentType.toLowerCase().contains('utf-8')) {
        return utf8.decode(bytes);
      }
      return gbk.decode(bytes);
    } catch (_) {
      try {
        return utf8.decode(bytes);
      } catch (_) {
        return String.fromCharCodes(bytes);
      }
    }
  }

  // ====================================================================
  //  RSA 加密
  // ====================================================================

  String encryptRsa(String plainText, String publicKeyBase64) {
    try {
      final cleanBase64 = publicKeyBase64.replaceAll(RegExp(r'\s+'), '');
      final publicKeyBytes = base64Decode(cleanBase64);

      final asn1Parser = ASN1Parser(publicKeyBytes);
      final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;

      ASN1Integer modulus;
      ASN1Integer exponent;

      if (topLevelSeq.elements[0] is ASN1Integer) {
        modulus = topLevelSeq.elements[0] as ASN1Integer;
        exponent = topLevelSeq.elements[1] as ASN1Integer;
      } else {
        final subjectPublicKey = topLevelSeq.elements[1] as ASN1BitString;
        final innerParser = ASN1Parser(subjectPublicKey.contentBytes());
        final pkSeq = innerParser.nextObject() as ASN1Sequence;
        modulus = pkSeq.elements[0] as ASN1Integer;
        exponent = pkSeq.elements[1] as ASN1Integer;
      }

      final rsaPublicKey = pc.RSAPublicKey(
        modulus.valueAsBigInteger,
        exponent.valueAsBigInteger,
      );
      final cipher = pc.PKCS1Encoding(pc.RSAEngine())
        ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(rsaPublicKey));
      final plainBytes = utf8.encode(plainText);
      return base64Encode(cipher.process(plainBytes));
    } catch (e) {
      throw Exception('RSA密码加密失败: $e');
    }
  }

  // ====================================================================
  //  二课登录
  // ====================================================================

  /// 执行二课 ASP.NET WebForms 登录
  /// 返回登录后可用于后续请求 (cookie 已写入 _cookieJar)
  Future<void> loginToErke(String username, String password) async {
    // 上游偶发首次登录建立会话却返回错误页；先验证会话，再限次恢复。
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _loginOnce(username, password);
        return;
      } on ErkeLoginException {
        if (attempt == 1) rethrow;
      }
    }
  }

  Future<void> _loginOnce(String username, String password) async {
    final loginUrl = buildVpnUrl(ErkeEndpoints.login);

    // 1. GET 登录页 → 处理重定向链
    String currentUrl = loginUrl;
    Response getResp;
    int redirectCount = 0;

    while (true) {
      getResp = await _dio.get(
        currentUrl,
        options: Options(responseType: ResponseType.bytes),
      );

      if (getResp.statusCode == 301 || getResp.statusCode == 302) {
        final location = getResp.headers.value('location');
        if (location != null) {
          currentUrl = _resolveUrl(location, currentUrl);
          if (Uri.parse(currentUrl).host != Uri.parse(_vpnHost).host ||
              Uri.parse(currentUrl).scheme != 'https') {
            throw const ErkeLoginException();
          }
          redirectCount++;
          if (redirectCount > 10) throw Exception('重定向次数过多');
          continue;
        }
      }
      break;
    }

    if (getResp.statusCode != 200) {
      throw Exception('无法访问登录页，状态码: ${getResp.statusCode}');
    }

    final htmlStr = decodeResponseBytes(
      getResp.data as List<int>,
      getResp.headers,
    );
    final doc = parse(htmlStr);

    // 2. 提取 ASP.NET 隐藏字段
    final viewState = _getInputValue(doc, '__VIEWSTATE');
    final viewStateGen = _getInputValue(doc, '__VIEWSTATEGENERATOR');
    final eventValidation = _getInputValue(doc, '__EVENTVALIDATION');
    final pubKeyBase64 = _getInputValue(doc, 'pubKey');

    if (pubKeyBase64.isEmpty) {
      if (await _hasAuthenticatedSession()) return;
      throw const ErkeLoginException();
    }

    // 3. RSA 加密密码
    final encryptedPwd = encryptRsa(password, pubKeyBase64);

    // 4. 提取伪验证码
    final codeBoxElement = doc.querySelector('#code-box');
    String captcha = codeBoxElement?.text.trim() ?? '';
    if (captcha.isEmpty) captcha = 'K777';

    // 5. POST 登录 (GBK 编码)
    final formData = <String, dynamic>{
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      '__EVENTVALIDATION': eventValidation,
      'UserName': username,
      'Password': '',
      'pwd': encryptedPwd,
      'pubKey': pubKeyBase64,
      'codeInput': captcha,
      'queryBtn': '登            录',
    };

    var postResp = await _dio.post(
      currentUrl,
      data: _encodeGbkForm(formData),
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: false,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': currentUrl,
        },
      ),
    );

    // 手动跟随，确保 CookieManager 收到每一跳的 Set-Cookie。
    var responseUrl = currentUrl;
    for (var redirects = 0;
        const [301, 302, 303, 307, 308].contains(postResp.statusCode);
        redirects++) {
      final location = postResp.headers.value('location');
      if (redirects >= 10 || location == null) {
        throw const ErkeLoginException();
      }
      responseUrl = _resolveUrl(location, responseUrl);
      if (Uri.parse(responseUrl).host != Uri.parse(_vpnHost).host ||
          Uri.parse(responseUrl).scheme != 'https') {
        throw const ErkeLoginException();
      }
      postResp = await _dio.get(responseUrl,
          options: Options(
              responseType: ResponseType.bytes, followRedirects: false));
    }
    if (postResp.statusCode != 200) throw const ErkeLoginException();

    final postHtml = decodeResponseBytes(
      postResp.data as List<int>,
      postResp.headers,
    );
    final postDoc = parse(postHtml);

    // 6. 成功证据优先于页面中通用的 alert 脚本。
    if (Uri.parse(responseUrl)
            .path
            .toLowerCase()
            .endsWith('/systemform/main.htm') &&
        postDoc.querySelector('input[id="pubKey"]') == null) {
      return;
    }
    final successRedirect = RegExp(
      r'''(?:window\.)?location(?:\.href)?\s*(?:=|\()\s*['"][^'"]*SystemForm/main\.htm''',
      caseSensitive: false,
    );
    for (final script in postDoc.querySelectorAll('script')) {
      if (successRedirect.hasMatch(script.text)) return;
    }
    if (await _hasAuthenticatedSession()) return;
    throw const ErkeLoginException();
  }

  Future<bool> _hasAuthenticatedSession() async {
    try {
      await getGraduationSummary();
      return true;
    } on ErkePageChangedException {
      return false;
    } on ErkeLoginException {
      return false;
    }
  }

  String _decodeProtectedResponse(Response response) {
    if (response.statusCode != 200) {
      if (const [301, 302, 303, 307, 308, 401, 403]
          .contains(response.statusCode)) {
        throw const ErkeLoginException();
      }
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }
    final html =
        decodeResponseBytes(response.data as List<int>, response.headers);
    final doc = parse(html);
    if (doc.querySelector('#pubKey, #pwdEncryptSalt, input[name="UserName"]') !=
        null) {
      throw const ErkeLoginException();
    }
    return html;
  }

  // ====================================================================
  //  页面获取
  // ====================================================================

  /// 获取毕业要求汇总页 HTML
  Future<String> getGraduationSummaryHtml() async {
    final url = buildVpnUrl(ErkeEndpoints.graduationSummary);
    final resp = await _dio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return _decodeProtectedResponse(resp);
  }

  /// 获取并解析毕业要求
  Future<ErkeGraduationSummary> getGraduationSummary() async {
    final html = await getGraduationSummaryHtml();
    return ErkeParser.parseGraduationSummary(html);
  }

  /// 获取学年要求汇总页 HTML（含成绩）
  ///
  /// 流程: GET → 比较年份 → 同年有成绩直接解析 / 否则 WebForms POST
  Future<String> getYearlySummaryHtml({String? year}) async {
    final url = buildVpnUrl(ErkeEndpoints.yearlySummary);

    // 1. GET 初始页面
    final getResp = await _dio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final getHtml = _decodeProtectedResponse(getResp);

    // 2. 解析表单
    final form = ErkeParser.parseYearPageForm(getHtml);
    final requestedYear = year;

    if (kDebugMode) {
      print('[Erke] yearly requestedYear=$requestedYear'
          ' getSelectedYear=${form.selectedYear}');
    }

    // 3. 判断是否需要 POST（年份不同时必须 POST）
    final hasScores = ErkeParser.yearlyPageHasScores(getHtml);
    final canUseGet = hasScores &&
        (requestedYear == null || requestedYear == form.selectedYear);

    if (kDebugMode) {
      print('[Erke] yearly shouldPost=${!canUseGet}');
    }

    if (canUseGet) {
      return getHtml;
    }

    // 4. 执行 WebForms POST（模拟 __doPostBack('YearTime','')）
    final targetYear = requestedYear ?? form.selectedYear;
    if (!form.availableYears.contains(targetYear)) {
      throw Exception('无效的学年: $targetYear (可选: ${form.availableYears})');
    }

    if (kDebugMode) {
      print('[Erke] yearly POST eventTarget=YearTime'
          ' targetYear=$targetYear');
    }
    final formData = <String, dynamic>{
      ...form.hiddenInputs,
      '__EVENTTARGET': 'YearTime',
      '__EVENTARGUMENT': '',
      'YearTime': targetYear,
    };

    final postResp = await _dio.post(
      url,
      data: _encodeGbkForm(formData),
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': url,
        },
      ),
    );

    final postHtml = _decodeProtectedResponse(postResp);

    // 5. 验证 POST 结果
    final returnedForm = ErkeParser.parseYearPageForm(postHtml);
    if (kDebugMode) {
      print('[Erke] yearly POST returnedYear=${returnedForm.selectedYear}'
          ' hasScores=${ErkeParser.yearlyPageHasScores(postHtml)}');
    }

    if (returnedForm.selectedYear != targetYear) {
      throw ErkePageChangedException(
        '学年切换失败：请求 $targetYear，'
        '服务器返回 ${returnedForm.selectedYear}',
      );
    }

    if (!ErkeParser.yearlyPageHasScores(postHtml)) {
      throw const ErkePageChangedException(
        '学年查询已提交，但返回页面没有成绩数据',
      );
    }

    return postHtml;
  }

  /// 获取并解析学年要求
  Future<ErkeYearlySummary> getYearlySummary({String? year}) async {
    final html = await getYearlySummaryHtml(year: year);
    return ErkeParser.parseYearlySummary(html);
  }

  /// 获取活动明细页 HTML
  /// [year] 可选；提供时通过 YearTime 提交筛选
  Future<String> getActivitiesPageHtml({String? year}) async {
    final url = buildVpnUrl(ErkeEndpoints.activitySearch);

    if (year == null) {
      final resp = await _dio.get(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      return _decodeProtectedResponse(resp);
    }

    // WebForms 学年筛选
    final getResp = await _dio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final getHtml = _decodeProtectedResponse(getResp);
    final hiddenInputs = ErkeParser.extractHiddenInputs(parse(getHtml));

    final formData = <String, dynamic>{
      ...hiddenInputs,
      'YearTime': year,
    };

    final postResp = await _dio.post(
      url,
      data: _encodeGbkForm(formData),
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': url,
        },
      ),
    );

    return _decodeProtectedResponse(postResp);
  }

  /// 获取并解析活动明细
  Future<List<ErkeActivity>> getActivities({String? year}) async {
    final html = await getActivitiesPageHtml(year: year);
    if (parse(html).querySelector('table, #GridView1, #DataGrid1') == null &&
        !RegExp(r'暂无|没有.*记录|未查询到|无活动记录')
            .hasMatch(parse(html).body?.text ?? '')) {
      throw const ErkePageChangedException('活动列表页面缺少数据或空状态');
    }
    return ErkeParser.parseActivities(html);
  }

  // ====================================================================
  //  辅助
  // ====================================================================

  /// 从 HTML 文档提取 input value
  static String _getInputValue(Document doc, String name) {
    var element = doc.querySelector('input[id="$name"]');
    element ??= doc.querySelector('input[name="$name"]');
    return element?.attributes['value'] ?? '';
  }

  static String _resolveUrl(String url, String base) {
    return Uri.parse(base).resolve(url).toString();
  }

  /// ASP.NET 页面使用 GBK；Dio 对 Map 默认以 UTF-8 编码，会改变登录按钮值。
  static String _encodeGbkForm(Map<String, dynamic> form) {
    String encode(String value) => gbk.encode(value).map((byte) {
          final unreserved = byte >= 65 && byte <= 90 ||
              byte >= 97 && byte <= 122 ||
              byte >= 48 && byte <= 57 ||
              const [45, 46, 95, 126].contains(byte);
          if (unreserved) return String.fromCharCode(byte);
          if (byte == 32) return '+';
          return '%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}';
        }).join();
    return form.entries
        .map(
            (entry) => '${encode(entry.key)}=${encode(entry.value.toString())}')
        .join('&');
  }
}
