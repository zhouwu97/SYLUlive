import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' show Document;
import 'package:fast_gbk/fast_gbk.dart';

import '../common/erke_endpoints.dart';
import 'erke_models.dart';
import 'erke_parser.dart';

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

      if (topLevelSeq.elements![0] is ASN1Integer) {
        modulus = topLevelSeq.elements![0] as ASN1Integer;
        exponent = topLevelSeq.elements![1] as ASN1Integer;
      } else {
        final subjectPublicKey = topLevelSeq.elements![1] as ASN1BitString;
        final innerParser = ASN1Parser(subjectPublicKey.contentBytes()!);
        final pkSeq = innerParser.nextObject() as ASN1Sequence;
        modulus = pkSeq.elements![0] as ASN1Integer;
        exponent = pkSeq.elements![1] as ASN1Integer;
      }

      final rsaPublicKey = pc.RSAPublicKey(
        modulus.valueAsBigInteger,
        exponent.valueAsBigInteger,
      );
      final cipher = pc.PKCS1Encoding(pc.RSAEngine())
        ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(rsaPublicKey));
      final plainBytes = utf8.encode(plainText) as Uint8List;
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
      throw Exception('未能从页面提取到 RSA 公钥 (pubKey字段不存在)');
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
      'Password': password,
      'pwd': encryptedPwd,
      'pubKey': pubKeyBase64,
      'codeInput': captcha,
      'queryBtn': '登          录',
    };

    final postResp = await _dio.post(
      currentUrl,
      data: formData,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': currentUrl,
        },
      ),
    );

    final postHtml = decodeResponseBytes(
      postResp.data as List<int>,
      postResp.headers,
    );
    final postDoc = parse(postHtml);

    // 6. 检查登录结果
    for (final script in postDoc.querySelectorAll('script')) {
      if (script.text.contains('alert')) {
        throw Exception('登录失败: ${script.text.trim()}');
      }
      if (script.text.contains("window.location.href='SystemForm/main.htm'") ||
          script.text.contains('window.location.href="SystemForm/main.htm"')) {
        return; // 登录成功
      }
    }

    for (final element in postDoc.querySelectorAll('*')) {
      final id = element.id;
      if (id.contains('msg') || id.contains('error')) {
        throw Exception('登录失败: ${element.text.trim()}');
      }
    }

    throw Exception('未能确认登录成功');
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
    return decodeResponseBytes(resp.data as List<int>, resp.headers);
  }

  /// 获取并解析毕业要求
  Future<ErkeGraduationSummary> getGraduationSummary() async {
    final html = await getGraduationSummaryHtml();
    return ErkeParser.parseGraduationSummary(html);
  }

  /// 获取学年要求汇总页 HTML（含成绩）
  ///
  /// 流程: GET → 解析表单 → 有成绩直接返回 / 无成绩则 WebForms POST
  Future<String> getYearlySummaryHtml({String? year}) async {
    final url = buildVpnUrl(ErkeEndpoints.yearlySummary);

    // 1. GET 初始页面
    print('[Erke] yearly GET url=$url');
    final getResp = await _dio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final getHtml =
        decodeResponseBytes(getResp.data as List<int>, getResp.headers);
    final getDoc = parse(getHtml);

    print(
        '[Erke] yearly GET status=${getResp.statusCode} bodyLength=${getHtml.length}');
    final title = getDoc.querySelector('title')?.text ?? '';
    print('[Erke] yearly GET title=$title');

    // 2. 解析查询表单（不需要成绩数据）
    final form = ErkeParser.parseYearPageForm(getHtml);
    final targetYear = year ?? form.selectedYear;

    // 3. 如果 GET 已有成绩 → 直接解析
    if (ErkeParser.yearlyPageHasScores(getHtml)) {
      print('[Erke] yearly GET already has scores, skip POST');
      return getHtml;
    }

    // 4. 否则需要 POST 提交学年查询
    print(
        '[Erke] yearly POST needed — GET selectedYear=${form.selectedYear} targetYear=$targetYear');
    if (!form.availableYears.contains(targetYear)) {
      throw Exception('无效的学年: $targetYear (可选: ${form.availableYears})');
    }

    final formData = <String, dynamic>{
      ...form.hiddenInputs,
      'YearTime': targetYear,
    };
    if (form.submitButtonName != null) {
      formData[form.submitButtonName!] = form.submitButtonValue ?? '查询';
    }
    if (form.eventTarget != null) {
      formData['__EVENTTARGET'] = form.eventTarget;
    }

    final postResp = await _dio.post(
      url,
      data: formData,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': url,
        },
      ),
    );

    final postHtml =
        decodeResponseBytes(postResp.data as List<int>, postResp.headers);
    final postDoc = parse(postHtml);

    print(
        '[Erke] yearly POST status=${postResp.statusCode} bodyLength=${postHtml.length}');
    final returnedYear = ErkeParser.extractSelectedOption(postDoc, 'YearTime');
    print('[Erke] yearly POST selectedYear=$returnedYear');
    if (returnedYear != null && returnedYear != targetYear) {
      throw Exception('学年切换失败: 请求 $targetYear，服务器返回 $returnedYear');
    }

    final hasCountA1 = postDoc.getElementById('CountA1') != null ||
        postDoc.querySelectorAll('[id\$="CountA1"]').isNotEmpty;
    print('[Erke] yearly POST hasCountA1=$hasCountA1');

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
      return decodeResponseBytes(resp.data as List<int>, resp.headers);
    }

    // WebForms 学年筛选
    final getResp = await _dio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final getHtml =
        decodeResponseBytes(getResp.data as List<int>, getResp.headers);
    final hiddenInputs = ErkeParser.extractHiddenInputs(parse(getHtml));

    final formData = <String, dynamic>{
      ...hiddenInputs,
      'YearTime': year,
    };

    final postResp = await _dio.post(
      url,
      data: formData,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': url,
        },
      ),
    );

    return decodeResponseBytes(postResp.data as List<int>, postResp.headers);
  }

  /// 获取并解析活动明细
  Future<List<ErkeActivity>> getActivities({String? year}) async {
    final html = await getActivitiesPageHtml(year: year);
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
    if (url.startsWith('http')) return url;
    final uri = Uri.parse(base);
    if (url.startsWith('/')) return '${uri.scheme}://${uri.host}$url';
    return '${uri.scheme}://${uri.host}${uri.path}$url';
  }
}
