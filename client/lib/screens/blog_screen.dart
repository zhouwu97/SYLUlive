import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';

// ---- 瑞士极客风博客页面 ----

void _showDevSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('还在开发中喵~', style: TextStyle(fontFamily: 'monospace')),
      duration: const Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      backgroundColor: const Color(0xFF334155),
      margin: const EdgeInsets.symmetric(horizontal: 100, vertical: 400),
    ),
  );
}

class BlogScreen extends StatefulWidget {
  const BlogScreen({super.key});

  @override
  State<BlogScreen> createState() => _BlogScreenState();
}

class _BlogScreenState extends State<BlogScreen> {
  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = true; // 博客强制深色模式，护眼

    return Scaffold(
      backgroundColor: Colors.transparent, // 使用全局默认背景
      appBar: _buildAppBar(),
      body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              _buildHeroCard(),
              const SizedBox(height: 20),
              _buildArticleCard(
                title: 'Flutter 状态管理深度对比',
                date: '2026-04-28',
                excerpt: 'Provider、Riverpod、Bloc、GetX — 四种主流方案的优劣分析，以及在不同场景下的选型建议...',
                tags: ['Flutter', '状态管理', '架构'],
              ),
              const SizedBox(height: 14),
              _buildArticleCard(
                title: 'Go 语言并发模式实战',
                date: '2026-04-25',
                excerpt: '从 goroutine 到 channel，从 sync 到 context，深入理解 Go 并发编程的核心模式与陷阱...',
                tags: ['Go', '并发', '后端'],
              ),
              const SizedBox(height: 14),
              _buildArticleCard(
                title: 'PostgreSQL 查询优化指南',
                date: '2026-04-20',
                excerpt: '索引策略、EXPLAIN ANALYZE 解读、慢查询定位 — 让你的数据库查询快 10 倍...',
                tags: ['PostgreSQL', '数据库', '性能'],
              ),
              const SizedBox(height: 14),
              _buildArticleCard(
                title: 'Android 签名机制与 APK 安全',
                date: '2026-04-18',
                excerpt: 'V1/V2/V3 签名方案的区别，release APK 网络权限陷阱，以及常见签名错误排查...',
                tags: ['Android', '安全', 'APK'],
              ),
              // 订阅卡片
              const SizedBox(height: 24),
            ],
          ),
        ],
      ),
    );
  }

  // ---- AppBar ----

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xCC0B1121),
      elevation: 0,
      automaticallyImplyLeading: false,
      title: const Row(
        children: [
          Icon(Icons.terminal, color: Color(0xFF22C55E), size: 22),
          SizedBox(width: 10),
          Text(
            '博客',
            style: TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: Color(0xFFE2E8F0),
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search, color: Color(0xFF64748B), size: 20),
          onPressed: () => _showDevToast(context),
        ),
      ],
    );
  }

  // ---- 顶部精选卡片 ----

  Widget _buildHeroCard() {
    return GestureDetector(
      onTap: () => _openArticle(
        title: 'Flutter 状态管理深度对比',
        content: _sampleFlutterArticle,
        tags: ['Flutter', '状态管理', '架构'],
        date: '2026-04-28',
      ),
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          ),
          border: Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.25), width: 1),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF22C55E).withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            // 装饰代码片段
            Positioned(
              right: -20, top: -10,
              child: Opacity(
                opacity: 0.06,
                child: Text(
                  '</>',
                  style: TextStyle(fontSize: 120, fontWeight: FontWeight.w900, color: Colors.green[300], fontFamily: 'monospace'),
                ),
              ),
            ),
            // 内容
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.3)),
                        ),
                        child: const Text('精选', style: TextStyle(color: Color(0xFF22C55E), fontSize: 10, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Flutter 状态管理深度对比',
                        style: TextStyle(
                          color: Color(0xFFF1F5F9),
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Provider、Riverpod、Bloc、GetX — 四种方案的深入分析',
                        style: TextStyle(
                          color: const Color(0xFF94A3B8),
                          fontSize: 13,
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 文章卡片 ----

  Widget _buildArticleCard({
    required String title,
    required String date,
    required String excerpt,
    required List<String> tags,
  }) {
    return GestureDetector(
      onTap: () => _openArticle(title: title, content: _sampleFlutterArticle, tags: tags, date: date),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B).withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标签
            Wrap(
              spacing: 6, runSpacing: 4,
              children: tags.map((t) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF334155),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(t, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontFamily: 'monospace')),
              )).toList(),
            ),
            const SizedBox(height: 12),
            // 标题
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
            const SizedBox(height: 6),
            // 摘要
            Text(
              excerpt,
              style: TextStyle(
                color: const Color(0xFF64748B),
                fontSize: 13,
                fontFamily: 'monospace',
                height: 1.5,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            // 日期 + 箭头
            Row(
              children: [
                Text(date, style: const TextStyle(color: Color(0xFF475569), fontSize: 11, fontFamily: 'monospace')),
                const Spacer(),
                const Icon(Icons.arrow_forward, color: Color(0xFF475569), size: 16),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showDevToast(BuildContext context) {
    _showDevSnackBar(context);
  }

  // ---- 文章详情 ----

  void _openArticle({
    required String title,
    required String content,
    required List<String> tags,
    required String date,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ArticleReader(
          title: title,
          content: content,
          tags: tags,
          date: date,
        ),
      ),
    );
  }
}

// ---- 文章阅读器 ----

class _ArticleReader extends StatefulWidget {
  final String title;
  final String content;
  final List<String> tags;
  final String date;

  const _ArticleReader({
    required this.title,
    required this.content,
    required this.tags,
    required this.date,
  });

  @override
  State<_ArticleReader> createState() => _ArticleReaderState();
}

class _ArticleReaderState extends State<_ArticleReader> {
  final _commentController = TextEditingController();
  final List<_BlogComment> _comments = [
    _BlogComment(author: 'Doeuny', text: '好文章！状态管理这块一直很困扰我', time: '2小时前'),
    _BlogComment(author: '管理员', text: '建议加上 GetX 的详细对比', time: '1天前'),
  ];

  void _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _addComment() {
    if (_commentController.text.isEmpty) return;
    setState(() {
      _comments.insert(0, _BlogComment(
        author: '我',
        text: _commentController.text,
        time: '刚刚',
      ));
    });
    _commentController.clear();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1121),
      appBar: AppBar(
        backgroundColor: const Color(0xCC0B1121),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF94A3B8)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.title, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600, fontSize: 16, color: Color(0xFFE2E8F0))),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Color(0xFF64748B), size: 20),
            onPressed: () => _showDevSnackBar(context),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _DotGridPainter())),
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
            children: [
              // 标签
              Row(
                children: [
                  ...widget.tags.map((t) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF22C55E).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(t, style: const TextStyle(color: Color(0xFF22C55E), fontSize: 10, fontFamily: 'monospace')),
                    ),
                  )),
                  const Spacer(),
                  Text(widget.date, style: const TextStyle(color: Color(0xFF475569), fontSize: 11, fontFamily: 'monospace')),
                ],
              ),
              const SizedBox(height: 20),
              Text(widget.title, style: const TextStyle(color: Color(0xFFF1F5F9), fontSize: 22, fontWeight: FontWeight.w700, fontFamily: 'monospace', height: 1.3)),
              const SizedBox(height: 8),
              const Text('作者: 沈理校园 · 阅读 5 min', style: TextStyle(color: Color(0xFF64748B), fontSize: 12, fontFamily: 'monospace')),
              const SizedBox(height: 24),
              Divider(color: Colors.white.withValues(alpha: 0.06)),
              const SizedBox(height: 20),
              _buildRichContent(widget.content),
              const SizedBox(height: 14),
              // ---- 紧凑评论区 ----
              _buildComments(),
              const SizedBox(height: 20),
              // 互动栏
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildActionChip(Icons.thumb_up_outlined, '赞'),
                  _buildActionChip(Icons.bookmark_outline, '收藏'),
                  _buildActionChip(Icons.share, '分享'),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComments() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: Colors.white.withValues(alpha: 0.06)),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.chat_bubble_outline, color: Color(0xFF475569), size: 15),
            const SizedBox(width: 6),
            Text('评论 ${_comments.length}', style: const TextStyle(color: Color(0xFF64748B), fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 10),
        // 评论列表 — 最多显示 4 条
        ..._comments.take(4).map((c) => _buildCommentItem(c)),
        const SizedBox(height: 10),
        // 快速回复
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commentController,
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    hintText: '写下你的问题或想法...',
                    hintStyle: TextStyle(color: Color(0xFF475569), fontSize: 12, fontFamily: 'monospace'),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: (_) => _addComment(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _addComment,
                child: const Icon(Icons.send_rounded, color: Color(0xFF22C55E), size: 20),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentItem(_BlogComment comment) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(comment.author[0].toUpperCase(), style: const TextStyle(color: Color(0xFF22C55E), fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(comment.author, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                    const SizedBox(width: 8),
                    Text(comment.time, style: const TextStyle(color: Color(0xFF475569), fontSize: 10, fontFamily: 'monospace')),
                  ],
                ),
                const SizedBox(height: 3),
                Text(comment.text, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontFamily: 'monospace', height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF64748B), size: 18),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontFamily: 'monospace')),
      ],
    );
  }

  Widget _buildRichContent(String text) {
    // 解析链接和代码块
    final urlRegex = RegExp(r'(https?://[^\s]+)');
    final codeRegex = RegExp(r'`([^`]+)`');

    // 按行渲染，处理特殊格式
    final lines = text.split('\n');
    final List<InlineSpan> spans = [];
    bool inCodeBlock = false;

    for (final line in lines) {
      if (line.startsWith('```')) {
        inCodeBlock = !inCodeBlock;
        if (!inCodeBlock) spans.add(const TextSpan(text: '\n'));
        continue;
      }

      if (line.startsWith('## ')) {
        if (spans.isNotEmpty) spans.add(const TextSpan(text: '\n'));
        spans.add(TextSpan(
          text: '${line.substring(3)}\n',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: Color(0xFFE2E8F0), fontFamily: 'monospace', height: 1.5),
        ));
        continue;
      }

      if (line.startsWith('- ')) {
        spans.add(TextSpan(
          text: '  › ${line.substring(2)}\n',
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 15, fontFamily: 'monospace', height: 1.7),
        ));
        continue;
      }

      if (inCodeBlock) {
        spans.add(TextSpan(
          text: '  $line\n',
          style: const TextStyle(color: Color(0xFF22C55E), fontSize: 13, fontFamily: 'monospace', backgroundColor: Color(0x111E293B), height: 1.6),
        ));
        continue;
      }

      // 解析行内链接
      final matches = urlRegex.allMatches(line);
      if (matches.isNotEmpty) {
        int lastEnd = 0;
        for (final match in matches) {
          if (match.start > lastEnd) {
            spans.add(TextSpan(
              text: line.substring(lastEnd, match.start),
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 15, fontFamily: 'monospace', height: 1.7),
            ));
          }
          final url = match.group(0)!;
          spans.add(TextSpan(
            text: url,
            style: const TextStyle(color: Color(0xFF22C55E), fontSize: 15, fontFamily: 'monospace', decoration: TextDecoration.underline, height: 1.7),
            recognizer: TapGestureRecognizer()..onTap = () => _launchUrl(url),
          ));
          lastEnd = match.end;
        }
        if (lastEnd < line.length) {
          spans.add(TextSpan(
            text: '${line.substring(lastEnd)}\n',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 15, fontFamily: 'monospace', height: 1.7),
          ));
        } else {
          spans.add(const TextSpan(text: '\n'));
        }
      } else {
        spans.add(TextSpan(
          text: '$line\n',
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 15, fontFamily: 'monospace', height: 1.7),
        ));
      }
    }

    return SelectableText.rich(
      TextSpan(children: spans),
      style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 15, fontFamily: 'monospace', height: 1.7),
      cursorColor: const Color(0xFF22C55E),
    );
  }
}

