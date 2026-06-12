import 'package:flutter/material.dart';
import 'chat_detail_screen.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final List<Map<String, String>> dummyChats = [
      {
        'name': '系统通知',
        'avatar': '',
        'lastMessage': '欢迎来到沈理校园！有任何建议欢迎反馈。',
        'time': '10:00',
        'unread': '1',
      },
      {
        'name': '张三 (测试用户)',
        'avatar': '',
        'lastMessage': '学长，这个题目怎么做呀？',
        'time': '昨天',
        'unread': '0',
      },
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('私信'),
      ),
      body: ListView.builder(
        itemCount: dummyChats.length,
        itemBuilder: (context, index) {
          final chat = dummyChats[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
              child: Text(
                chat['name']![0],
                style: TextStyle(color: Theme.of(context).primaryColor),
              ),
            ),
            title: Text(chat['name']!),
            subtitle: Text(
              chat['lastMessage']!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(chat['time']!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                if (chat['unread'] != '0')
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      chat['unread']!,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(userName: chat['name']!),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
