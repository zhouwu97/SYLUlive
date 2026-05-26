import 'package:flutter/material.dart';
import '../widgets/yuketang_webview_widget.dart';

class YuketangClassScreen extends StatefulWidget {
  const YuketangClassScreen({Key? key}) : super(key: key);

  @override
  State<YuketangClassScreen> createState() => _YuketangClassScreenState();
}

class _YuketangClassScreenState extends State<YuketangClassScreen> {
  final GlobalKey<YuketangWebViewWidgetState> _webViewKey = GlobalKey();

  Future<void> _handleBack() async {
    final controller = _webViewKey.currentState?.webViewController;
    if (controller != null && await controller.canGoBack()) {
      controller.goBack();
    } else {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('长江雨课堂'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _webViewKey.currentState?.webViewController?.reload();
              },
            ),
          ],
        ),
        body: YuketangWebViewWidget(
          key: _webViewKey,
          url: 'https://changjiang.yuketang.cn/v2/web/index',
        ),
      ),
    );
  }
}
