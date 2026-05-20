import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'package:html/parser.dart' show parse;
import 'package:fast_gbk/fast_gbk.dart';

/// 纯客户端的前端爬虫工具类
/// 用于在用户的手机本地直接穿透深信服 WebVPN，并模拟登录内网的 ASP.NET WebForms 二课系统。
class SyluClientCrawler {
  late final Dio _dio;
  late final CookieJar _cookieJar;

  /// WebVPN 加密的 Key 和 IV (固定)
  static const String _vpnKeyIvStr = 'wrdvpnisthebest!';

  /// 原始内网登录地址
  static const String _innerUrl =
      'http://xg.sylu.edu.cn/SyluTW/Sys/SystemForm/main.htm';

  /// 域名部分，用于加密
  static const String _targetDomain = 'xg.sylu.edu.cn';

  SyluClientCrawler() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Connection': 'keep-alive',
      },
      // 允许所有重定向
      followRedirects: true,
      validateStatus: (status) {
        return status != null && status < 500;
      },
    ));
    
    // 【核心修复】：强制信任所有证书 (相当于 Python 的 verify=False)
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 强制返回 true，忽略任何证书错误
        client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
        return client;
      },
    );

    _cookieJar = CookieJar();
    _dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// 执行登录并返回结果 (HTML 源码)
  /// [username]: 学号
  /// [password]: 明文密码
  /// [vpnTicket]: WebVPN 的认证 Ticket (通常是 wengine_vpn_ticketwebvpn_sylu_edu_cn)
  Future<String> fetchErkeData(
      String username, String password, String vpnTicket) async {
    // 1. 初始化 Cookie
    await _injectVpnCookie(vpnTicket);

    // 2. 生成加密后的 WebVPN 目标 URL
    final encryptedUrl = _buildVpnUrl();

    // 3. 踩点请求 (GET) - 必须用 ResponseType.bytes 防止 GBK 乱码
    final getResp = await _dio.get(
      encryptedUrl,
      options: Options(responseType: ResponseType.bytes),
    );

    // 使用 fast_gbk 将字节流解码为字符串
    final htmlStr = gbk.decode(getResp.data as List<int>);

    // 4. 解析提取 ASP.NET 隐藏字段和 RSA 公钥
    final doc = parse(htmlStr);

    final viewState = _getInputValue(doc, '__VIEWSTATE');
    final viewStateGen = _getInputValue(doc, '__VIEWSTATEGENERATOR');
    final eventValidation = _getInputValue(doc, '__EVENTVALIDATION');
    final pubKeyBase64 = _getInputValue(doc, 'pubKey');

    if (pubKeyBase64.isEmpty) {
      throw Exception('未能从页面提取到 RSA 公钥 (pubKey字段不存在)');
    }

    // 5. 使用 RSA 公钥加密密码
    final encryptedPwd = _encryptRsa(password, pubKeyBase64);

    // 6. 构造表单数据并进行 GBK 编码的 UrlEncode
    final Map<String, String> formData = {
      'UserName': username,
      'Password': password, // ASP.NET 原生需要明文，同时带着 RSA 的 pwd 字段
      'pwd': encryptedPwd,
      'pubKey': pubKeyBase64,
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      '__EVENTVALIDATION': eventValidation,
    };

    // [极度关键]：将表单数据转换为 GBK 字节流并 UrlEncode
    final encodedPayload = _encodeFormGbk(formData);

    // 7. 提交登录 (POST)
    final postResp = await _dio.post(
      encryptedUrl,
      data: encodedPayload,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': encryptedUrl, // 防盗链
        },
      ),
    );

    final resultHtml = gbk.decode(postResp.data as List<int>);
    
    // 如果登录成功，结果 HTML 通常会包含系统的框架页面或者重定向提示
    // 你可以在这里解析 resultHtml 并提取后续需要的具体二课数据
    return resultHtml;
  }

  /// 注入传入的 WebVPN Cookie
  Future<void> _injectVpnCookie(String vpnTicket) async {
    final vpnUri = Uri.parse('https://webvpn.sylu.edu.cn');
    // 如果你的 ticket 字符串没有包含 key=value，可以在这里补全，例如 'wengine_vpn_ticketwebvpn_sylu_edu_cn=...'
    // 这里假设传入的 vpnTicket 就是纯 value 或者是完整的 key=value
    String cookieStr = vpnTicket;
    if (!cookieStr.contains('=')) {
      cookieStr = 'wengine_vpn_ticketwebvpn_sylu_edu_cn=$vpnTicket';
    }

    await _cookieJar.saveFromResponse(
      vpnUri,
      [Cookie.fromSetCookieValue(cookieStr)],
    );
  }

  /// 构造 WebVPN 加密后的目标 URL
  /// 规则：https://webvpn.sylu.edu.cn/http/ + Hex(Key) + Hex(AES_CFB(xg.sylu.edu.cn)) + 路径
  String _buildVpnUrl() {
    final keyBytes = utf8.encode(_vpnKeyIvStr) as Uint8List;
    final ivBytes = utf8.encode(_vpnKeyIvStr) as Uint8List;
    final plainBytes = utf8.encode(_targetDomain) as Uint8List;

    // 2. 初始化 AES-CFB-128 加密器 (16 代表 128位 块大小)
    final cipher = pc.CFBBlockCipher(pc.AESEngine(), 16);
    cipher.init(true, pc.ParametersWithIV(pc.KeyParameter(keyBytes), ivBytes));

    // 3. CFBBlockCipher 是块加密器，我们必须按 16 字节块处理并手动处理尾部
    final cipherBytes = Uint8List(plainBytes.length);
    int offset = 0;
    while (offset < plainBytes.length) {
      final block = Uint8List(16); // 保证喂给它的是严格的 16 字节
      final remaining = plainBytes.length - offset;
      final chunkSize = remaining < 16 ? remaining : 16;
      block.setRange(0, chunkSize, plainBytes.skip(offset).take(chunkSize));
      
      final outBlock = Uint8List(16);
      cipher.processBlock(block, 0, outBlock, 0); // 现在绝对不会报 buffer too short
      
      // 取回实际需要的长度
      cipherBytes.setRange(offset, offset + chunkSize, outBlock.take(chunkSize));
      offset += chunkSize;
    }

    // 5. 转换为小写 hex
    final keyHex = _bytesToHex(keyBytes);
    final encryptedHostHex = _bytesToHex(cipherBytes);
    
    final path = _innerUrl.replaceFirst('http://$_targetDomain', '');
    
    return 'https://webvpn.sylu.edu.cn/http/$keyHex/$encryptedHostHex$path';
  }

  /// 从 HTML 文档中提取指定 input 的 value
  String _getInputValue(var document, String idOrName) {
    var element = document.querySelector('input[id="$idOrName"]');
    element ??= document.querySelector('input[name="$idOrName"]');
    return element?.attributes['value'] ?? '';
  }

  /// 使用 RSA Base64 公钥加密字符串，并返回 Base64 编码的密文
  String _encryptRsa(String plainText, String publicKeyBase64) {
    // 1. 解析 Base64 为 Uint8List
    final publicKeyBytes = base64Decode(publicKeyBase64);

    // 2. 解析 ASN.1 格式的公钥
    final asn1Parser = ASN1Parser(publicKeyBytes);
    final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;
    
    ASN1Integer modulus;
    ASN1Integer exponent;
    
    // 兼容 PKCS#1 或 PKCS#8 格式
    if (topLevelSeq.elements![0] is ASN1Integer) {
      // PKCS#1 格式: RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
      modulus = topLevelSeq.elements![0] as ASN1Integer;
      exponent = topLevelSeq.elements![1] as ASN1Integer;
    } else {
      // PKCS#8 格式: SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
      final subjectPublicKey = topLevelSeq.elements![1] as ASN1BitString;
      // 内部再包含一个 RSAPublicKey SEQUENCE
      final innerParser = ASN1Parser(subjectPublicKey.contentBytes()!);
      final pkSeq = innerParser.nextObject() as ASN1Sequence;
      modulus = pkSeq.elements![0] as ASN1Integer;
      exponent = pkSeq.elements![1] as ASN1Integer;
    }

    final rsaPublicKey = pc.RSAPublicKey(modulus.valueAsBigInteger, exponent.valueAsBigInteger);

    // 3. 初始化 RSA 加密引擎 (PKCS1 填充)
    final cipher = pc.PKCS1Encoding(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(rsaPublicKey));

    // 4. 加密
    final plainBytes = utf8.encode(plainText) as Uint8List;
    final cipherBytes = cipher.process(plainBytes);

    // 5. 返回 Base64
    return base64Encode(cipherBytes);
  }

  /// 构造 GBK 编码的 UrlEncode 字符串
  String _encodeFormGbk(Map<String, String> data) {
    final buffer = StringBuffer();
    bool first = true;
    
    data.forEach((key, value) {
      if (!first) {
        buffer.write('&');
      }
      buffer.write(_urlEncodeGbk(key));
      buffer.write('=');
      buffer.write(_urlEncodeGbk(value));
      first = false;
    });

    // 必须追加固定的登录按钮参数
    if (!first) {
      buffer.write('&');
    }
    buffer.write('queryBtn=%B5%C7++++++++++++%C2%BC'); // "登录" 的 GBK UrlEncode

    return buffer.toString();
  }

  /// 将字符串按 GBK 编码进行 UrlEncode
  String _urlEncodeGbk(String str) {
    final gbkBytes = gbk.encode(str);
    final buffer = StringBuffer();
    for (int byte in gbkBytes) {
      // 保留字母、数字和一些安全字符
      if ((byte >= 0x30 && byte <= 0x39) || // 0-9
          (byte >= 0x41 && byte <= 0x5A) || // A-Z
          (byte >= 0x61 && byte <= 0x7A) || // a-z
          byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E) { // - . _ ~
        buffer.writeCharCode(byte);
      } else {
        // 其他字符转为 %XX
        buffer.write('%');
        buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return buffer.toString();
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

  /// 从返回的 HTML 源码中提取二课分数列表
  List<Map<String, String>> parseErkeScores(String htmlStr) {
    final List<Map<String, String>> results = [];
    try {
      final document = parse(htmlStr);
      // 假设目标数据在 id 为 DataGrid1 的表格中
      final rows = document.querySelectorAll('#DataGrid1 tr');
      
      for (int i = 0; i < rows.length; i++) {
        final row = rows[i];
        final columns = row.querySelectorAll('td');
        
        // 过滤掉表头（如果有的话）或列数不足的行
        if (columns.length > 2) {
          final itemName = columns[0].text.trim();
          final score = columns[1].text.trim();
          // 如果表格有第三列是日期，也可以提取出来，这里简单回退
          final date = columns.length > 2 ? columns[2].text.trim() : '';

          // 避免把纯标题行加进去（视具体 HTML 结构而定）
          if (itemName.isNotEmpty && itemName != '活动名称') {
            results.add({
              'item': itemName,
              'score': score,
              'date': date,
            });
          }
        }
      }
    } catch (e) {
      print('解析二课数据失败: $e');
    }
    return results;
  }
}
