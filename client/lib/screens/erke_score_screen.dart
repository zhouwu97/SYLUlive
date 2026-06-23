import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  List<dynamic>? _summary;
  bool _obscureCas = true;
  bool _obscureErke = true;
  String? _filterCategory;

  String _realCasPwd = '';
  String _realErkePwd = '';

  static const _loadingMessages = [
    '正在穿透学校内网，请稍候…',
    '正在通过统一认证…',
    '正在进入二课平台…',
    '正在抓取成绩数据…',
  ];

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    if (user != null) {
      _studentIdCtrl.text = user.studentId;
    }
    _loadSavedPasswords();
    _loadCache();
  }

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scoresStr = prefs.getString('erke_scores_cache');
      final summaryStr = prefs.getString('erke_summary_cache');
      if (scoresStr != null && summaryStr != null) {
        if (mounted) {
          setState(() {
            _scores = json.decode(scoresStr);
            _summary = json.decode(summaryStr);
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCache(List<dynamic> scores, List<dynamic> summary) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('erke_scores_cache', json.encode(scores));
      await prefs.setString('erke_summary_cache', json.encode(summary));
    } catch (_) {}
  }

  Future<void> _loadSavedPasswords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final casPwd = prefs.getString('erke_cas_pwd') ?? '';
      final erkePwd = prefs.getString('erke_erke_pwd') ?? '';

      _realCasPwd = casPwd;
      _realErkePwd = erkePwd;

      _casPwdCtrl.text = casPwd.isNotEmpty ? '•' * casPwd.length : '';
      _erkePwdCtrl.text = erkePwd.isNotEmpty ? '•' * erkePwd.length : '';

      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _onCasPwdChanged(String val) {
    final placeholder = '•' * _realCasPwd.length;
    if (_realCasPwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('•', '');
      _realCasPwd = '';
      _casPwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _onErkePwdChanged(String val) {
    final placeholder = '•' * _realErkePwd.length;
    if (_realErkePwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('•', '');
      _realErkePwd = '';
      _erkePwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  Future<void> _savePasswords(String casPwd, String erkePwd) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('erke_cas_pwd', casPwd);
    await prefs.setString('erke_erke_pwd', erkePwd);
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
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.showSnackBar(context, '请先在「我的」页面登录后再查询', isError: true);
      return;
    }

    final inputCasPwd = _casPwdCtrl.text;
    final inputErkePwd = _erkePwdCtrl.text;

    final casPwd = inputCasPwd == ('•' * _realCasPwd.length)
        ? _realCasPwd
        : inputCasPwd;
    final erkePwd = inputErkePwd == ('•' * _realErkePwd.length)
        ? _realErkePwd
        : inputErkePwd;
    final studentId = _studentIdCtrl.text.trim();

    if (casPwd.isEmpty || erkePwd.isEmpty || studentId.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写完整信息，或先点击"切换账号/修改密码"输入密码');
      return;
    }

    _savePasswords(casPwd, erkePwd);

    if (mounted)
      setState(() {
        _isLoading = true;
        _loadingMessage = _loadingMessages.first;
      });
    _startMessageRotation();

    try {
      _updateMessage('正在通过统一认证…');
      final ok = await _vpn.login(studentId, casPwd);
      if (!ok) {
        AppFeedback.showSnackBar(context, '统一认证登录失败，请检查密码', isError: true);
        if (mounted) setState(() => _scores = null);
        return;
      }

      _updateMessage('正在进入二课平台…');
      final crawler = SyluClientCrawler(
        cookieJar: _vpn.cookieJar,
        dio: _vpn.dio,
      );
      final htmlStr = await crawler.login(studentId, erkePwd, _vpn.vpnCookie);
      final data = crawler.parseErkeData(htmlStr);

      if (data['scores'].isNotEmpty) {
        if (mounted)
          setState(() {
            _scores = data['scores'];
            _summary = data['summary'];
          });
        _saveCache(data['scores'], data['summary']);
        AppFeedback.showSnackBar(context, '查询并缓存成功');
      } else {
        AppFeedback.showSnackBar(
          context,
          '查询成功，但未解析到成绩数据或二课密码错误',
          isError: true,
        );
        if (mounted) setState(() => _scores = null);
      }
    } catch (e) {
      String errMsg = '未知网络错误或解析异常';
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('timeout')) {
        errMsg = '网络请求超时，请稍后再试';
      } else if (errStr.contains('handshake') ||
          errStr.contains('certificate')) {
        errMsg = '校园网证书异常，连接被拒绝';
      } else if (errStr.contains('socketexception') ||
          errStr.contains('connection')) {
        errMsg = '网络连接失败，请检查您的网络';
      } else if (errStr.contains('500') ||
          errStr.contains('502') ||
          errStr.contains('503') ||
          errStr.contains('504')) {
        errMsg = '学校服务器响应异常';
      }
      AppFeedback.showSnackBar(context, '查询失败: $errMsg', isError: true);
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF131720)
          : const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('二课成绩查询'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_scores != null)
            IconButton(
              icon: _isLoading 
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _isLoading ? null : _queryScores,
            ),
          if (_scores != null)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'logout' || value == 'relogin') {
                  setState(() {
                    _scores = null;
                    _filterCategory = null;
                  });
                } else if (value == 'clear_cache') {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove('erke_scores_cache');
                  await prefs.remove('erke_summary_cache');
                  if (context.mounted) {
                    AppFeedback.showSnackBar(context, '本地缓存已清除');
                  }
                }
              },
              itemBuilder: (BuildContext context) {
                return [
                  const PopupMenuItem<String>(
                    value: 'logout',
                    child: Text('更换账号'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'relogin',
                    child: Text('重新登录'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'clear_cache',
                    child: Text('清除本地缓存'),
                  ),
                ];
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            _scores == null ? _buildLoginForm() : _buildScoreList(isDark),
            if (_isLoading && _scores != null)
              Positioned.fill(
                child: Container(
                  color: Colors.black54,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey[850] : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            _loadingMessage,
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
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
      ),
    );
  }

  Widget _buildLoginForm() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final studentId = _studentIdCtrl.text.isNotEmpty
        ? _studentIdCtrl.text
        : '未登录';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        children: [
          GlassContainer(
            padding: const EdgeInsets.all(16),
            borderRadius: 16,
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '学号 $studentId 已自动识别，请完成双重密码验证',
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
                    const Icon(Icons.security, color: Colors.blue, size: 22),
                    const SizedBox(width: 10),
                    const Text(
                      '1. 统一认证密码',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'VPN 穿透专用',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _casPwdCtrl,
                  onChanged: _onCasPwdChanged,
                  obscureText: _obscureCas,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '输入统一身份认证密码',
                    prefixIcon: const Icon(Icons.lock_outline, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureCas ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                      ),
                      onPressed: () =>
                          setState(() => _obscureCas = !_obscureCas),
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
          const SizedBox(height: 12),
          GlassContainer(
            padding: const EdgeInsets.all(20),
            borderRadius: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.school, color: Colors.green, size: 22),
                    const SizedBox(width: 10),
                    const Text(
                      '2. 二课查询密码',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '系统登录专用',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _erkePwdCtrl,
                  onChanged: _onErkePwdChanged,
                  obscureText: _obscureErke,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '输入二课平台登录密码',
                    prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureErke ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                      ),
                      onPressed: () =>
                          setState(() => _obscureErke = !_obscureErke),
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
              onPressed: _isLoading ? null : _queryScores,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: _isLoading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text(
                          '查询中...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      '开始查询',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          if (_isLoading && _loadingMessage.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _loadingMessage,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 30),
          Text(
            '提示：系统将自动完成 WebVPN 穿透，在校外也可无障碍查询成绩。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreList(bool isDark) {
    // 收集所有类别用于筛选，保持与 summary 顺序一致
    final categoryList = <String>[];
    if (_summary != null) {
      for (final item in _summary!) {
        final cat = item['category']?.toString() ?? '';
        if (cat.isNotEmpty && !categoryList.contains(cat)) {
          categoryList.add(cat);
        }
      }
    }

    // 如果成绩列表中有 summary 未包含的类别，追加到后面
    if (_scores != null) {
      for (final s in _scores!) {
        final cat = s['category']?.toString() ?? '';
        if (cat.isNotEmpty && !categoryList.contains(cat)) {
          categoryList.add(cat);
        }
      }
    }

    // 按筛选过滤
    final filtered =
        _scores?.where((s) {
          if (_filterCategory == null) return true;
          return (s['category'] ?? '') == _filterCategory;
        }).toList() ??
        [];

    return Column(
      children: [
        if (_summary != null && _summary!.isNotEmpty)
          _buildSummaryHeader(isDark),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Text(
                '${_filterCategory ?? '查询结果'} ${filtered.length}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              const Spacer(),
              if (categoryList.isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _showFilterSheet(context, categoryList),
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : const Color(0xFFF0F1F5),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '筛选',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white70 : const Color(0xFF5C6273),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.filter_list, 
                          size: 16, 
                          color: isDark ? Colors.white70 : const Color(0xFF5C6273),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    '该分类暂无数据',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white54 : Colors.grey[600],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    return _buildScoreItem(item, isDark);
                  },
                ),
        ),
      ],
    );
  }

  void _showFilterSheet(BuildContext context, List<String> categories) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('选择分类', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              ListTile(
                title: const Text('全部'),
                trailing: _filterCategory == null ? const Icon(Icons.check, color: Color(0xFF5B6EE1)) : null,
                onTap: () {
                  setState(() => _filterCategory = null);
                  Navigator.pop(context);
                },
              ),
              ...categories.map((c) => ListTile(
                title: Text(c),
                trailing: _filterCategory == c ? const Icon(Icons.check, color: Color(0xFF5B6EE1)) : null,
                onTap: () {
                  setState(() => _filterCategory = c);
                  Navigator.pop(context);
                },
              )),
            ],
          ),
        );
      },
    );
  }

  String _formatDate(String dateStr) {
    if (dateStr.isEmpty) return '';
    String s = dateStr.replaceAll('-', '.').replaceAll('至', '–');
    s = s.replaceAll(' 00:00:00', '');
    s = s.replaceAllMapped(RegExp(r'(\d{2}:\d{2}):00'), (match) => match.group(1)!);

    final sameDayRegex = RegExp(r'^(\d{4}\.\d{2}\.\d{2})(.*?)–\1(.*?)$');
    final sameYearRegex = RegExp(r'^(\d{4})\.(.*?)–\1\.(.*?)$');

    if (sameDayRegex.hasMatch(s)) {
      s = s.replaceFirstMapped(sameDayRegex, (match) => '${match.group(1)}${match.group(2)}–${match.group(3)?.trim()}');
    } else if (sameYearRegex.hasMatch(s)) {
      s = s.replaceFirstMapped(sameYearRegex, (match) => '${match.group(1)}.${match.group(2)}–${match.group(3)}');
    }
    return s;
  }

  Widget _buildSummaryHeader(bool isDark) {
    double totalScore = 0;
    double totalRequired = 0;
    double totalGap = 0;
    for (final item in _summary!) {
      double score = double.tryParse(item['score'] ?? '0') ?? 0;
      double required = double.tryParse(item['required'] ?? '0') ?? 0;
      totalScore += score;
      totalRequired += required;
      if (required > score) {
        totalGap += (required - score);
      }
    }

    final List<Widget> categoryWidgets = [];
    for (int i = 0; i < _summary!.length; i++) {
      final item = _summary![i];
      final score = double.tryParse(item['score'] ?? '0') ?? 0;
      final required = double.tryParse(item['required'] ?? '0') ?? 0;
      final gap = required - score;
      final isFull = gap <= 0;

      categoryWidgets.add(
        Container(
          width: 90,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            children: [
              Text(
                item['category'] ?? '',
                style: const TextStyle(fontSize: 13, color: Color(0xFF8A8F9C)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '${score.toStringAsFixed(score == score.roundToDouble() ? 0 : 1)} / $required',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isFull ? '已完成' : '还差 ${gap.toStringAsFixed(gap == gap.roundToDouble() ? 0 : 1)}',
                style: TextStyle(
                  fontSize: 12,
                  color: isFull ? const Color(0xFF42B36F) : const Color(0xFFF3A640),
                ),
              ),
            ],
          ),
        ),
      );

      if (i < _summary!.length - 1) {
        categoryWidgets.add(
          Container(
            width: 1,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: isDark ? Colors.white12 : const Color(0xFFF0F1F5),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 22),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[850] : Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '总学分',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF20232A)),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${totalScore.toStringAsFixed(totalScore == totalScore.roundToDouble() ? 0 : 1)} / $totalRequired',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF5B6EE1),
                      ),
                    ),
                    if (totalGap > 0) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3A640).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '距离目标还差 ${totalGap.toStringAsFixed(totalGap == totalGap.roundToDouble() ? 0 : 1)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF3A640),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: MediaQuery.of(context).size.width - 64,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: categoryWidgets,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreItem(Map<String, dynamic> item, bool isDark) {
    final formattedDate = _formatDate(item['date'] ?? '');
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[850] : Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 54),
                    child: Text(
                      item['item'] ?? '未知项目',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        height: 1.35,
                        color: isDark ? Colors.white : const Color(0xFF20232A),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (item['category'] != null && item['category'].toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            item['category'],
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF5B6EE1),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          formattedDate,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8A8F9C),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: Text(
                '+${item['score']}',
                style: const TextStyle(
                  color: Color(0xFF42B36F),
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
