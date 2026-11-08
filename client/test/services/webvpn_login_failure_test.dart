import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/webvpn_service.dart';

void main() {
  for (final status in [200, 401]) {
    for (final body in [
      '<h1>学校认证服务暂不可用</h1>',
      "<script>function fail() { alert('密码错误'); }</script><p>认证失败，请稍后重试</p>",
      '<p>登录失败</p>',
      '<p>请输入用户名或密码</p>',
      '<p>用户名或密码错误</p>',
    ]) {
      test('CAS $status 通用失败不能标记密码无效：$body', () async {
        final vpn = WebVpnService();
        addTearDown(vpn.dispose);
        vpn.dio.interceptors.insert(0,
            InterceptorsWrapper(onRequest: (options, handler) {
          final isHome = options.uri.path.isEmpty;
          handler.resolve(Response(
            requestOptions: options,
            statusCode: options.method == 'POST'
                ? status
                : isHome
                    ? 302
                    : 200,
            headers: Headers.fromMap({
              if (isHome) 'location': ['https://webvpn.sylu.edu.cn/cas']
            }),
            data: options.method == 'POST'
                ? body
                : '<form action="/cas"><input id="pwdEncryptSalt" value="1234567890123456"></form>',
          ));
        }));
        expect(await vpn.login('fixture-student', 'fixture-secret'), isFalse);
        expect(
            vpn.lastFailureType,
            body == '<p>用户名或密码错误</p>'
                ? WebVpnLoginFailureType.invalidCredentials
                : WebVpnLoginFailureType.unavailable);
      });
    }
  }
}
