import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/webvpn_service.dart';
import '../utils/sylu_client_crawler.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';

class ErkeScoreScreen extends StatefulWidget {
  const ErkeScoreScreen({super.key});

  @override
  State<ErkeScoreScreen> createState() => _ErkeScoreScreenState();
}

class _ErkeScoreScreenState extends State<ErkeScoreScreen> {
  final _casPwdCtrl = TextEditingController();
  final _erkePwdCtrl = TextEditingController();
  final _studentIdCtrl = TextEditingController();

  final WebVpnService _vpn = WebVpnService();

  bool _isLoading = false;
  String _loadingMessage = '';
  List<dynamic>? _scores;
  bool _obscureCas = true;
  bool _obscureErke = true;

  static const _loadingMessages = [
    '正在穿透学校内网，请稍候…',
    '正在通过统一认证…',
    '正在获取 VPN 通行证…',
    '正在进入二课平台…',
    '正在抓取成绩数据…',
    '数据解密中，马上就好…',
  ];

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    if (user != null) {
      _studentIdCtrl.text = user.studentId;
    }
  }

  @override
  void dispose() {
    _casPwdCtrl.dispose();
    _erkePwdCtrl.dispose();
    _studentIdCtrl.dispose();
    _vpn.dispose();
    super.dispose();
  }

  Future<void> _queryScores() async {
    final casPwd = _casPwdCtrl.text;
    final erkePwd = _erkePwdCtrl.text;
    final studentId = _studentIdCtrl.text.trim();

    if (casPwd.isEmpty || erkePwd.isEmpty || studentId.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写完整信息');
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = _loadingMessages.first;
    });
    _startMessageRotation();

    try {
      // 1. CAS 统一认证登录 → 获取 VPN cookie
      _updateMessage('正在通过统一认证…');
      final ok = await _vpn.login(studentId, casPwd);
      if (!ok) {
        AppFeedback.showSnackBar(context, '统一认证登录失败，请检查密码', isError: true);
        return;
      }

      // 2. 拿 VPN cookie 穿透内网抓二课
      //    必须复用 WebVpnService 的 Dio 实例，否则 WebVPN 检测到不同 TLS 连接
      //    会触发 logoutByTAChange 强制注销。
      _updateMessage('正在进入二课平台…');
      final crawler = SyluClientCrawler(cookieJar: _vpn.cookieJar, dio: _vpn.dio);
      final htmlStr = await crawler.login(studentId, erkePwd, _vpn.vpnCookie);
      final parsedScores = crawler.parseErkeScores(htmlStr);

      if (parsedScores.isNotEmpty) {
        setState(() => _scores = parsedScores);
      } else {
        AppFeedback.showSnackBar(context, '查询成功，但未解析到成绩数据或账号密码错误', isError: true);
      }
    } catch (e) {
      AppFeedback.showSnackBar(context, '查询失败: $e', isError: true);
    } finally {
      _stopMessageRotation();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _updateMessage(String msg) {
    if (mounted) setState(() => _loadingMessage = msg);
  }

  int _msgIdx = 0;
  void _startMessageRotation() {
    _msgIdx = 0;
    Future.doWhile(() async {
      if (!_isLoading || !mounted) return false;
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!_isLoading || !mounted) return false;
      _msgIdx = (_msgIdx + 1) % _loadingMessages.length;
      if (mounted) setState(() => _loadingMessage = _loadingMessages[_msgIdx]);
      return _isLoading && mounted;
    });
  }

  void _stopMessageRotation() {
    _isLoading = false;
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/images/morenbeijing.jpeg', fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB))),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.32)
                : Colors.white.withValues(alpha: 0.22)),
      ],
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath', fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
            : bgPath.startsWith('/')
                ? Image.file(File(bgPath), fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
                : Image.network(bgPath, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBg(isDark)),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.25)),
      ]);
    }
    return _buildDefaultBg(isDark);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Stack(
      children: [
        Positioned.fill(child: _buildBackground(themeProvider, isDark)),
        Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            title: const Text('二课分查询'),
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: SafeArea(
            child: _scores == null
                ? _buildLoginForm(isDark)
                : _buildScoreList(isDark),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginForm(bool isDark) {
    final studentId =
        _studentIdCtrl.text.isNotEmpty ? _studentIdCtrl.text : '未获取到学号';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        const SizedBox(height: 12),
        // 当前账号
        GlassContainer(
          padding: const EdgeInsets.all(20),
          borderRadius: 20,
          child: Row(children: [
            Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                    color:
                        Theme.of(context).primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.person,
                    color: Theme.of(context).primaryColor, size: 24)),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('当前账号',
                      style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.grey[600])),
                  Text(studentId,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ])),
            Icon(Icons.check_circle, color: Colors.green.shade400, size: 20),
          ]),
        ),
        const SizedBox(height: 20),
        // CAS 统一认证密码
        GlassContainer(
          padding: const EdgeInsets.all(24),
          borderRadius: 24,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.security, color: Colors.blue),
                  SizedBox(width: 12),
                  Text('统一认证登录',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 4),
                Text('账号已自动填入：$studentId\n自动穿透网瑞达 WebVPN',
                    style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white54 : Colors.grey[600])),
                const SizedBox(height: 16),
                TextField(
                  controller: _casPwdCtrl,
                  obscureText: _obscureCas,
                  decoration: InputDecoration(
                    labelText: '统一认证密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureCas
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscureCas = !_obscureCas),
                    ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.white,
                  ),
                ),
              ]),
        ),
        const SizedBox(height: 16),
        // 二课平台密码
        GlassContainer(
          padding: const EdgeInsets.all(24),
          borderRadius: 24,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.school, color: Colors.green),
                  SizedBox(width: 12),
                  Text('二课平台登录',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 4),
                Text('学号已自动填入：$studentId',
                    style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white54 : Colors.grey[600])),
                const SizedBox(height: 16),
                TextField(
                  controller: _erkePwdCtrl,
                  obscureText: _obscureErke,
                  decoration: InputDecoration(
                    labelText: '二课查询密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureErke
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscureErke = !_obscureErke),
                    ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.white,
                  ),
                ),
              ]),
        ),
        const SizedBox(height: 32),
        SizedBox(
            width: double.infinity,
            child: Column(children: [
              SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _queryScores,
                    style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white),
                    child: _isLoading
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                                SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.5)),
                                SizedBox(width: 12),
                                Text('查询中…',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                              ])
                        : const Text('立即查询',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                  )),
              if (_isLoading && _loadingMessage.isNotEmpty) ...[
                const SizedBox(height: 16),
                AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: Text(_loadingMessage,
                        key: ValueKey(_loadingMessage),
                        style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white70 : Colors.grey[700],
                            fontStyle: FontStyle.italic),
                        textAlign: TextAlign.center)),
              ],
            ])),
        const SizedBox(height: 20),
        Text(
          '注：自动穿透网瑞达 WebVPN + CAS 统一认证，外网直接查询',
          style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : Colors.grey[600]),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _buildScoreList(bool isDark) {
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Text('查询结果 (${_scores!.length})',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton(
                onPressed: () => setState(() => _scores = null),
                child: const Text('重新查询')),
          ])),
      Expanded(
          child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _scores!.length,
              itemBuilder: (context, index) {
                final item = _scores![index];
                return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: GlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
                        child: Row(children: [
                          Expanded(
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                Text(item['item'] ?? '未知项目',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15)),
                                const SizedBox(height: 4),
                                Text(item['date'] ?? '',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.grey[600])),
                              ])),
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                  color: Colors.green
                                      .withValues(alpha: 0.15),
                                  borderRadius:
                                      BorderRadius.circular(20)),
                              child: Text('+${item['score']}',
                                  style: const TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16))),
                        ])));
              })),
    ]);
  }
}
