import 'package:flutter/services.dart';

import '../models/post.dart';

/// 帖子正文复制的统一入口。
///
/// 只处理文本整理和系统剪贴板写入，不负责页面反馈，避免不同页面
/// 因为各自实现而产生不一致的空文本和换行行为。
class PostClipboard {
  const PostClipboard._();

  /// 正文优先；正文为空时回退到标题。保留正文内部换行，只清理首尾空白。
  static String textFor(Post post) {
    final content = post.content.trim();
    if (content.isNotEmpty) return content;
    return post.title.trim();
  }

  /// 写入帖子可复制文本。没有可复制内容时返回 false，不触发系统调用。
  static Future<bool> copy(Post post) async {
    final text = textFor(post);
    if (text.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  }
}
