import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/storage/campus_cookie_jar.dart';

void main() {
  group('CampusCookieJar', () {
    test('clearWebvpnSession clears specific cookies across domains', () async {
      final jar = CookieJar();
      final campusJar = CampusCookieJar(cookieJar: jar);

      final webvpnUrl = Uri.parse('https://webvpn.sylu.edu.cn');
      await jar.saveFromResponse(webvpnUrl, [
        Cookie('wengine_vpn_ticketwebvpn_sylu_edu_cn', 'dummy_ticket'),
        Cookie('other_cookie', 'keep_me'),
      ]);

      final ssoUrl = Uri.parse('https://sso.sylu.edu.cn');
      await jar.saveFromResponse(ssoUrl, [
        Cookie('CASTGC', 'dummy_tgc'),
      ]);

      final xgUrl = Uri.parse('https://xg.sylu.edu.cn');
      await jar.saveFromResponse(xgUrl, [
        Cookie('JSESSIONID', 'dummy_session'),
        Cookie('other_xg_cookie', 'keep_me2'),
      ]);

      await campusJar.clearWebvpnSession();

      final webvpnCookies = await jar.loadForRequest(webvpnUrl);
      expect(webvpnCookies.length, 1);
      expect(webvpnCookies.first.name, 'other_cookie');

      final ssoCookies = await jar.loadForRequest(ssoUrl);
      expect(ssoCookies.isEmpty, isTrue);

      final xgCookies = await jar.loadForRequest(xgUrl);
      expect(xgCookies.length, 1);
      expect(xgCookies.first.name, 'other_xg_cookie');
    });

    test('clearAll clears all cookies', () async {
      final campusJar = CampusCookieJar();
      final url = Uri.parse('https://webvpn.sylu.edu.cn');
      
      await campusJar.innerJar.saveFromResponse(url, [
        Cookie('some_cookie', 'val'),
      ]);

      await campusJar.clearAll();

      final cookies = await campusJar.innerJar.loadForRequest(url);
      expect(cookies.isEmpty, isTrue);
    });
  });
}
