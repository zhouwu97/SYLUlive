import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/campus_response_decoder.dart';
import 'package:shenliyuan/features/campus_data/common/cas_crypto.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_url_codec.dart';

class WebVpnClient {
  final Dio _dio;

  WebVpnClient({required Dio dio}) : _dio = dio;

  /// Performs the WebVPN CAS Login flow.
  /// Throws [CasLoginFailedException] if credentials are wrong.
  Future<void> login(String username, String password) async {
    // 1. Initiate login
    Response<List<int>> response = await _dio.get<List<int>>(
      'https://webvpn.sylu.edu.cn/',
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (status) => status != null && status < 400,
      ),
    );

    String html = CampusResponseDecoder.decodeResponseBytes(response);
    CampusResponseDecoder.interceptHtmlErrors(html, realUri: response.realUri);

    // Parse the form
    var doc = html_parser.parse(html);
    var saltNode = doc.getElementById('pwdEncryptSalt');
    var execNode = doc.getElementById('execution');
    var formNode = doc.getElementById('casLoginForm');

    if (saltNode == null || execNode == null || formNode == null) {
      throw const ErkePageChangedException('未能解析 WebVPN CAS 登录表单');
    }

    final salt = saltNode.attributes['value'] ?? '';
    final execution = execNode.attributes['value'] ?? '';
    final action = formNode.attributes['action'] ?? '';

    if (salt.isEmpty || execution.isEmpty || action.isEmpty) {
      throw const ErkePageChangedException('CAS 登录表单缺少必要参数');
    }

    // 2. Encrypt password
    final encryptedPassword = CasCrypto.encryptPassword(salt, password);

    // 3. Submit login
    final submitUri = response.realUri.resolve(action);
    final formData = {
      'username': username,
      'password': encryptedPassword,
      'execution': execution,
      '_eventId': 'submit',
      'geolocation': '',
    };

    final submitResponse = await _dio.post<List<int>>(
      submitUri.toString(),
      data: Uri(queryParameters: formData).query,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (status) => status != null && status < 500,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
    );

    final resultHtml =
        CampusResponseDecoder.decodeResponseBytes(submitResponse);
    CampusResponseDecoder.interceptHtmlErrors(resultHtml, realUri: submitResponse.realUri);

    // Verify if we actually logged in by checking if we hit the success page or an index
    if (submitResponse.realUri.path.toLowerCase().endsWith('/login') && resultHtml.contains('pwdEncryptSalt')) {
      throw const CasLoginFailedException('统一认证登录失败，可能密码错误或认证失效');
    }
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
