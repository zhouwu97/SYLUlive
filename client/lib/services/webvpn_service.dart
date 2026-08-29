import 'dart:math';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:html/parser.dart' show parse;

import 'webvpn_tls_config.dart'
    if (dart.library.io) 'webvpn_tls_config_io.dart';

/// 登录失败的结构化分类。只有 [invalidCredentials] 有资格让调用方清除
/// 已保存密码；其余都是链路或上游问题，清密码会导致用户被误要求重输。
enum WebVpnLoginFailureType { invalidCredentials, unavailable, unknown }

/// 网瑞达 WebVPN + CAS 统一认证登录
///
/// 流程: VPN首页 → 302 → CAS登录页 → AES加密密码 → POST → 302 → VPN cookie
class WebVpnService {
  static const String _vpnHost = 'https://webvpn.sylu.edu.cn';

  late final Dio _dio;
  late final CookieJar _jar;
  String? _vpnCookie;
  String? _lastError;
  WebVpnLoginFailureType? _lastFailureType;

  WebVpnService() {
    _jar = CookieJar();
    _dio = Dio(
      BaseOptions(
        followRedirects: false,
        validateStatus: (s) => s != null && s < 500,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Upgrade-Insecure-Requests': '1',
        },
      ),
    );

    configureWebVpnCertificatePolicy(_dio);
    _dio.interceptors.add(CookieManager(_jar));
  }

  Future<bool> login(String username, String password) async {
    try {
      _lastError = null;
      _lastFailureType = null;
      // 清除旧会话 Cookie，防止残留 cookie 使服务器跳过 CAS 重定向
      await _jar.deleteAll();
      _vpnCookie = null;

      // 1. 访问 VPN 首页 → 跟重定向到 CAS
      debugPrint('[VPN] 访问首页...');
      var resp = await _dio.get(_vpnHost);
      String? nextUrl = resp.headers.value('location');
      if (nextUrl == null || nextUrl.isEmpty) {
        // VPN 首页返回 200，无 Location 头 — 从 HTML 中查找 CAS 登录链接
        final html = resp.data.toString();
        final casLinkMatch = RegExp(
          r'href="([^"]*cas_login[^"]*)"',
        ).firstMatch(html);
        if (casLinkMatch != null) {
          final casLink = casLinkMatch.group(1)!.replaceAll('&amp;', '&');
          debugPrint('[VPN] 首页无重定向，已提取 CAS 链接');
          nextUrl = _resolveUrl(casLink);
        } else {
          debugPrint('[VPN] VPN首页未重定向且无CAS链接');
          _lastError = 'WebVPN 未返回统一认证入口，请稍后重试';
          _lastFailureType = WebVpnLoginFailureType.unavailable;
          return false;
        }
      }

      // 2. 跟重定向链直到到达 CAS 登录页（最多8次）
      bool reachedCas = false;
      for (int i = 0; i < 8 && nextUrl != null; i++) {
        final url = _resolveUrl(nextUrl);
        debugPrint('[VPN] 请求: ${_redactUrl(url)}');
        resp = await _dio.get(url);
        debugPrint('[VPN] 响应状态: ${resp.statusCode}');
        final html = resp.data.toString();

        // 打印页面摘要
        final title =
            RegExp(r'<title>([^<]+)</title>').firstMatch(html)?.group(1) ?? '';
        debugPrint('[VPN] 页面标题: $title, 长度: ${html.length}');

        // 注意: 不在此处检查 cookie jar 中的 wrdvpn- ticket！
        // 旧会话的 cookie 可能残留在 jar 中但服务端已失效。
        // 只有完成 CAS 认证流程并跟完所有重定向后，才在 _followRedirects 中验证。

        // 优先跟随 HTTP Location 重定向
        final locationHeader = resp.headers.value('location');
        if (locationHeader != null && locationHeader.isNotEmpty) {
          nextUrl = _resolveUrl(locationHeader, url);
          continue;
        }

        // 检查是否是 CAS 登录页 (有 pwdEncryptSalt)
        if (html.contains('pwdEncryptSalt')) {
          reachedCas = true;
          debugPrint('[VPN] 到达 CAS 登录页');
          final ok = await _submitCasLogin(resp, url, username, password);
          if (ok) return true;
          debugPrint('[VPN] CAS 登录失败');
          _lastError ??= '统一认证登录失败，请检查密码';
          // 密码错误已在 _submitCasLogin 内标记；其余失败按链路问题处理。
          _lastFailureType ??= WebVpnLoginFailureType.unavailable;
          return false;
        }

        // 仅在没有 HTTP 重定向且未到达 CAS 时，跟随 HTML 中的 CAS 链接（并解码 &amp;）
        if (!reachedCas) {
          final casLinkMatch = RegExp(
            r'href="([^"]*cas_login[^"]*)"',
          ).firstMatch(html);
          if (casLinkMatch != null) {
            final casLink = casLinkMatch.group(1)!;
            debugPrint('[VPN] 跟随CAS链接');
            final decodedLink = casLink.replaceAll('&amp;', '&');
            nextUrl = _resolveUrl(decodedLink, url);
            continue;
          }
        }

        // 没有匹配到任何跳转或登录表单，无法继续
        debugPrint('[VPN] 当前页面无可用跳转');
        nextUrl = null;
      }

      debugPrint('[VPN] 未到达 CAS 登录页');
      _lastError = '未能连接到统一认证页面，请检查网络后重试';
      _lastFailureType = WebVpnLoginFailureType.unavailable;
    } on DioException catch (e) {
      _lastError = _describeDioException(e);
      _lastFailureType = WebVpnLoginFailureType.unavailable;
      debugPrint(
        '[VPN] 登录异常: type=${e.type} status=${e.response?.statusCode} cause=${e.error.runtimeType}',
      );
    } catch (e) {
      _lastError = '统一认证流程异常，请稍后重试';
      _lastFailureType = WebVpnLoginFailureType.unknown;
      debugPrint('[VPN] 登录异常: ${e.runtimeType}');
    }
    return false;
  }

  Future<bool> _submitCasLogin(
    Response resp,
    String pageUrl,
    String username,
    String password,
  ) async {
    final html = resp.data.toString();
    final doc = parse(html);

    // 手动收集 CAS 页面返回的所有 Set-Cookie，防止被 WebVPN 代理丢弃
    final casCookiesRaw = <String>[];
    final setCookies = resp.headers['set-cookie'];
    if (setCookies != null) {
      for (final c in setCookies) {
        final name = c.split('=')[0].split(';')[0].trim();
        if (name.isNotEmpty) {
          casCookiesRaw.add(
            '$name=${c.split(';')[0].split('=').skip(1).join('=')}',
          );
        }
      }
    }
    debugPrint('[CAS] CAS页面Set-Cookie数量: ${setCookies?.length ?? 0}');

    // 提取关键字段 — 打印完整的 input 列表辅助调试
    final allInputs = doc.querySelectorAll('input');
    debugPrint('[CAS] 所有input字段:');
    for (final input in allInputs) {
      final n = input.attributes['name'] ?? '';
      final t = input.attributes['type'] ?? 'text';
      if (n.isNotEmpty && t != 'hidden') {
        debugPrint('[CAS]   可见: $n ($t)');
      }
    }

    final salt = _extractValue(doc, 'pwdEncryptSalt') ?? '';
    final execution = _extractValue(doc, 'execution') ?? '';
    final eventId = _extractValue(doc, '_eventId') ?? 'submit';
    const cllt = 'userNameLogin'; // 抓包确认，不用页面提取的值(fidoLogin 是另一个表)
    const dllt = 'generalLogin';
    final lt = _extractValue(doc, 'lt') ?? '';

    debugPrint('[CAS] salt=<redacted> executionLength=${execution.length}');
    debugPrint('[CAS] 登录表单字段已解析');

    // AES 加密密码 — 注意: 密码字段名是 userPassword，但要提交为 password
    final encryptedPwd = _encryptPassword(password, salt);
    debugPrint('[CAS] 加密密码: <redacted>, length=${encryptedPwd.length}');

    // 构造表单 — 严格对齐抓包，不能多字段
    final formData = <String, String>{
      'username': username,
      'password': encryptedPwd,
      '_eventId': eventId,
      'cllt': cllt,
      'dllt': dllt,
      'lt': lt,
      'execution': execution,
    };

    // 找到 form action — 需要补上 service 参数
    final form = doc.querySelector('form');
    String action = pageUrl; // pageUrl 已经带 ?service=...
    if (form != null) {
      final fa = form.attributes['action'] ?? '';
      if (fa.isNotEmpty) {
        final base = fa.startsWith('http') ? fa : _resolveUrl(fa, pageUrl);
        // 如果 form action 不带 service 参数，从页面 URL 提取（保持原始编码）
        if (!base.contains('service=') && pageUrl.contains('service=')) {
          final serviceMatch = RegExp(
            r'[?&]service=([^&]+)',
          ).firstMatch(pageUrl);
          if (serviceMatch != null) {
            action = '$base?service=${serviceMatch.group(1)!}';
          } else {
            action = base;
          }
        } else {
          action = base;
        }
      }
    }
    debugPrint('[CAS] 已解析登录表单 action');
    debugPrint('[CAS] POST 地址: ${_redactUrl(action)}');

    // POST — 拼上 VPN cookie + CAS session cookies
    final allCookies = <String>{};
    if (_vpnCookie != null) allCookies.add(_vpnCookie!);
    // 从 CookieJar 已有的 cookie
    final jarCookies = await _jar.loadForRequest(Uri.parse(pageUrl));
    for (final c in jarCookies) {
      if (c.name.contains('wengine') ||
          c.name.contains('JSESSIONID') ||
          c.name.contains('CASTGC')) {
        allCookies.add('${c.name}=${c.value}');
      }
    }
    // 手动提取的 CAS Set-Cookie
    for (final c in casCookiesRaw) {
      final name = c.split('=')[0];
      if (name.contains('JSESSIONID') ||
          name.contains('CAS') ||
          name.contains('SESSION')) {
        allCookies.add(c);
      }
    }
    final cookieHeader = allCookies.join('; ');
    debugPrint('[CAS] 登录请求Cookie数量: ${allCookies.length}');

    final loginResp = await _dio.post(
      action,
      data: formData,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {
          'Referer': pageUrl,
          'Origin': _extractOrigin(pageUrl),
          if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
        },
      ),
    );

    debugPrint('[CAS] 登录响应: ${loginResp.statusCode}');

    if (loginResp.statusCode == 401) {
      final body = loginResp.data.toString();
      debugPrint('[CAS] 401! bodyLength=${body.length}');
      _lastError = '统一认证登录失败，请检查密码';
      _lastFailureType = WebVpnLoginFailureType.invalidCredentials;
      return false;
    }

    if (loginResp.statusCode == 200) {
      final body = loginResp.data.toString();
      if (body.contains('认证失败') || body.contains('密码错误')) {
        debugPrint('[CAS] 密码错误');
        _lastError = '统一认证登录失败，请检查密码';
        _lastFailureType = WebVpnLoginFailureType.invalidCredentials;
        return false;
      }
      // 某些情况下 200 页面里包含 JavaScript 跳转
      final redirectMatch = RegExp(
        r"window\.location\.href\s*=\s*'([^']+)'",
      ).firstMatch(body);
      if (redirectMatch != null) {
        return await _followRedirects(
          _resolveUrl(redirectMatch.group(1)!, pageUrl),
        );
      }
    }

    if (loginResp.statusCode == 302 || loginResp.statusCode == 301) {
      final loc = loginResp.headers.value('location');
      if (loc != null) return await _followRedirects(_resolveUrl(loc, pageUrl));
    }

    _lastError = '统一认证服务未完成登录，请稍后重试';
    _lastFailureType = WebVpnLoginFailureType.unavailable;
    return false;
  }

  Future<bool> _followRedirects(String startUrl) async {
    String? nextUrl = startUrl;
    // 跟随所有重定向直到链路结束 — 不能在检测到 cookie 时提前退出。
    // WebVPN 的会话在服务端仅当客户端完整走完全部重定向链后才会激活，
    // 提前返回会导致后续访问内网资源时依然被重定向回门户登录页。
    for (int i = 0; i < 10 && nextUrl != null; i++) {
      debugPrint(
        '[VPN] 重定向 $i: ${_redactUrl(nextUrl)}',
      );
      final resp = await _dio.get(nextUrl);

      // 记录 ticket 值（不立即返回，继续跟完剩余的重定向）
      final cookies = await _jar.loadForRequest(Uri.parse(_vpnHost));
      for (final c in cookies) {
        if (c.name.contains('wengine_vpn_ticket') &&
            c.value.startsWith('wrdvpn-')) {
          _vpnCookie = '${c.name}=${c.value}';
          debugPrint('[VPN] 🔑 检测到 VPN ticket，继续走完重定向...');
        }
      }

      // 跟 HTTP Location 重定向
      nextUrl = resp.headers.value('location');
      if (nextUrl != null) {
        nextUrl = _resolveUrl(nextUrl, resp.realUri.toString());
        continue;
      }
      break; // 无更多重定向
    }

    // 全部重定向走完后，再做最终验证
    final finalCookies = await _jar.loadForRequest(Uri.parse(_vpnHost));
    for (final c in finalCookies) {
      if (c.name.contains('wengine_vpn_ticket') &&
          c.value.startsWith('wrdvpn-')) {
        _vpnCookie = '${c.name}=${c.value}';
        debugPrint('[VPN] ✅ 拿到 VPN ticket! 会话已建立');
        return true;
      }
    }
    debugPrint('[VPN] 重定向结束，未找到 VPN ticket');
    return false;
  }

  // ── 辅助方法 ──

  String _resolveUrl(String url, [String base = _vpnHost]) {
    if (url.startsWith('http')) return url;
    if (url.startsWith('//')) return 'https:$url';
    final uri = Uri.parse(base);
    if (url.startsWith('/')) return '${uri.scheme}://${uri.host}$url';
    final basePath = uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
    return '${uri.scheme}://${uri.host}$basePath$url';
  }

  String _extractOrigin(String url) {
    final uri = Uri.parse(url);
    return '${uri.scheme}://${uri.host}';
  }

  String _redactUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}${uri.path}';
    } catch (_) {
      return '<invalid-url>';
    }
  }

  String? _extractValue(dynamic doc, String name) {
    final el = doc.querySelector('#$name, [name="$name"]');
    return el?.attributes['value'];
  }

  /// CAS AES 加密: 64位随机前缀 + 密码 → AES-CBC(salt as key, random IV) → Base64
  String _encryptPassword(String rawPassword, String salt) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random();
    final prefix = List.generate(
      64,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
    final plaintext = prefix + rawPassword;
    final key = encrypt.Key.fromUtf8(salt);
    // 16位随机字符作为 IV — 不能用全零，否则 Java 后端 UTF-8 解码崩溃
    final ivStr = List.generate(
      16,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
    final iv = encrypt.IV.fromUtf8(ivStr);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc),
    );
    return encrypter.encrypt(plaintext, iv: iv).base64;
  }

  String? get vpnCookie => _vpnCookie;
  String? get lastError => _lastError;
  WebVpnLoginFailureType? get lastFailureType => _lastFailureType;
  CookieJar get cookieJar => _jar;
  Dio get dio => _dio;

  void dispose() => _dio.close();

  static void debugPrint(String msg) {
    if (kDebugMode) {
      print('[WebVPN] $msg');
    }
  }

  static String _describeDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return 'WebVPN 连接超时，请检查网络后重试';
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return 'WebVPN 响应超时，请稍后重试';
      case DioExceptionType.badCertificate:
        return 'WebVPN 安全连接校验失败，请稍后重试';
      case DioExceptionType.connectionError:
        final cause = error.error.runtimeType.toString();
        if (cause.contains('Handshake')) {
          return 'WebVPN 安全连接校验失败，请稍后重试';
        }
        return 'WebVPN 网络连接失败，请检查网络后重试';
      case DioExceptionType.badResponse:
        return 'WebVPN 服务响应异常（HTTP ${error.response?.statusCode ?? '未知'}）';
      case DioExceptionType.cancel:
        return 'WebVPN 请求已取消，请重试';
      case DioExceptionType.unknown:
        return 'WebVPN 请求异常，请稍后重试';
    }
  }
}
