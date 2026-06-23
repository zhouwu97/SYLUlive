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
import 'lottery_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:ui';
import 'yuketang_class_screen.dart';
import 'exam_schedule_screen.dart';

class ToolboxScreen extends StatefulWidget {
  const ToolboxScreen({super.key});

  @override
  State<ToolboxScreen> createState() => _ToolboxScreenState();
}

class _ToolboxScreenState extends State<ToolboxScreen> {
  final _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          centerTitle: false,
          foregroundColor: Colors.white,
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '工具箱',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: Colors.black45,
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              Text(
                '学习、查询与校园工具',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          actions: [],
        ),
        body: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 150,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  int crossAxisCount = 1;
                  if (constraints.maxWidth >= 900) {
                    crossAxisCount = 4;
                  } else if (constraints.maxWidth >= 600) {
                    crossAxisCount = 3;
                  } else if (constraints.maxWidth >= 380) {
                    crossAxisCount = 2;
                  } else {
                    crossAxisCount = 1;
                  }

                  return ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _buildSectionTitle('常用工具', isDark),
                      const SizedBox(height: 12),
                      GridView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          mainAxisExtent: 88,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                        children: [
                          _buildToolCard(
                            context,
                            icon: Icons.school_outlined,
                            color: const Color(0xFF55B97A),
                            title: '二课分查询',
                            subtitle: '支持 WebVPN 穿透',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ErkeScoreScreen(),
                              ),
                            ),
                          ),
                          _buildToolCard(
                            context,
                            icon: Icons.school,
                            color: const Color(0xFF5B8DEF),
                            title: '雨课堂',
                            subtitle: '测验与课件',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const YuketangClassScreen(),
                              ),
                            ),
                          ),
                          _buildToolCard(
                            context,
                            icon: Icons.fitness_center,
                            color: const Color(0xFFE9A23B),
                            title: '体测成绩',
                            subtitle: '扫码核验 / 查询',
                            onTap: () => _openPhysicalTest(context),
                          ),
                          _buildToolCard(
                            context,
                            icon: Icons.event_note,
                            color: const Color(0xFF826FE8),
                            title: '考试日程',
                            subtitle: 'AI一键提取',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ExamScheduleScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _buildSectionTitle('校园与娱乐', isDark),
                      const SizedBox(height: 12),
                      GridView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          mainAxisExtent: 88,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                        children: [
                          _buildToolCard(
                            context,
                            icon: Icons.sports_esports,
                            color: const Color(0xFF35B7C4),
                            title: '云原神',
                            subtitle: '点击即玩',
                            onTap: () => _launchCloudGenshin(context),
                          ),
                          _buildToolCard(
                            context,
                            icon: Icons.card_giftcard,
                            color: const Color(0xFFEE5C8A),
                            title: '抽奖活动',
                            subtitle: '公平福利派送',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const LotteryScreen()),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _buildMoreToolsCard(isDark),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, bool isDark) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        shadows: [
          Shadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
          ),
        ],
      ),
    );
  }

  Widget _buildMoreToolsCard(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isDark 
                  ? Colors.black.withValues(alpha: 0.65)
                  : Colors.white.withValues(alpha: 0.78),
              border: Border.all(
                color: isDark 
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.65),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.auto_stories_outlined, color: Color(0xFF5B8DEF), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '更多工具',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: isDark ? Colors.white : const Color(0xFF20232A),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '更多校园功能正在完善',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: isDark ? Colors.white60 : const Color(0xFF7D8492),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '开发中',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white54 : const Color(0xFF94A3B8),
                  ),
                ),
              ],
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
        _buildBackgroundOverlay(isDark),
      ],
    );
  }

  void _openPhysicalTest(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final username = auth.user?.studentId ?? '';
    if (username.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _PhysicalTestGate(username: username)),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    }
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.isBackgroundVisible &&
        themeProvider.getBackgroundImageFor(context) != null) {
      final bgPath = themeProvider.getBackgroundImageFor(context)!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset(
                  'assets/images/$bgPath',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                )
              : bgPath.startsWith('/')
                  ? Image.file(
                      File(bgPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                    )
                  : Image.network(
                      bgPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                    ),
          _buildBackgroundOverlay(isDark),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/morenbeijing.jpeg',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
          ),
        ),
        _buildBackgroundOverlay(isDark),
      ],
    );
  }

  Widget _buildBackgroundOverlay(bool isDark) {
    if (isDark) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.26),
              Colors.black.withValues(alpha: 0.12),
              Colors.black.withValues(alpha: 0.22),
            ],
          ),
        ),
      );
    } else {
      return Container(
        color: const Color(0x33291B27),
      );
    }
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
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark 
                    ? Colors.black.withValues(alpha: 0.65)
                    : Colors.white.withValues(alpha: 0.78),
                border: Border.all(
                  color: isDark 
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.white.withValues(alpha: 0.65),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: isDark ? Colors.white : const Color(0xFF20232A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: isDark ? Colors.white60 : const Color(0xFF7D8492),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
  bool _obscurePwd = true;
  String _realPwd = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSavedPassword());
  }

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    final pwd = prefs.getString('sylu_physical_test_pwd_${widget.username}');
    if (pwd != null && pwd.isNotEmpty) {
      _realPwd = pwd;
      _pwdCtrl.text = '•' * pwd.length;
      if (mounted) setState(() {});
    }
  }

  void _onPwdChanged(String val) {
    final placeholder = '•' * _realPwd.length;
    if (_realPwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('•', '');
      _realPwd = '';
      _pwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _queryManual() {
    final inputPwd = _pwdCtrl.text;
    final pwd = inputPwd == ('•' * _realPwd.length) ? _realPwd : inputPwd;

    if (pwd.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入体测密码')));
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PhysicalTestPage(username: widget.username, password: pwd),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('体测成绩查询'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Column(
            children: [
              GlassContainer(
                padding: const EdgeInsets.all(16),
                borderRadius: 16,
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      color: Colors.blue,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '学号 ${widget.username} 已自动识别，请输入体测密码查询',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassContainer(
                padding: const EdgeInsets.all(20),
                borderRadius: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.fitness_center,
                          color: Colors.blue,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          '体测密码',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '初始密码默认为111111',
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white38 : Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _pwdCtrl,
                      onChanged: _onPwdChanged,
                      obscureText: _obscurePwd,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '输入体测系统密码',
                        prefixIcon: const Icon(Icons.lock_outline, size: 18),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePwd
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 18,
                          ),
                          onPressed: () =>
                              setState(() => _obscurePwd = !_obscurePwd),
                        ),
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
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _queryManual,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    '开始查询',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
