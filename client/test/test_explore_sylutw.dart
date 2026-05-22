import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:html/parser.dart' show parse;
import 'package:shenliyuan/services/webvpn_service.dart';
import 'package:shenliyuan/utils/sylu_client_crawler.dart';
import 'package:cookie_jar/cookie_jar.dart';

void main() async {
  final crawler = SyluClientCrawler();
  final dio = crawler.getDio();
  final webVpn = WebVpnService(); 
  
  try {
    print('=== 1. 执行 VPN 登录 ===');
    final success = await webVpn.login('2403060128', '@Zhoukangwu0');
    final ticket = webVpn.vpnCookie;
    print('VPN 登录结果: $success, Ticket: $ticket');

    print('\n=== 2. 执行系统登录 ===');
    final loginResult = await crawler.login('2403060128', '@Zhoukangwu0', ticket);
    print('登录结果: $loginResult');

    if (loginResult == 'SUCCESS') {
      print('\n=== 3. 获取主框架内容 ===');
      final baseUrl = 'https://webvpn.sylu.edu.cn/http/77726476706e69737468656265737421e8f00f8f3e3c7d1e7b0c9ce29b5b/SyluTW/Sys/';
      
      final mainResp = await dio.get(
        '${baseUrl}SystemForm/main.htm',
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
        )
      );
      
      String mainHtml = crawler.decodeResponseBytes(mainResp.data as List<int>, mainResp.headers);
      print('main.htm 长度: ${mainHtml.length}');
      
      final doc = parse(mainHtml);
      final frames = doc.querySelectorAll('frame, iframe');
      for (final frame in frames) {
        final src = frame.attributes['src'];
        final name = frame.attributes['name'];
        print('发现框架: name=$name, src=$src');
        
        if (src != null && src.toLowerCase().contains('left')) {
          print('\n=== 4. 获取左侧菜单内容: $src ===');
          final menuResp = await dio.get(
            '$baseUrl$src',
            options: Options(
              responseType: ResponseType.bytes,
              followRedirects: false,
            )
          );
          String menuHtml = crawler.decodeResponseBytes(menuResp.data as List<int>, menuResp.headers);
          
          final menuDoc = parse(menuHtml);
          final links = menuDoc.querySelectorAll('a');
          print('发现菜单链接数量: ${links.length}');
          for (final a in links) {
            final href = a.attributes['href'];
            final text = a.text.trim();
            print('菜单: $text -> $href');
          }
          
          if (links.isEmpty) {
             print('由于链接为空，打印原始 HTML:');
             print(menuHtml);
          }
        }
      }
    }
  } catch (e) {
    print('执行失败: $e');
  }
}
