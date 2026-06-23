import 'dart:convert';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/sign_utils.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';

class PhysicalTestPage extends StatefulWidget {
  final String username;
  final String password;

  const PhysicalTestPage({
    super.key,
    required this.username,
    required this.password,
  });

  @override
  State<PhysicalTestPage> createState() => _PhysicalTestPageState();
}

class _PhysicalTestPageState extends State<PhysicalTestPage> {
  static const String _baseUrl = 'http://47.92.231.221';
  static const String _cachePrefix = 'gym_cache_';

  static const _headers = {
    'X-Requested-With': 'com.wisedu.cpdaily',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.43 Mobile Safari/537.36',
    'Content-Type': 'application/json;charset=UTF-8',
  };

  late final Dio _dio;

  bool _loggingIn = true;
  bool _loadingYear = false;
  String? _errorMessage;
  String? _userId;
  String? _token;
  String _currentYear = '';
  late final List<String> _availableYears;

  // year → {total_grade, total_score, scores[]}
  final Map<String, _YearData> _yearData = {};

  bool _showQr = false;
  String _testCode = ''; 
  int _displayMode = 0; // 0: 成绩, 1: 得分, 2: 评级

  @override
  void initState() {
    super.initState();
    // 动态生成可用年份列表：当年份优先，递减
    final now = DateTime.now();
    final currentYear = now.month >= 9 ? now.year + 1 : now.year;
    _availableYears = List.generate(4, (i) => (currentYear - i).toString());

    _dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        headers: _headers,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    _dio.interceptors.add(CookieManager(CookieJar()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  String _md5(String input) => md5.convert(utf8.encode(input)).toString();

  Future<void> _init() async {
    final ok = await _login();
    if (!ok) {
      if (mounted) setState(() => _loggingIn = false);
      return;
    }
    if (mounted) setState(() => _loggingIn = false);

    // 获取学生信息（含 testCode 二维码内容）
    await _fetchStudentInfo();

    // 尝试从本地缓存加载已有的年份数据
    await _loadCached();
    // 自动选中最新有数据的年份：优先当前学年，无数据则取最近有缓存的
    final now = DateTime.now();
    final academicYear = now.month >= 9 ? now.year + 1 : now.year;
    final currentYearStr = academicYear.toString();
    // 服务端的 school_date 可能返回旧年份，不要直接信任
    if (mounted)
      setState(() {
        _currentYear = _yearData[currentYearStr] != null
            ? currentYearStr // 当前学年有数据，优先用
            : _availableYears.firstWhere(
                (y) => _yearData[y] != null,
                orElse: () => currentYearStr, // 都没数据，用当前学年
              );
      });

    // 如果选中年份没有缓存，自动拉取；优先拉取当前年份
    if (_yearData[_currentYear] == null) {
      _fetchYear(_currentYear);
    } else {
      // 当前年有缓存，后台静默拉取最新数据
      _fetchYear(_currentYear);
    }
  }

  Future<void> _loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    for (final year in _availableYears) {
      final raw = prefs.getString('$_cachePrefix${widget.username}_$year');
      if (raw != null) {
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          _yearData[year] = _YearData(
            totalGrade: map['total_grade'] ?? '',
            totalScore: (map['total_score'] ?? 0).toDouble(),
            scores:
                (map['scores'] as List?)
                    ?.map(
                      (e) => _GymScoreItem.fromJson(e as Map<String, dynamic>),
                    )
                    .toList() ??
                [],
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _saveCache(String year, _YearData data) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode({
      'total_grade': data.totalGrade,
      'total_score': data.totalScore,
      'scores': data.scores.map((s) {
        return {
          'sub_name': s.subName,
          'result': s.result,
          'grade': s.grade,
          'score': s.score,
        };
      }).toList(),
    });
    await prefs.setString('$_cachePrefix${widget.username}_$year', json);
  }

  Future<bool> _login() async {
    final md5Password = _md5(widget.password);
    final requestData = <String, dynamic>{
      'username': widget.username,
      'password': md5Password,
      'sys_id': 'iscpMobile',
      'nonceStr': '',
      'captchaValue': '',
    };
    requestData['sign'] = SignUtils.generateSign(requestData);

    debugPrint('--- [体测登录] 请求开始 ---');
    debugPrint('URL: $_baseUrl/service/login/mobile/check');
    debugPrint('Payload: $requestData');

    try {
      final resp = await _dio.post(
        '/service/login/mobile/check',
        data: requestData,
      );
      debugPrint('Status Code: ${resp.statusCode}');
      debugPrint('Response Headers: ${resp.headers}');
      debugPrint('Response Body: ${resp.data}');

      if (resp.statusCode == 200) {
        var data = resp.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } catch (_) {}
        }
        if (data is Map) {
          String? uid;
          for (final key in ['user_id', 'userId', 'id']) {
            if (data[key] != null) uid = data[key].toString();
          }
          if (uid == null && data['data'] is Map) {
            for (final key in ['user_id', 'userId', 'id']) {
              if (data['data'][key] != null) {
                uid = data['data'][key].toString();
              }
            }
          }
          if (uid == null) {
            final cookies = resp.headers['set-cookie'];
            if (cookies != null) {
              for (final c in cookies) {
                final m = RegExp(r'userid=([^;]+)').firstMatch(c);
                if (m != null) uid = m.group(1);
              }
            }
          }
          if (uid != null) {
            _userId = uid;
            _token = data['token']?.toString();
            if (data['school_date'] != null) {
              _currentYear = data['school_date'].toString();
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(
              'sylu_physical_test_pwd_${widget.username}',
              widget.password,
            );
            debugPrint(
              '登录成功！UserId: $_userId, Token: $_token, Year: $_currentYear',
            );
            return true;
          } else {
            debugPrint('登录返回了数据，但未能解析到 userId');
          }
        } else {
          debugPrint('登录返回的数据不是 Map 类型');
        }
      }
    } catch (e, st) {
      debugPrint('登录发生异常: $e');
      debugPrint('$st');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('sylu_physical_test_pwd_${widget.username}');
    } catch (_) {}
    if (mounted) {
      setState(() => _errorMessage = '登录失败，请检查学号或体测密码');
    }
    return false;
  }

  /// 获取学生信息（含 testCode 作为二维码内容）
  Future<void> _fetchStudentInfo() async {
    if (_userId == null) return;
    final bodyData = <String, dynamic>{'userId': _userId};
    bodyData['sign'] = SignUtils.generateSign(bodyData);
    try {
      final resp = await _dio.post(
        '/service/sysUser/mobile/findStudent',
        data: bodyData,
        options: Options(
          headers: {
            'Authorization': _token ?? _userId!,
            'Cookie': 'userid=$_userId',
          },
        ),
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final data = resp.data['data'];
        if (data is Map && data['testCode'] != null) {
          _testCode = data['testCode'].toString();
          debugPrint('获取到 testCode: $_testCode');
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchYear(String year) async {
    if (_userId == null) {
      debugPrint('获取成绩失败: _userId 为空！');
      return;
    }
    if (mounted) setState(() => _loadingYear = true);

    // _token 登录返回已是 "userId:hash" 格式，直接用
    final authValue = _token ?? _userId!;
    final bodyData = <String, dynamic>{'user_id': _userId, 'school_year': year};
    bodyData['sign'] = SignUtils.generateSign(bodyData);

    debugPrint('--- [体测成绩查询] 请求开始 ---');
    debugPrint('URL: $_baseUrl/service/mobile/gymResult/selectUserPlanScore');
    debugPrint('Headers Authorization: $authValue');
    debugPrint('Payload: $bodyData');

    try {
      final resp = await _dio.post(
        '/service/mobile/gymResult/selectUserPlanScore',
        data: bodyData,
        options: Options(
          headers: {'Authorization': authValue, 'Cookie': 'userid=$_userId'},
        ),
      );
      debugPrint('Status Code: ${resp.statusCode}');
      debugPrint('Response Body: ${resp.data}');

      if (resp.statusCode == 200) {
        var data = resp.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } catch (_) {}
        }
        if (data is Map && data['data'] is Map) {
          final inner = data['data'] as Map;
          final totalGrade = inner['total_grade']?.toString() ?? '';
          final totalScore = (inner['total_score'] ?? 0).toDouble();
          final list = inner['data_arr'];
          final scores = (list is List)
              ? list
                    .map(
                      (e) => _GymScoreItem.fromJson(e as Map<String, dynamic>),
                    )
                    .toList()
              : <_GymScoreItem>[];

          debugPrint('成功解析到成绩数据，长度: ${scores.length}');

          final yearData = _YearData(
            totalGrade: totalGrade,
            totalScore: totalScore,
            scores: scores,
          );
          _yearData[year] = yearData;
          await _saveCache(year, yearData);
          if (mounted) {
            AppFeedback.showSnackBar(context, '成绩已更新');
          }
        } else {
          debugPrint('成绩查询返回的不是预期的 Map 或 data 字段不是 Map');
        }
      }
    } catch (e, st) {
      debugPrint('获取成绩失败，发生异常: $e');
      debugPrint('$st');
    }
    if (mounted) setState(() => _loadingYear = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF131720)
          : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('体测成绩查询'),
        backgroundColor: isDark
            ? const Color(0xFF131720)
            : const Color(0xFFF4F6FB),
        elevation: 0,
        actions: [
          IconButton(
            icon: _loadingYear
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _loadingYear ? null : () => _fetchYear(_currentYear),
            tooltip: '刷新当前学年',
          ),
        ],
      ),
      body: _loggingIn ? _buildLoading() : _buildContent(isDark),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在登录…'),
        ],
      ),
    );
  }

  Widget _buildContent(bool isDark) {
    if (_errorMessage != null) return _buildError(isDark);

    final data = _yearData[_currentYear];
    final scores = data?.scores ?? [];

    return Column(
      children: [
        _buildYearSelector(isDark),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                _buildQrSection(isDark),
                const SizedBox(height: 16),
                if (data != null) ...[
                  _buildSummaryCard(data, isDark),
                  const SizedBox(height: 16),
                ],
                if (scores.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 12, top: 8),
                    child: Row(
                      children: [
                        const Text(
                          '成绩明细',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        _buildDisplayModeSelector(isDark),
                      ],
                    ),
                  ),
                  _buildScoreListCard(scores, isDark, _displayMode),
                ] else if (data != null)
                  Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text(
                      '暂无成绩数据',
                      style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.grey[600],
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text(
                      '选择学年查看成绩',
                      style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.grey[600],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildYearSelector(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
      child: Row(
        children: [
          const Text('学年', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const Spacer(),
          GestureDetector(
            onTap: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: isDark ? Colors.grey[900] : Colors.white,
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
                          child: Text('选择学年', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                        ..._availableYears.map((y) => ListTile(
                          title: Text('$y—${int.parse(y) + 1}', textAlign: TextAlign.center),
                          trailing: _currentYear == y ? const Icon(Icons.check, color: Color(0xFF6366F1)) : const SizedBox(width: 24),
                          onTap: () {
                            Navigator.pop(context);
                            if (mounted) setState(() => _currentYear = y);
                            if (_yearData[y] == null) {
                              _fetchYear(y);
                            }
                          },
                        )),
                      ],
                    ),
                  );
                },
              );
            },
            child: Row(
              children: [
                Text(
                  '${_currentYear.isNotEmpty ? _currentYear : "..."}—${_currentYear.isNotEmpty ? int.parse(_currentYear) + 1 : "..."}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down, size: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showPhysicalQrDialog(BuildContext context, bool isDark) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) {
        final screenWidth = MediaQuery.sizeOf(dialogContext).width;
        final dialogWidth = (screenWidth * 0.84).clamp(300.0, 360.0);
        final qrSize = (dialogWidth - 72).clamp(220.0, 260.0);

        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Container(
            width: dialogWidth,
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey[900] : Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 36),
                    Expanded(
                      child: Text(
                        '体测身份码',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: Icon(Icons.close_rounded, size: 21, color: isDark ? Colors.white70 : Colors.black54),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                Container(
                  width: qrSize,
                  height: qrSize,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _testCode.isNotEmpty ? _testCode : widget.username,
                    version: QrVersions.auto,
                    size: qrSize,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF6366F1),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ),

                const SizedBox(height: 18),
                Text(
                  '扫码进行体测身份核验',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '学号：${widget.username}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildQrSection(bool isDark) {
    return GestureDetector(
      onTap: () => _showPhysicalQrDialog(context, isDark),
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        borderRadius: 16,
        child: Row(
          children: [
            const Icon(Icons.qr_code_2, size: 20, color: Color(0xFF6366F1)),
            const SizedBox(width: 10),
            const Text(
              '体测身份码',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '查看',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: isDark ? Colors.white54 : Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(_YearData data, bool isDark) {
    Color gradeColor;
    Color gradeBg;
    if (data.totalGrade == '优秀' || data.totalGrade == '良好' || data.totalGrade == '正常') {
      gradeColor = const Color(0xFF32A866);
      gradeBg = const Color(0xFFE8F7EF);
    } else if (data.totalGrade == '及格') {
      gradeColor = const Color(0xFF5B6EE1);
      gradeBg = const Color(0xFFEEF0FF);
    } else if (data.totalGrade == '不及格') {
      gradeColor = const Color(0xFFE45757);
      gradeBg = const Color(0xFFFDECEC);
    } else {
      gradeColor = const Color(0xFF8A8F9C);
      gradeBg = isDark ? Colors.white10 : const Color(0xFFF6F7FB);
    }

    return GlassContainer(
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '体测总评',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (data.totalGrade.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: gradeBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    data.totalGrade,
                    style: TextStyle(
                      color: gradeColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${data.totalScore} 分',
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '当前采用：${_currentYear.isNotEmpty ? _currentYear : ""}年体测标准',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.grey[600],
                ),
              ),
              const Spacer(),
              const Text(
                '评分标准',
                style: TextStyle(
                  color: Color(0xFF5B6EE1),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDisplayModeSelector(bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '得分',
          style: TextStyle(
            fontSize: 13,
            fontWeight: _displayMode == 0 ? FontWeight.w600 : FontWeight.w500,
            color: _displayMode == 0 
                ? (isDark ? Colors.white : const Color(0xFF1A1A2E))
                : (isDark ? Colors.white54 : const Color(0xFF8A8F9C)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 22,
          child: FittedBox(
            fit: BoxFit.contain,
            child: Switch(
              value: _displayMode == 1,
              onChanged: (val) => setState(() => _displayMode = val ? 1 : 0),
              activeColor: Colors.white,
              activeTrackColor: const Color(0xFF5B6EE1),
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: isDark ? Colors.white24 : const Color(0xFFD1D5DB),
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '评级',
          style: TextStyle(
            fontSize: 13,
            fontWeight: _displayMode == 1 ? FontWeight.w600 : FontWeight.w500,
            color: _displayMode == 1 
                ? (isDark ? Colors.white : const Color(0xFF1A1A2E))
                : (isDark ? Colors.white54 : const Color(0xFF8A8F9C)),
          ),
        ),
      ],
    );
  }

  Widget _buildScoreListCard(List<_GymScoreItem> scores, bool isDark, int displayMode) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: scores.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          
          Color gradeColor;
          Color gradeBg;
          if (item.grade == '优秀' || item.grade == '良好' || item.grade == '正常') {
            gradeColor = const Color(0xFF32A866);
            gradeBg = const Color(0xFFE8F7EF);
          } else if (item.grade == '及格') {
            gradeColor = const Color(0xFF5B6EE1);
            gradeBg = const Color(0xFFEEF0FF);
          } else if (item.grade == '不及格') {
            gradeColor = const Color(0xFFE45757);
            gradeBg = const Color(0xFFFDECEC);
          } else {
            gradeColor = const Color(0xFF8A8F9C);
            gradeBg = isDark ? Colors.white10 : const Color(0xFFF6F7FB);
          }

          Widget rightWidget;
          if (displayMode == 0) {
            rightWidget = Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: gradeBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${item.score}分',
                style: TextStyle(
                  color: gradeColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            );
          } else {
            rightWidget = Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: gradeBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                item.statusLabel,
                style: TextStyle(
                  color: gradeColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            );
          }

          final w = item.standardWeight;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            item.subName,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white : const Color(0xFF20232A),
                            ),
                          ),
                          if (w.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text(
                              '· $w%',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? Colors.white54 : const Color(0xFF8E94A3),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Text(
                      item.result,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(width: 18),
                    SizedBox(
                      width: 64,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: rightWidget,
                      ),
                    ),
                  ],
                ),
              ),
              if (index < scores.length - 1)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark ? Colors.white12 : const Color(0xFFEEF0F4),
                  indent: 16,
                  endIndent: 16,
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildError(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: isDark ? Colors.white38 : Colors.grey[500],
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _init,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _YearData {
  final List<_GymScoreItem> scores;
  final String totalGrade;
  final double totalScore;

  const _YearData({
    this.scores = const [],
    this.totalGrade = '',
    this.totalScore = 0,
  });
}

class _GymScoreItem {
  final String subName;
  final String result;
  final String grade;
  final int score;
  final String weight;

  const _GymScoreItem({
    required this.subName,
    required this.result,
    required this.grade,
    this.score = 0,
    this.weight = '',
  });

  String get standardWeight {
    if (weight.isNotEmpty) return weight;
    if (subName.contains('BMI') || subName.contains('体重指数')) return '15';
    if (subName.contains('肺活量')) return '15';
    if (subName.contains('50')) return '20';
    if (subName.contains('前屈')) return '10';
    if (subName.contains('跳远')) return '10';
    if (subName.contains('引体') || subName.contains('仰卧')) return '10';
    if (subName.contains('1000') || subName.contains('800')) return '20';
    return '';
  }

  factory _GymScoreItem.fromJson(Map<String, dynamic> json) {
    String name = (json['sub_name'] ?? '').toString();
    if (name == '1000') name = '1000 米跑';
    if (name == '800') name = '800 米跑';
    if (name.contains('50米跑')) name = name.replaceAll('50米跑', '50 米跑');

    String rawResult = '${json['result'] ?? ''} ${json['unit'] ?? ''}'.trim();
    rawResult = rawResult.replaceAll('ml', 'mL');
    rawResult = rawResult.replaceAll('times', '次');
    rawResult = rawResult.replaceAll(' min', ' 分钟'); 
    
    rawResult = rawResult.replaceAll(RegExp(r"m's['" + '"' + r"]*"), "");
    if (rawResult.contains("'") || rawResult.contains('"')) {
      rawResult = rawResult.replaceAll("''", "″").replaceAll("'", "′").replaceAll("\"", "″");
    }
    rawResult = rawResult.trim();

    String w = (json['weight'] ?? json['percent'] ?? '').toString();
    w = w.replaceAll('%', '');

    return _GymScoreItem(
      subName: name,
      result: rawResult,
      grade: (json['grade'] ?? '').toString(),
      score: int.tryParse(json['score']?.toString() ?? '') ?? 0,
      weight: w,
    );
  }

  String get statusLabel => grade.isNotEmpty ? grade : '--';
}