// ---- 评论数据 ----

class _BlogComment {
  final String author;
  final String text;
  final String time;
  const _BlogComment({required this.author, required this.text, required this.time});
}

// ---- 点阵背景绘制器 ----

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1E293B).withValues(alpha: 0.4)
      ..strokeWidth = 0.5;

    const spacing = 24.0;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 0.6, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---- 示例文章内容 ----

const _sampleFlutterArticle = '''
## 引言

Flutter 生态中有多种状态管理方案，选择哪一种往往让人纠结。
本文将从实际项目出发，对比四种主流方案的优劣。

## Provider — 官方推荐

Provider 是 Flutter 团队推荐的方案，基于 InheritedWidget 封装：

```dart
class CounterProvider extends ChangeNotifier {
  int _count = 0;
  int get count => _count;
  void increment() { _count++; notifyListeners(); }
}
```

Provider 的优点在于简单直观，学习曲线平缓。但对于复杂应用，
多层嵌套的 Consumer 会导致代码可读性下降。

## Riverpod — Provider 的进化版

Riverpod 解决了 Provider 的一些痛点：
- 编译时安全，不会出现 ProviderNotFoundException

详细信息请查阅官方文档：
https://riverpod.dev

## Bloc — 企业级方案

Bloc 基于事件驱动，强制分离 UI 和业务逻辑。
适合大型团队协作，但模板代码较多。

## 总结

- 小型项目：Provider
- 中型项目：Riverpod
- 大型项目：Bloc
- 不建议：GetX（过度封装，测试困难）
''';
