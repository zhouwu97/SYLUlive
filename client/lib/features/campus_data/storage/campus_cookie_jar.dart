import 'package:cookie_jar/cookie_jar.dart';

class CampusCookieJar {
  final CookieJar _cookieJar;

  CampusCookieJar({CookieJar? cookieJar}) : _cookieJar = cookieJar ?? CookieJar();

  CookieJar get innerJar => _cookieJar;

  /// Clears WebVPN and CAS related session cookies
  Future<void> clearWebvpnSession() async {
    final webvpnUrl = Uri.parse('https://webvpn.sylu.edu.cn');
    final ssoUrl = Uri.parse('https://sso.sylu.edu.cn');
    final xgUrl = Uri.parse('https://xg.sylu.edu.cn');

    final urls = [webvpnUrl, ssoUrl, xgUrl];
    for (final url in urls) {
      final cookies = await _cookieJar.loadForRequest(url);
      final cookiesToRemove = [
        'wengine_vpn_ticketwebvpn_sylu_edu_cn',
        'CASTGC',
        'JSESSIONID',
      ];
      
      final newCookies = cookies.where((c) => !cookiesToRemove.contains(c.name)).toList();
      
      // Delete old cookies by setting maxAge = 0
      final deletedCookies = cookies
          .where((c) => cookiesToRemove.contains(c.name))
          .map((c) => Cookie(c.name, '')..maxAge = 0..domain = c.domain..path = c.path)
          .toList();

      await _cookieJar.saveFromResponse(url, deletedCookies);
    }
  }

  /// Completely clears all cookies for total logout
  Future<void> clearAll() async {
    await _cookieJar.deleteAll();
  }
}
