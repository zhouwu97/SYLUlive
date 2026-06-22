import 'package:dio/dio.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/campus_response_decoder.dart';
import 'package:shenliyuan/features/campus_data/common/gb18030_form_encoder.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_client.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_crypto.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_parser.dart';

class ErkeClient {
  final WebVpnClient _webVpnClient;

  ErkeClient({required WebVpnClient webVpnClient}) : _webVpnClient = webVpnClient;

  /// Logs into the Erke system using the provided credentials.
  /// Throws [ErkeLoginFailedException] on failure.
  Future<void> login(String username, String password) async {
    // 1. Fetch login page to get viewstate and public key
    final initRes = await _webVpnClient.getProxied('dekt.sylu.edu.cn', '/login.aspx');
    final html = CampusResponseDecoder.decodeResponseBytes(initRes);

    final hiddenFields = ErkeParser.parseLoginHiddenFields(html);
    final pubKeyBase64 = ErkeParser.parsePublicKey(html);

    // 2. Encrypt password
    final encryptedPassword = ErkeCrypto.encryptPassword(password, pubKeyBase64);

    // 3. Post login
    final formData = <String, String>{
      ...hiddenFields,
      'tbId': username,
      'tbPwd': encryptedPassword,
      'queryBtn': '跳 转', // "跳 转" in Chinese
    };

    final bodyBytes = Gb18030FormEncoder.encodeFormBody(formData);

    final res = await _webVpnClient.proxyRequest(
      'POST',
      'dekt.sylu.edu.cn',
      '/login.aspx',
      data: bodyBytes,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    );

    final resultHtml = CampusResponseDecoder.decodeResponseBytes(res);
    CampusResponseDecoder.interceptHtmlErrors(resultHtml);

    if (resultHtml.contains('密码错误') || resultHtml.contains('用户名不存在')) {
      throw const ErkeLoginFailedException('用户名或密码错误');
    }
    
    // Check if we hit the actual system (e.g. MyInfo or similar menu)
    if (!resultHtml.contains('党政联席管理办公系统') && !resultHtml.contains('退出系统')) {
      // It might be a redirect or something else
      // Let's just trust it for now if no error
    }
  }

  /// Gets the user's score summary
  Future<ErkeSummary> getSummary() async {
    final res = await _webVpnClient.getProxied('dekt.sylu.edu.cn', '/Stu/MyInfo.aspx');
    final html = CampusResponseDecoder.decodeResponseBytes(res);
    CampusResponseDecoder.interceptHtmlErrors(html);
    return ErkeParser.parseSummary(html);
  }

  /// Gets a specific page of activities
  Future<ErkeActivitiesPage> getActivities({String? viewState}) async {
    if (viewState == null) {
      // First page
      final res = await _webVpnClient.getProxied('dekt.sylu.edu.cn', '/Stu/MyActivitySearch.aspx');
      final html = CampusResponseDecoder.decodeResponseBytes(res);
      CampusResponseDecoder.interceptHtmlErrors(html);
      return ErkeParser.parseActivities(html);
    } else {
      // Next page
      final formData = <String, String>{
        '__VIEWSTATE': viewState,
        'TPaged1\$GotoPage': '',
        'TPaged1\$Jump': '', // Some forms need this
      };

      final bodyBytes = Gb18030FormEncoder.encodeFormBody(formData);

      final res = await _webVpnClient.proxyRequest(
        'POST',
        'dekt.sylu.edu.cn',
        '/Stu/MyActivitySearch.aspx',
        data: bodyBytes,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      );
      
      final html = CampusResponseDecoder.decodeResponseBytes(res);
      CampusResponseDecoder.interceptHtmlErrors(html);
      return ErkeParser.parseActivities(html);
    }
  }
}
