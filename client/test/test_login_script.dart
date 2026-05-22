import 'package:shenliyuan/services/webvpn_service.dart';
import 'package:shenliyuan/utils/sylu_client_crawler.dart';

void main() async {
  print('=== 体测/二课 端到端测试 ===');
  final vpn = WebVpnService();

  // Step 1: CAS 登录
  print('\n--- Step 1: CAS 统一认证登录 ---');
  final success = await vpn.login('2403060128', '@Zhoukangwu0');
  print('登录结果: $success');

  if (!success) {
    print('❌ CAS 登录失败，终止');
    return;
  }

  print('✅ CAS 登录成功');
  print('VPN Cookie: ${vpn.vpnCookie}');

  // Step 2: 用共享的 CookieJar 抓取二课
  print('\n--- Step 2: 穿透 VPN 抓取二课 ---');
  final crawler = SyluClientCrawler(cookieJar: vpn.cookieJar);

  try {
    final html = await crawler.login('2403060128', '@Zhoukangwu0', vpn.vpnCookie);
    print('HTML 长度: ${html.length}');

    if (html.contains('<form') && html.contains('pubKey')) {
      print('✅ 二课登录页获取成功 (含 RSA pubKey)');
    } else if (html.contains('沈阳理工大学资源访问控制系统')) {
      print('❌ 仍然是 VPN 登录页 — Cookie 未生效');
    } else {
      print('=== 完整 HTML ===');
      print(html);
      print('=== HTML 结束 ===');
    }

    final data = crawler.parseErkeData(html);
    final scores = data['scores'] as List;
    final summary = data['summary'] as List;
    print('\n--- 解析结果 ---');
    print('明细成绩: ${scores.length} 条');
    for (final s in scores) {
      print('  ${s['item']} → +${s['score']} (${s['date']}) [${s['category']}]');
    }
    print('\n--- 汇总（各类别总分）---');
    if (summary.isNotEmpty) {
      for (final s in summary) {
        final score = double.tryParse(s['score'] ?? '0') ?? 0;
        final required = double.tryParse(s['required'] ?? '10') ?? 10;
        final gap = required - score;
        print('  ${s['category']}: ${s['score']} / ${s['required']} ${gap <= 0 ? '✓' : '还差$gap'}');
      }
    } else {
      print('  ⚠ 未解析到汇总数据');
    }
  } catch (e, st) {
    print('❌ 爬虫异常: $e');
    print(st);
  }
}
