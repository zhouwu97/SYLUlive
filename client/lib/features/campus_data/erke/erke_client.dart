import 'package:dio/dio.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/campus_response_decoder.dart';
import 'package:shenliyuan/features/campus_data/common/gb18030_form_encoder.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_client.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_crypto.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_parser.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_url_codec.dart';

import 'package:shenliyuan/features/campus_data/common/erke_endpoints.dart';

class ErkeClient {
  final WebVpnClient _webVpnClient;

  ErkeClient({required WebVpnClient webVpnClient})
      : _webVpnClient = webVpnClient;

  /// Logs into the Erke system using the provided credentials.
  /// Throws [ErkeLoginFailedException] on failure.
  Future<void> login(String username, String password) async {
    // 1. Fetch login page
    String? finalHtml;
    String? currentPath;
    
    for (final path in ErkeEndpoints.loginPaths) {
      final res = await _webVpnClient.getProxied(ErkeEndpoints.domain, path);
      final html = CampusResponseDecoder.decodeResponseBytes(res);
      
      if (html.contains('UserName') && html.contains('code-box')) {
        finalHtml = html;
        currentPath = path;
        break;
      }
    }
    
    if (finalHtml == null || currentPath == null) {
      throw const ErkePageChangedException('未找到二课登录页面或页面已失效');
    }

    final formData = ErkeParser.parseLoginForm(finalHtml);
    final pubKeyBase64 = ErkeParser.parsePublicKey(finalHtml);

    // 2. Encrypt password
    final encryptedPassword = ErkeCrypto.encryptPassword(password, pubKeyBase64);

    // 3. Post login
    formData['UserName'] = username;
    formData['Password'] = password;
    formData['pwd'] = encryptedPassword;
    formData['pubKey'] = pubKeyBase64;
    // captcha is already set to codeInput in parseLoginForm
    // queryBtn is also dynamically read by parseLoginForm if present

    final bodyBytes = Gb18030FormEncoder.encodeFormBody(formData);

    final res = await _webVpnClient.proxyRequest(
      'POST',
      ErkeEndpoints.domain,
      currentPath,
      data: bodyBytes,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    );

    final resultHtml = CampusResponseDecoder.decodeResponseBytes(res);
    CampusResponseDecoder.interceptHtmlErrors(resultHtml, realUri: res.realUri);

    // Check by fetching summary page instead of relying on redirect
    try {
      await getSummary();
    } on CampusDataException {
      rethrow;
    } catch (e) {
      throw ErkeLoginFailedException('二课登录失败: 无法访问受保护的成绩页面 ($e)');
    }
  }

  /// Gets the user's score summary
  Future<ErkeSummary> getSummary() async {
    final res = await _webVpnClient.getProxied(ErkeEndpoints.domain, ErkeEndpoints.summaryPath);
    final html = CampusResponseDecoder.decodeResponseBytes(res);
    CampusResponseDecoder.interceptHtmlErrors(html, realUri: res.realUri);
    return ErkeParser.parseSummary(html);
  }

  /// Gets a specific page of activities
  Future<ErkeActivitiesPage> getActivitiesPage(int pageNumber, {Map<String, String>? hiddenFields}) async {
    if (pageNumber == 1 || hiddenFields == null) {
      // First page
      final res = await _webVpnClient.getProxied(ErkeEndpoints.domain, ErkeEndpoints.activityPath);
      final html = CampusResponseDecoder.decodeResponseBytes(res);
      CampusResponseDecoder.interceptHtmlErrors(html, realUri: res.realUri);
      return ErkeParser.parseActivities(html);
    } else {
      // Next page
      final formData = <String, String>{
        ...hiddenFields,
        'YearTime': '',
        'ActivityType': '',
        'OrgNo': '',
        'ActivityName': '',
        'TPaged1\$GotoPage': pageNumber.toString(),
        'TPaged1\$Jump': '跳 转',
      };

      final bodyBytes = Gb18030FormEncoder.encodeFormBody(formData);

      final res = await _webVpnClient.proxyRequest(
        'POST',
        ErkeEndpoints.domain,
        ErkeEndpoints.activityPath,
        data: bodyBytes,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': WebVpnUrlCodec.buildHttpUrl(domain: ErkeEndpoints.domain, path: ErkeEndpoints.activityPath).toString(),
        },
      );

      final html = CampusResponseDecoder.decodeResponseBytes(res);
      CampusResponseDecoder.interceptHtmlErrors(html, realUri: res.realUri);
      final page = ErkeParser.parseActivities(html);
      
      if (page.currentPage != pageNumber) {
        throw ErkePageChangedException(
          '请求第 $pageNumber 页，但服务器返回第 ${page.currentPage} 页',
        );
      }
      
      return ErkeActivitiesPage(
        activities: page.activities,
        currentPage: pageNumber,
        totalPages: page.totalPages,
        hiddenFields: page.hiddenFields,
      );
    }
  }
}
