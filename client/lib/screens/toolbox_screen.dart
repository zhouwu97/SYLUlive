import 'dart:io' show File, Platform;
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import '../main.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import 'erke_score_screen.dart';
import 'physical_test_screen.dart';

class ToolboxScreen extends StatelessWidget {
  const ToolboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: const Text('工具箱'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: GridView.count(
                padding: const EdgeInsets.all(20),
                crossAxisCount: 3,
                childAspectRatio: 0.85,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: [
                  _buildToolCard(
                    context,
                    icon: Icons.school_outlined,
                    color: Colors.green,
                    title: '二课分查询',
                    subtitle: '支持 WebVPN 穿透',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const ErkeScoreScreen())),
                  ),
                  _buildToolCard(
                    context,
                    icon: Icons.fitness_center,
                    color: Colors.orange,
                    title: '体测成绩',
                    subtitle: '扫码核验 / 查询',
                    onTap: () => _openPhysicalTest(context),
                  ),
                  _buildToolCard(
                    context,
                    icon: Icons.sports_esports,
                    color: const Color(0xFF00BCD4),
                    title: '云原神',
                    subtitle: '点击即玩',
                    onTap: () => _launchCloudGenshin(context),
                  ),
                  _buildToolCard(
                    context,
                    icon: Icons.auto_stories_outlined,
                    color: Colors.blue,
                    title: '更多工具',
                    subtitle: '敬请期待',
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 判断是否为 5月20日
  bool _isMay20() {
    final now = DateTime.now();
    return now.month == 5 && now.day == 20;
  }

  /// 5月20日专属背景
  Widget _build520Background(bool isDark) {
    final image = kIsWeb ? 'assets/images/pcys.png' : 'assets/images/sjys.png';
    debugPrint('520背景: $image (isWeb=$kIsWeb)');
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          image,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (_, e, st) {
            debugPrint('520背景加载失败: $e');
            return _buildDefaultBg(isDark);
          },
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  void _openPhysicalTest(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final username = auth.user?.studentId ?? '';
    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhysicalTestGate(
          username: username,
        ),
      ),
    );
  }

  void _launchCloudGenshin(BuildContext context) async {
    String url;
    LaunchMode mode;

    if (kIsWeb) {
      url = 'https://ys.mihoyo.com/cloud/';
      mode = LaunchMode.platformDefault;
    } else if (Platform.isAndroid) {
      url = 'https://ys.mihoyo.com/cloud/';
      mode = LaunchMode.externalApplication;
    } else if (Platform.isIOS) {
      url = 'https://apps.apple.com/cn/app/id1569029742';
      mode = LaunchMode.externalApplication;
    } else {
      url = 'https://ys.mihoyo.com/cloud/';
      mode = LaunchMode.externalApplication;
    }

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: mode, webOnlyWindowName: '_self');
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接')),
        );
      }
    }
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset('assets/images/$bgPath',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
              : bgPath.startsWith('/')
                  ? Image.file(File(bgPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
                  : Image.network(bgPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark)),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.25),
          ),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/images/morenbeijing.jpeg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                  color:
                      isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
                )),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  Widget _buildToolCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final is520 = _isMay20();

    return GestureDetector(
      onTap: onTap,
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        borderRadius: 20,
        borderColor: is520 ? const Color(0x668BE197) : null,
        backgroundColor: is520
            ? (isDark
                ? Colors.black.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.5))
            : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: isDark ? Colors.white : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: isDark ? Colors.white60 : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 体测密码输入门控 — 独立的 StatefulWidget，避免 controller 生命周期问题
class _PhysicalTestGate extends StatefulWidget {
  final String username;
  const _PhysicalTestGate({required this.username});

  @override
  State<_PhysicalTestGate> createState() => _PhysicalTestGateState();
}

class _PhysicalTestGateState extends State<_PhysicalTestGate> {
  final _pwdCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAutoLogin());
  }

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final pwd = prefs.getString('sylu_physical_test_pwd_${widget.username}');
    if (pwd != null && pwd.isNotEmpty) {
      _pwdCtrl.text = pwd;
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PhysicalTestPage(
              username: widget.username,
              password: pwd,
            ),
          ),
        );
      }
    }
  }

  void _queryManual() {
    final pwd = _pwdCtrl.text;
    if (pwd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入体测密码')),
      );
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PhysicalTestPage(
          username: widget.username,
          password: pwd,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset('assets/images/morenbeijing.jpeg',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                    color: isDark
                        ? const Color(0xFF131720)
                        : const Color(0xFFF4F6FB))),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: GlassContainer(
                  padding: const EdgeInsets.all(28),
                  borderRadius: 24,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.fitness_center,
                            color: Colors.orange, size: 36),
                      ),
                      const SizedBox(height: 16),
                      const Text('体测查询',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text('学号：${widget.username}',
                          style: TextStyle(
                              fontSize: 14,
                              color:
                                  isDark ? Colors.white70 : Colors.grey[700])),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _pwdCtrl,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: '体测密码 (默认111111)',
                          labelStyle: TextStyle(
                              color: isDark ? Colors.white54 : Colors.grey[600]),
                          filled: true,
                          fillColor: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.03),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _queryManual,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('查询',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
