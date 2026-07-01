import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' show Document;
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

/// 纯客户端的前端爬虫工具类
/// 用于在用户的手机本地直接穿透深信服 WebVPN，并模拟登录内网的 ASP.NET WebForms 二课系统。
class SyluClientCrawler {
  late final Dio _dio;
  late final CookieJar _cookieJar;

  /// WebVPN 加密的 Key 和 IV (固定)
  static const String _vpnKeyIvStr = 'wrdvpnisthebest!';

  /// 原始内网登录地址（二课登录页）
  static const String _innerUrl =
      'http://xg.sylu.edu.cn/SyluTW/Sys/UserLogin.aspx';

  /// 域名部分，用于加密
  static const String _targetDomain = 'xg.sylu.edu.cn';

  SyluClientCrawler({CookieJar? cookieJar, Dio? dio}) {
    _dio = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
              'Accept-Language': 'zh-CN,zh;q=0.9',
              'Connection': 'keep-alive',
              'Upgrade-Insecure-Requests': '1',
            },
            // 关闭自动跟随重定向，我们手动处理，以防止 Cookie 丢失
            followRedirects: false,
            validateStatus: (status) {
              return status != null && status < 600; // 捕获所有状态码
            },
          ),
        );

    // 【核心修复】：强制信任所有证书
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 强制返回 true，忽略任何证书错误
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        return client;
      },
    );

    _cookieJar = CookieJar();
    _dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// 获取 Dio 实例用于测试脚本
  Dio getDio() => _dio;

  void _debugLog(String message) {
    if (kDebugMode) {
      print(message);
    }
  }

  String _redactUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}${uri.path}';
    } catch (_) {
      return '<invalid-url>';
    }
  }

  /// 健壮的响应字节流解码器
  String decodeResponseBytes(List<int> bytes, Headers headers) {
    return _decodeResponseBytes(bytes, headers);
  }

  String _decodeResponseBytes(List<int> bytes, Headers headers) {
    try {
      final contentType = headers.value('content-type') ?? '';
      if (contentType.toLowerCase().contains('utf-8')) {
        return utf8.decode(bytes);
      }
      return gbk.decode(bytes);
    } catch (e) {
      try {
        return utf8.decode(bytes);
      } catch (e2) {
        return String.fromCharCodes(bytes);
      }
    }
  }

  /// 执行登录并返回结果状态
  Future<String> login(
    String username,
    String password, [
    String? vpnTicket,
  ]) async {
    // 1. 初始化 Cookie
    if (vpnTicket != null) {
      await _injectVpnCookie(vpnTicket);
    }

    // 2. 生成加密后的 WebVPN 目标 URL
    final encryptedUrl = _buildVpnUrl();
    _debugLog('[Crawler] 初始 VPN URL: ${_redactUrl(encryptedUrl)}');

    // 3. 手动处理 GET 重定向链，以维持 WebVPN 的会话
    String currentUrl = encryptedUrl;
    Response getResp;
    int redirectCount = 0;

    while (true) {
      getResp = await _dio.get(
        currentUrl,
        options: Options(responseType: ResponseType.bytes),
      );

      _debugLog(
        '[Crawler] GET 响应状态: ${getResp.statusCode}, URL: ${_redactUrl(currentUrl)}',
      );

      if (getResp.statusCode == 301 || getResp.statusCode == 302) {
        final location = getResp.headers.value('location');
        if (location != null) {
          if (location.startsWith('http')) {
            currentUrl = location;
          } else if (location.startsWith('/')) {
            final uri = Uri.parse(currentUrl);
            currentUrl = '${uri.scheme}://${uri.host}$location';
          }
          _debugLog('[Crawler] 重定向到: ${_redactUrl(currentUrl)}');
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

    final htmlStr = _decodeResponseBytes(
      getResp.data as List<int>,
      getResp.headers,
    );
    final doc = parse(htmlStr);

    final viewState = _getInputValue(doc, '__VIEWSTATE');
    final viewStateGen = _getInputValue(doc, '__VIEWSTATEGENERATOR');
    final eventValidation = _getInputValue(doc, '__EVENTVALIDATION');
    final pubKeyBase64 = _getInputValue(doc, 'pubKey');

    if (pubKeyBase64.isEmpty) {
      throw Exception('未能从页面提取到 RSA 公钥 (pubKey字段不存在)');
    }
    _debugLog('[Crawler] 找到 RSA 公钥');

    // 使用 RSA 公钥加密密码
    final encryptedPwd = _encryptRsa(password, pubKeyBase64);
    _debugLog('[Crawler] 加密后的 pwd: <redacted>, length=${encryptedPwd.length}');

    // 提取伪验证码
    final codeBoxElement = doc.querySelector('#code-box');
    String captcha = codeBoxElement?.text.trim() ?? '';
    if (captcha.isEmpty) captcha = 'K777'; // 兜底的伪造验证码
    _debugLog('[Crawler] 提取的伪验证码: <redacted>, length=${captcha.length}');

    // 构造表单数据 (使用 UTF-8 URL编码)
    final Map<String, dynamic> formData = {
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      '__EVENTVALIDATION': eventValidation,
      'UserName': username,
      'Password': password, // JSEncrypt 保留原字段
      'pwd': encryptedPwd,
      'pubKey': pubKeyBase64,
      'codeInput': captcha,
      'queryBtn': '登          录',
    };

    _debugLog('[Crawler] 发送 POST 登录请求到: ${_redactUrl(currentUrl)}');
    // 注意：我们将 followRedirects 设置回 true，以便自动跟随登录后的可能的 302（如果有）
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

    final postHtml = _decodeResponseBytes(
      postResp.data as List<int>,
      postResp.headers,
    );

    final postDoc = parse(postHtml);
    for (final script in postDoc.querySelectorAll('script')) {
      if (script.text.contains('alert')) {
        _debugLog('[Crawler] 发现服务器弹窗提示，length=${script.text.trim().length}');
        throw Exception('登录失败: ${script.text.trim()}');
      }
      if (script.text.contains("window.location.href='SystemForm/main.htm'") ||
          script.text.contains('window.location.href="SystemForm/main.htm"')) {
        _debugLog('[Crawler] 登录成功，直接跳转到成绩查询页');
        final baseUri = Uri.parse(currentUrl);
        final mainUrl =
            '${baseUri.scheme}://${baseUri.host}${baseUri.path.replaceAll('UserLogin.aspx', 'SystemForm/StuAction/StuActionSearch.aspx')}';
        _debugLog('[Crawler] 成绩页URL: ${_redactUrl(mainUrl)}');
        final mainResp = await _dio.get(
          mainUrl,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
          ),
        );
        final mainHtml = _decodeResponseBytes(
          mainResp.data as List<int>,
          mainResp.headers,
        );
        _debugLog('[Crawler] 成绩页获取成功，长度: ${mainHtml.length}');
        return mainHtml;
      }
    }

    for (final element in postDoc.querySelectorAll('*')) {
      final id = element.id;
      if (id.contains('msg') || id.contains('error')) {
        _debugLog(
          '[Crawler] 发现提示元素 ID: $id, 内容长度: ${element.text.trim().length}',
        );
        throw Exception('登录失败: ${element.text.trim()}');
      }
    }

    throw Exception('未能确认登录成功，页面未包含重定向脚本。');
  }

  /// 注入传入的 WebVPN Cookie
  Future<void> _injectVpnCookie(String vpnTicket) async {
    final vpnUri = Uri.parse('https://webvpn.sylu.edu.cn');
    String cookieStr = vpnTicket;
    if (!cookieStr.contains('=')) {
      cookieStr = 'wengine_vpn_ticketwebvpn_sylu_edu_cn=$vpnTicket';
    }

    await _cookieJar.saveFromResponse(vpnUri, [
      Cookie.fromSetCookieValue(cookieStr),
    ]);
  }

  /// 构造 WebVPN 加密后的目标 URL
  String _buildVpnUrl() {
    final keyBytes = utf8.encode(_vpnKeyIvStr) as Uint8List;
    final ivBytes = utf8.encode(_vpnKeyIvStr) as Uint8List;
    final plainBytes = utf8.encode(_targetDomain) as Uint8List;

    final cipher = pc.CFBBlockCipher(pc.AESEngine(), 16);
    cipher.init(true, pc.ParametersWithIV(pc.KeyParameter(keyBytes), ivBytes));

    final cipherBytes = Uint8List(plainBytes.length);
    int offset = 0;
    while (offset < plainBytes.length) {
      final block = Uint8List(16);
      final remaining = plainBytes.length - offset;
      final chunkSize = remaining < 16 ? remaining : 16;
      block.setRange(0, chunkSize, plainBytes.skip(offset).take(chunkSize));

      final outBlock = Uint8List(16);
      cipher.processBlock(block, 0, outBlock, 0);

      cipherBytes.setRange(
        offset,
        offset + chunkSize,
        outBlock.take(chunkSize),
      );
      offset += chunkSize;
    }

    final keyHex = _bytesToHex(keyBytes);
    final encryptedHostHex = _bytesToHex(cipherBytes);

    final path = _innerUrl.replaceFirst('http://$_targetDomain', '');

    return 'https://webvpn.sylu.edu.cn/http/$keyHex$encryptedHostHex$path';
  }

  /// 从 HTML 文档中提取指定 input 的 value
  String _getInputValue(Document doc, String name) {
    var element = doc.querySelector('input[id="$name"]');
    element ??= doc.querySelector('input[name="$name"]');
    return element?.attributes['value'] ?? '';
  }

  /// 使用 RSA Base64 公钥加密字符串，并返回 Base64 编码的密文 (JSEncrypt 兼容)
  String _encryptRsa(String plainText, String publicKeyBase64) {
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
      final cipherBytes = cipher.process(plainBytes);

      return base64Encode(cipherBytes);
    } catch (e) {
      _debugLog('[Crawler] RSA加密失败: $e');
      return plainText;
    }
  }

  /// 辅助方法：byte 数组转小写 Hex 字符串
  String _bytesToHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (int part in bytes) {
      if (part & 0xff != part) {
        throw FormatException("Non-byte integer detected");
      }
      buffer.write('${part < 16 ? '0' : ''}${part.toRadixString(16)}');
    }
    return buffer.toString().toLowerCase();
  }

  /// 从返回的 HTML 源码中提取二课分数列表和汇总数据
  Map<String, dynamic> parseErkeData(String htmlStr) {
    final List<Map<String, String>> scores = [];
    final List<Map<String, String>> summary = [];

    try {
      final document = parse(htmlStr);

      // 1. 解析汇总数据 (尝试从页面顶部提取各类别总分/要求分)
      //    注意：活动查询页(StuActionSearch.aspx)没有汇总数据，汇总在成绩总览页。
      //    但这页的 select 框列出了所有类别，可从明细自行计算。
      final tables = document.querySelectorAll('table');
      for (var table in tables) {
        final text = table.text;
        // 匹配 "思想成长(13.0/10.0)" 这种典型结构
        final regex = RegExp(
          r'([^\d\s\(\/]+)[\s\(\)]*([\d\.]+)\s*/\s*([\d\.]+)',
        );
        final matches = regex.allMatches(text);

        if (matches.isNotEmpty) {
          for (var m in matches) {
            final category = m.group(1)!;
            // 排除掉不相关的词
            if (category.length > 1 && category.length < 10) {
              summary.add({
                'category': category,
                'score': m.group(2)!,
                'required': m.group(3)!,
              });
            }
          }
          if (summary.isNotEmpty) break;
        }
      }

      // 2. 解析详细列表
      var rows = document.querySelectorAll('#GridView1 tr');
      if (rows.isEmpty) rows = document.querySelectorAll('#DataGrid1 tr');
      if (rows.isEmpty) rows = document.querySelectorAll('table tr');

      for (int i = 0; i < rows.length; i++) {
        final row = rows[i];
        final columns = row.querySelectorAll('td');

        if (columns.length >= 8) {
          final itemName = columns[0].text.trim();
          final score = columns[7].text.trim(); // 活动分值
          final date = columns[2].text.trim(); // 活动时间
          var category =
              columns[3].text.trim(); // 活动类型（思想成长/志愿公益/...)  columns[1]是申请单位

          if (itemName.isNotEmpty &&
              !itemName.contains('活动名称') &&
              !itemName.contains('序号')) {
            // 合并分类，对齐教务系统的标准
            if (category == '文体活动' || category == '技能特长') {
              category = '文体活动和技能特长';
            }
            scores.add({
              'item': itemName,
              'score': score,
              'date': date,
              'category': category,
            });
          }
        }
      }

      // 按日期降序排列：最新的在上面
      scores.sort((a, b) {
        final aDate = _parseDate(a['date'] ?? '');
        final bDate = _parseDate(b['date'] ?? '');
        return bDate.compareTo(aDate);
      });

      // 3. 如果页面没有汇总数据，从明细自行计算各类别总分
      if (summary.isEmpty && scores.isNotEmpty) {
        // 各类别要求分（沈理二课标准）
        const requiredScores = <String, double>{
          '思想成长': 10.0,
          '实践实习': 10.0,
          '创新创业': 5.0,
          '志愿公益': 10.0,
          '文体活动和技能特长': 5.0,
        };

        final categoryTotals = <String, double>{};
        for (final s in scores) {
          final cat = s['category'] ?? '';
          if (cat.isEmpty) continue;
          final scoreVal = double.tryParse(s['score'] ?? '0') ?? 0;
          categoryTotals[cat] = (categoryTotals[cat] ?? 0) + scoreVal;
        }

        // 始终展示全部六大类，即使分数为 0
        for (final cat in requiredScores.keys) {
          final score = categoryTotals[cat] ?? 0;
          summary.add({
            'category': cat,
            'score': score.toStringAsFixed(
              score == score.roundToDouble() ? 0 : 1,
            ),
            'required': requiredScores[cat]!.toStringAsFixed(0),
          });
        }

        _debugLog('[Crawler] 从明细计算汇总: ${summary.length} 个类别');
      }
    } catch (e) {
      _debugLog('解析二课数据失败: $e');
    }

    return {'summary': summary, 'scores': scores};
  }

  /// 保持向下兼容
  List<Map<String, String>> parseErkeScores(String htmlStr) {
    return parseErkeData(htmlStr)['scores'].cast<Map<String, String>>();
  }

  /// 从日期字符串 "2024-09-13 00:00:00至..." 中提取 DateTime
  DateTime _parseDate(String dateStr) {
    try {
      final start = dateStr.split('至').first.trim();
      return DateTime.parse(start);
    } catch (_) {
      return DateTime(2000);
    }
  }
}
