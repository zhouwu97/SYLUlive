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
    final initResponse = await _dio.get<List<int>>(
      'https://webvpn.sylu.edu.cn/login',
      options: Options(responseType: ResponseType.bytes),
    );

    final html = CampusResponseDecoder.decodeResponseBytes(initResponse);
    CampusResponseDecoder.interceptHtmlErrors(html);

    // Parse the form
    final doc = html_parser.parse(html);
    final saltNode = doc.getElementById('pwdEncryptSalt');
    final execNode = doc.getElementById('execution');
    final formNode = doc.getElementById('casLoginForm');

    if (saltNode == null || execNode == null || formNode == null) {
      throw const ErkeDecodeException('未能解析 WebVPN CAS 登录表单');
    }

    final salt = saltNode.attributes['value'] ?? '';
    final execution = execNode.attributes['value'] ?? '';
    final action = formNode.attributes['action'] ?? '';

    if (salt.isEmpty || execution.isEmpty || action.isEmpty) {
      throw const ErkeDecodeException('CAS 登录表单缺少必要参数');
    }

    // 2. Encrypt password
    final encryptedPassword = CasCrypto.encryptPassword(salt, password);

    // 3. Submit login
    final submitUrl = 'https://webvpn.sylu.edu.cn\$action';
    final formData = {
      'username': username,
      'password': encryptedPassword,
      'execution': execution,
      '_eventId': 'submit',
      'geolocation': '',
    };

    final submitResponse = await _dio.post<List<int>>(
      submitUrl,
      data: FormData.fromMap(formData),
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
    CampusResponseDecoder.interceptHtmlErrors(resultHtml);

    // At this point, Dio + CookieJar automatically saved the JSESSIONID, CASTGC and wengine_vpn_ticket.
    // If it didn't throw CasLoginFailedException from interceptHtmlErrors, we assume success.
    // We can also verify we are back at the webvpn index or the cookie is present.
    if (resultHtml.contains('密码错误')) {
      throw const CasLoginFailedException('密码错误');
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
    CampusResponseDecoder.interceptHtmlErrors(html);

    return response;
  }
}
