import 'dart:convert';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/sign_utils.dart';
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
  final List<String> _availableYears = ['2026', '2025', '2024'];

  // year → {total_grade, total_score, scores[]}
  final Map<String, _YearData> _yearData = {};

  bool _showQr = false;
  String _testCode = ''; // 扫码核验码 (id=xxx&name=xxx)

  @override
  void initState() {
    super.initState();
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      headers: _headers,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
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
    // 自动选中最新可用年份
    if (_currentYear.isEmpty && _availableYears.isNotEmpty) {
      _currentYear = _availableYears.first;
    }
    if (mounted) setState(() {});

    // 如果当前年份没有缓存，自动拉取
    if (_yearData[_currentYear] == null) {
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
            scores: (map['scores'] as List?)
                    ?.map((e) =>
                        _GymScoreItem.fromJson(e as Map<String, dynamic>))
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
      final resp =
          await _dio.post('/service/login/mobile/check', data: requestData);
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
            await prefs.setString('sylu_physical_test_pwd_${widget.username}', widget.password);
            debugPrint('登录成功！UserId: $_userId, Token: $_token, Year: $_currentYear');
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
        options: Options(headers: {
          'Authorization': _token ?? _userId!,
          'Cookie': 'userid=$_userId',
        }),
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
    setState(() => _loadingYear = true);

    // _token 登录返回已是 "userId:hash" 格式，直接用
    final authValue = _token ?? _userId!;
    final bodyData = <String, dynamic>{
      'user_id': _userId,
      'school_year': year,
    };
    bodyData['sign'] = SignUtils.generateSign(bodyData);

    debugPrint('--- [体测成绩查询] 请求开始 ---');
    debugPrint('URL: $_baseUrl/service/mobile/gymResult/selectUserPlanScore');
    debugPrint('Headers Authorization: $authValue');
    debugPrint('Payload: $bodyData');

    try {
      final resp = await _dio.post(
        '/service/mobile/gymResult/selectUserPlanScore',
        data: bodyData,
        options: Options(headers: {
          'Authorization': authValue,
          'Cookie': 'userid=$_userId',
        }),
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
                  .map((e) =>
                      _GymScoreItem.fromJson(e as Map<String, dynamic>))
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
      backgroundColor:
          isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('体测成绩查询'),
        backgroundColor: Colors.transparent,
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
            onPressed:
                _loadingYear ? null : () => _fetchYear(_currentYear),
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
        if (_loadingYear)
          const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(),
          )
        else
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
                  if (scores.isNotEmpty)
                    ...scores.map((s) => _buildScoreCard(s, isDark))
                  else if (data != null)
                    Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text('暂无成绩数据',
                          style: TextStyle(
                              color:
                                  isDark ? Colors.white54 : Colors.grey[600])),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text('选择学年查看成绩',
                          style: TextStyle(
                              color:
                                  isDark ? Colors.white54 : Colors.grey[600])),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Text('学年：', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _availableYears.map(
                  (y) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('$y - ${int.parse(y) + 1}'),
                      selected: _currentYear == y,
                      selectedColor: const Color(0xFF6366F1),
                      labelStyle: TextStyle(
                        color: _currentYear == y ? Colors.white : null,
                        fontWeight: FontWeight.w600,
                      ),
                      onSelected: (_) {
                        setState(() => _currentYear = y);
                        if (_yearData[y] == null) {
                          _fetchYear(y);
                        }
                      },
                    ),
                  ),
                ).toList(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed:
                _loadingYear ? null : () => _fetchYear(_currentYear),
            tooltip: '刷新数据',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildQrSection(bool isDark) {
    return GestureDetector(
      onTap: () => setState(() => _showQr = !_showQr),
      child: GlassContainer(
        padding: EdgeInsets.all(_showQr ? 20 : 14),
        borderRadius: 16,
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2,
                    size: 20, color: Color(0xFF6366F1)),
                const SizedBox(width: 10),
                const Text('体测身份码',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Icon(_showQr ? Icons.expand_less : Icons.expand_more,
                    color: isDark ? Colors.white54 : Colors.grey[600]),
              ],
            ),
            if (_showQr) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
            child: QrImageView(
              data: _testCode.isNotEmpty ? _testCode : widget.username,
                  version: QrVersions.auto,
                  size: 160,
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
              const SizedBox(height: 10),
              Text('扫码进行体测身份核验',
                  style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.grey[600])),
              Text('学号：${widget.username}',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.grey[500])),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(_YearData data, bool isDark) {
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.emoji_events,
                color: Color(0xFF6366F1), size: 22),
          ),
          const SizedBox(width: 14),
          Text(
            '总评：${data.totalGrade}  |  ${data.totalScore}分',
            style:
                const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreCard(_GymScoreItem item, bool isDark) {
    final statusColor = Color(item.statusColorValue);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassContainer(
        padding: const EdgeInsets.all(14),
        borderRadius: 14,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.subName,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(item.result,
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : const Color(0xFF1A1A2E))),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(item.statusLabel,
                  style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ],
        ),
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
            Icon(Icons.error_outline,
                size: 48, color: isDark ? Colors.white38 : Colors.grey[500]),
            const SizedBox(height: 16),
            Text(_errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.grey[700])),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _init,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
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

  const _GymScoreItem({
    required this.subName,
    required this.result,
    required this.grade,
    this.score = 0,
  });

  factory _GymScoreItem.fromJson(Map<String, dynamic> json) {
    return _GymScoreItem(
      subName: (json['sub_name'] ?? '').toString(),
      result: '${json['result'] ?? ''} ${json['unit'] ?? ''}'.trim(),
      grade: (json['grade'] ?? '').toString(),
      score: int.tryParse(json['score']?.toString() ?? '') ?? 0,
    );
  }

  String get statusLabel => grade.isNotEmpty ? grade : '--';

  int get statusColorValue {
    switch (grade) {
      case '优秀':
      case '正常':
        return 0xFF16A34A;
      case '及格':
        return 0xFF6366F1;
      case '不及格':
        return 0xFFEF4444;
      default:
        return 0xFF9CA3AF;
    }
  }
}
