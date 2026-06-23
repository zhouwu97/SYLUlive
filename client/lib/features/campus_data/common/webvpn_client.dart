import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/campus_response_decoder.dart';
import 'package:shenliyuan/features/campus_data/common/cas_crypto.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_url_codec.dart';

class WebVpnClient {
  static final Uri _entryUri =
      Uri.parse('https://webvpn.sylu.edu.cn/login?cas_login=true');
  static final Uri _webVpnRoot = Uri.parse('https://webvpn.sylu.edu.cn/');
  static const _ticketCookieName = 'wengine_vpn_ticketwebvpn_sylu_edu_cn';

  final Dio _dio;
  final CookieJar? _cookieJar;

  WebVpnClient({required Dio dio, CookieJar? cookieJar})
      : _dio = dio,
        _cookieJar = cookieJar;

  /// Performs the WebVPN CAS Login flow.
  /// Throws [CasLoginFailedException] if credentials are wrong.
  Future<void> login(String username, String password) async {
    final casResponse = await _openCasLoginPage();
    if (casResponse == null) {
      return;
    }

    final html = CampusResponseDecoder.decodeResponseBytes(casResponse);
    CampusResponseDecoder.interceptHtmlErrors(
      html,
      realUri: casResponse.realUri,
      context: CampusResponseContext.requestingCasLoginPage,
    );

    final document = html_parser.parse(html);
    _debugCasResponse(casResponse, document);

    final form = document.querySelector('#pwdFromId');
    if (form == null) {
      if (await _hasWebVpnTicket()) {
        return;
      }
      throw const WebVpnPageChangedException('WebVPN CAS 页面缺少 #pwdFromId');
    }

    final salt = _formValue(form, 'pwdEncryptSalt');
    final execution = _formValue(form, 'execution');
    final action = form.attributes['action']?.trim() ?? '';

    if (salt.isEmpty || execution.isEmpty || action.isEmpty) {
      throw const WebVpnPageChangedException('WebVPN CAS 登录表单缺少必要参数');
    }

    final encryptedPassword = CasCrypto.encryptPassword(salt, password);
    final submitUri = casResponse.realUri.resolve(action);
    final submitUriWithService = submitUri.replace(
      queryParameters: {
        ...submitUri.queryParameters,
        'service': _entryUri.toString(),
      },
    );
    final formData = <String, String>{
      'username': username,
      'password': encryptedPassword,
      '_eventId': 'submit',
      'cllt': 'userNameLogin',
      'dllt': 'generalLogin',
      'lt': '',
      'execution': execution,
    };

    final submitResponse = await _dio.post<List<int>>(
      submitUriWithService.toString(),
      data: Uri(queryParameters: formData).query,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
    );

    await _completeLoginRedirects(submitResponse);
  }

  Future<Response<List<int>>?> _openCasLoginPage() async {
    final entryResponse = await _dio.get<List<int>>(
      _entryUri.toString(),
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );

    if (_isRedirect(entryResponse.statusCode)) {
      final location = entryResponse.headers.value('location');
      if (location == '/') {
        return null;
      }
      if (location == null || location.isEmpty) {
        throw const CasLoginFailedException('WebVPN 登录入口没有返回跳转地址');
      }
      return _dio.getUri<List<int>>(
        _entryUri.resolve(location),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    }

    if (entryResponse.statusCode == 200) {
      return entryResponse;
    }

    throw CampusNetworkException(
      'WebVPN 登录入口异常：HTTP ${entryResponse.statusCode}',
    );
  }

  Future<void> _completeLoginRedirects(
    Response<List<int>> initialResponse,
  ) async {
    var response = initialResponse;

    for (var i = 0; i < 8; i++) {
      if (await _hasWebVpnTicket()) {
        return;
      }

      final html = CampusResponseDecoder.decodeResponseBytes(response);
      CampusResponseDecoder.interceptHtmlErrors(
        html,
        realUri: response.realUri,
        context: CampusResponseContext.requestingCasLoginPage,
      );

      if (!_isRedirect(response.statusCode)) {
        if (html.contains('pwdFromId') || html.contains('pwdEncryptSalt')) {
          throw const CasLoginFailedException('统一认证登录失败，请检查账号或密码');
        }
        break;
      }

      final location = response.headers.value('location');
      if (location == null || location.isEmpty) {
        throw const CasLoginFailedException('WebVPN 登录跳转缺少 Location');
      }

      response = await _dio.getUri<List<int>>(
        response.realUri.resolve(location),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    }

    if (!await _hasWebVpnTicket()) {
      throw const CasLoginFailedException('登录流程结束，但未取得 WebVPN Ticket');
    }
  }

  bool _isRedirect(int? statusCode) {
    return statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }

  Future<bool> _hasWebVpnTicket() async {
    final cookieJar = _cookieJar;
    if (cookieJar == null) {
      return false;
    }
    final cookies = await cookieJar.loadForRequest(_webVpnRoot);
    return cookies.any(
      (cookie) =>
          cookie.name == _ticketCookieName && cookie.value.trim().isNotEmpty,
    );
  }

  String _formValue(Element form, String key) {
    return form.querySelector('[name="$key"], #$key')?.attributes['value'] ??
        '';
  }

  void _debugCasResponse(Response<List<int>> response, Document document) {
    if (!kDebugMode) return;

    final title = document.querySelector('title')?.text.trim();
    final forms = document
        .querySelectorAll('form')
        .map((element) => element.id)
        .where((id) => id.isNotEmpty)
        .toList();
    final inputs = document
        .querySelectorAll('input')
        .map((element) => element.attributes['name'] ?? element.id)
        .where((name) => name.isNotEmpty)
        .toList();

    debugPrint(
      'WebVPN CAS response: '
      'status=${response.statusCode}, '
      'uri=${_maskSensitiveUri(response.realUri)}, '
      'contentType=${response.headers.value('content-type')}, '
      'title=$title, '
      'forms=$forms, '
      'inputs=$inputs',
    );
  }

  String _maskSensitiveUri(Uri uri) {
    if (uri.queryParameters.isEmpty) {
      return uri.toString();
    }
    return '${uri.scheme}://${uri.authority}${uri.path}?<redacted>';
  }

  /// Proxy an arbitrary HTTP GET request through WebVPN.
  Future<Response<List<int>>> getProxied(String domain, String path) async {
    return proxyRequest('GET', domain, path);
  }

  /// Proxy an arbitrary HTTP request through WebVPN.
  Future<Response<List<int>>> proxyRequest(
    String method,
    String domain,
    String path, {
    dynamic data,
    Map<String, dynamic>? headers,
  }) async {
    final uri = WebVpnUrlCodec.buildHttpUrl(domain: domain, path: path);
    final response = await _dio.requestUri<List<int>>(
      uri,
      data: data,
      options: Options(
        method: method,
        responseType: ResponseType.bytes,
        headers: headers,
        followRedirects: true,
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    // Check if we hit an access denied
    final html = CampusResponseDecoder.decodeResponseBytes(response);
    CampusResponseDecoder.interceptHtmlErrors(html, realUri: response.realUri);

    return response;
  }
}
