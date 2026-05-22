import 'dart:convert';
import 'dart:io';

void main() async {
  print('=== 课表抓取连通性测试 ===\n');

  // 1. 测试 Python 教务服务健康状态
  print('--- 1. Python 教务服务健康检查 ---');
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('http://101.42.27.44:8000/health'));
    req.headers.set('User-Agent', 'Dart/Test');
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    print('  状态: ${resp.statusCode}');
    print('  响应: $body');
    client.close();
  } catch (e) {
    print('  ❌ 连不上 Python 服务: $e');
  }

  // 2. 直接访问学校官网课表页（不经过 VPN，直接测试 IP 是否被 ban）
  print('\n--- 2. 直连学校官网 ---');
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(
        'https://jxw.sylu.edu.cn/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N253508&layout=default'));
    req.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    print('  状态: ${resp.statusCode}');
    print('  内容长度: ${body.length}');
    print('  前200字符: ${body.substring(0, body.length < 200 ? body.length : 200)}');
    
    if (body.contains('周康武') || body.contains('课表') || body.contains('kbcx')) {
      print('  ✅ 页面正常，未被 ban');
    } else if (body.contains('禁止') || body.contains('拦截') || body.contains('block') || resp.statusCode == 403) {
      print('  ❌ 可能被 ban/403');
    } else {
      print('  ⚠ 页面内容异常，可能需登录');
    }
    client.close();
  } catch (e) {
    print('  ❌ 连接失败: $e');
  }

  // 3. 模拟 Python 服务调用：通过 /api/edu/courses/fetch 获取
  print('\n--- 3. 调用 Python 教务 fetch 接口 ---');
  try {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('http://101.42.27.44:8000/api/edu/courses/fetch'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('User-Agent', 'Dart/Test');
    req.write(jsonEncode({
      'user_id': '2403060128',
      'year': '2025',
      'semester': 12,
    }));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    print('  状态: ${resp.statusCode}');
    print('  响应: ${body.substring(0, body.length < 500 ? body.length : 500)}');
    client.close();
  } catch (e) {
    print('  ❌ 请求失败: $e');
  }

  // 4. 再试 semester=3 (秋季学期)
  print('\n--- 4. 尝试秋季学期 (semester=3) ---');
  try {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('http://101.42.27.44:8000/api/edu/courses/fetch'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('User-Agent', 'Dart/Test');
    req.write(jsonEncode({
      'user_id': '2403060128',
      'year': '2024',
      'semester': 3,
    }));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    print('  状态: ${resp.statusCode}');
    print('  响应: ${body.substring(0, body.length < 500 ? body.length : 500)}');
    client.close();
  } catch (e) {
    print('  ❌ 请求失败: $e');
  }

  print('\n=== 测试完成 ===');
}
