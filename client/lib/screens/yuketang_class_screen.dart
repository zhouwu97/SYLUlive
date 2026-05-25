import 'package:flutter/material.dart';
import '../widgets/yuketang_webview_widget.dart';

class YuketangClassScreen extends StatelessWidget {
  const YuketangClassScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('长江雨课堂'),
        // 允许用户刷新 WebView
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              // 如果需要在这里控制全局 WebView 刷新，可以通过 GlobalKey 或别的方式通知组件
            },
          ),
        ],
      ),
      // 直接铺满主体内容，引入实装好的探针浏览器组件
      body: const YuketangWebViewWidget(
        url: 'https://pro.yuketang.cn/v2/web/index', // 雨课堂入口地址
      ),
    );
  }
}
