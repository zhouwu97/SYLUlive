import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../utils/app_feedback.dart';
import '../utils/sylu_client_crawler.dart';

class ErkeScoreScreen extends StatefulWidget {
  const ErkeScoreScreen({super.key});

  @override
  State<ErkeScoreScreen> createState() => _ErkeScoreScreenState();
}

class _ErkeScoreScreenState extends State<ErkeScoreScreen> {
  final _vpnUserCtrl = TextEditingController();
  final _vpnPwdCtrl = TextEditingController();
  final _erkeUserCtrl = TextEditingController();
  final _erkePwdCtrl = TextEditingController();
  
  bool _isLoading = false;
  String _loadingMessage = '';
  List<dynamic>? _scores;

  /// 加载中的趣味文案池
  static const _loadingMessages = [
    '正在穿透学校内网，请稍候…',
    '正在唤醒教务系统…',
    'OCR 识别验证码中…',
    '加密传输中，保障你的密码安全…',
    '正在与深信服 VPN 握手…',
    '数据解密中，马上就好…',
  ];

  @override
  void initState() {
    super.initState();
    // 默认填入学号
    final user = context.read<AuthProvider>().user;
    if (user != null) {
      _vpnUserCtrl.text = user.studentId;
      _erkeUserCtrl.text = user.studentId;
    }
  }

  Future<void> _queryScores() async {
    if (_vpnPwdCtrl.text.isEmpty || _erkePwdCtrl.text.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写完整密码');
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = _loadingMessages.first;
    });

    // 每 1.5 秒轮换一条加载文案
    _startLoadingMessageRotation();

    try {
      // 使用纯本地前端爬虫穿透深信服 WebVPN
      final crawler = SyluClientCrawler();
      
      // 注意：这里的 vpn_password 框暂时用来接收 WebVPN 的 Ticket 
      // (如果你后续有完整的 WebVPN 自动抓包登录流，这里再改)
      final vpnTicket = _vpnPwdCtrl.text.trim();
      final erkeUser = _erkeUserCtrl.text.trim();
      final erkePwd = _erkePwdCtrl.text;
      
      final htmlStr = await crawler.fetchErkeData(erkeUser, erkePwd, vpnTicket);
      final parsedScores = crawler.parseErkeScores(htmlStr);

      if (parsedScores.isNotEmpty) {
        setState(() {
          _scores = parsedScores;
        });
      } else {
        AppFeedback.showSnackBar(
          context,
          '查询成功，但没有解析到成绩数据或账号密码错误',
          isError: true,
        );
      }
    } catch (e) {
      AppFeedback.showSnackBar(
        context,
        '穿透失败: $e',
        isError: true,
      );
    } finally {
      _stopLoadingMessageRotation();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingMessage = '';
        });
      }
    }
  }

  int _messageIndex = 0;
  void _startLoadingMessageRotation() {
    _messageIndex = 0;
    Future.doWhile(() async {
      if (!_isLoading || !mounted) return false;
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!_isLoading || !mounted) return false;
      setState(() {
        _messageIndex = (_messageIndex + 1) % _loadingMessages.length;
        _loadingMessage = _loadingMessages[_messageIndex];
      });
      return _isLoading && mounted;
    });
  }

  void _stopLoadingMessageRotation() {
    _isLoading = false;
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
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.32)
              : Colors.white.withValues(alpha: 0.22),
        ),
      ],
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
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
                : Colors.white.withValues(alpha: 0.25),
          ),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('二课分查询'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground(themeProvider, isDark)),
          if (_scores != null)
            Positioned.fill(
              child: Container(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.45)
                    : Colors.black.withValues(alpha: 0.3),
              ),
            ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                SizedBox(height: kToolbarHeight),
                Expanded(
                  child: _scores == null ? _buildLoginForm(isDark) : _buildScoreList(isDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginForm(bool isDark) {
    final studentId = _vpnUserCtrl.text.isNotEmpty ? _vpnUserCtrl.text : '未获取到学号';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // 当前账号信息卡片
          GlassContainer(
            padding: const EdgeInsets.all(20),
            borderRadius: 20,
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.person, color: Theme.of(context).primaryColor, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('当前账号', style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600])),
                      const SizedBox(height: 2),
                      Text(studentId, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Icon(Icons.check_circle, color: Colors.green.shade400, size: 20),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // WebVPN 密码
          GlassContainer(
            padding: const EdgeInsets.all(24),
            borderRadius: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.security, color: Colors.blue),
                    SizedBox(width: 12),
                    Text('统一认证平台登录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '账号已自动填入学号：$studentId',
                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _vpnPwdCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: '统一认证密码 (目前填 WebVPN Ticket)',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 二课密码
          GlassContainer(
            padding: const EdgeInsets.all(24),
            borderRadius: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.school, color: Colors.green),
                    SizedBox(width: 12),
                    Text('二课平台登录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '学号已自动填入：$studentId',
                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _erkePwdCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: '二课查询密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _queryScores,
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    child: _isLoading 
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            ),
                            SizedBox(width: 12),
                            Text('查询中…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        )
                      : const Text('立即查询', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
                if (_isLoading && _loadingMessage.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: Text(
                      _loadingMessage,
                      key: ValueKey(_loadingMessage),
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white70 : Colors.grey[700],
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '注：系统会自动穿透校内 VPN，外网环境下也能直接查询。',
            style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildScoreList(bool isDark) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Text('查询结果 (${_scores!.length})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(onPressed: () => setState(() => _scores = null), child: const Text('重新查询')),
            ],
          ),
        ),
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
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item['item'] ?? '未知项目', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                            const SizedBox(height: 4),
                            Text(item['date'] ?? '', style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600])),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '+${item['score']}',
                          style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
