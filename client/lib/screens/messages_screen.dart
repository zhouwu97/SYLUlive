import 'package:flutter/material.dart';

import '../config/private_chat_policy.dart';
import 'chat_list_screen.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 私聊暂停开放期间该入口不提供会话列表；保留占位说明，
    // 避免通过动态路由等方式进入时出现空白页。
    if (!PrivateChatPolicy.enabled) {
      return Scaffold(
        appBar: AppBar(title: const Text('消息')),
        body: const Center(child: Text(PrivateChatPolicy.disabledHint)),
      );
    }
    return const ChatListScreen();
  }
}
