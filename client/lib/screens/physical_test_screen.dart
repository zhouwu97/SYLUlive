import 'dart:convert';
import 'dart:io' show File;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';

/// 体测查询 — 直连目标服务器，两步鉴权
///
/// 步骤 1: POST /service/login/check → 获取 token
/// 步骤 2: POST /service/mobile/gymResult/selectGymSubjectScoreList → 获取成绩

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

  static const _headers = {
    'X-Requested-With': 'com.wisedu.cpdaily',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.43 Mobile Safari/537.36',
    'Content-Type': 'application/json',
  };

  late final Dio _dio;

  bool _isLoading = true;
  String? _errorMessage;
  List<_GymScoreItem> _scores = [];

  @override
  void initState() {
    super.initState();
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      headers: _headers,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchScores());
  }

  // ── MD5 ──
  String _md5(String input) {
    return md5.convert(utf8.encode(input)).toString();
  }

  // ── 步骤 1：登录获取 token ──
  Future<String?> _login() async {
    final resp = await _dio.post('/service/login/check', data: {
      'username': widget.username,
      'password': _md5(widget.password),
      'sys_id': 'iscpMobile',
      'nonceStr': '',
      'captchaValue': '',
      'sign': '',
    });

    if (resp.statusCode == 200) {
      final data = resp.data;
      if (data is Map) {
        // token 可能在 data['userId'] 或 data['data']['userId']
        if (data['userId'] != null) return data['userId'].toString();
        if (data['data'] is Map && data['data']['userId'] != null) {
          return data['data']['userId'].toString();
        }
        // 兜底：从 Cookie 中提取 userid
        final cookies = resp.headers['set-cookie'];
        if (cookies != null) {
          for (final c in cookies) {
            final match = RegExp(r'userid=([^;]+)').firstMatch(c);
            if (match != null) return match.group(1);
          }
        }
      }
    }
    return null;
  }

  // ── 步骤 2：获取成绩 ──
  Future<List<_GymScoreItem>> _getScores(String token) async {
    final resp = await _dio.post(
      '/service/mobile/gymResult/selectGymSubjectScoreList',
      options: Options(headers: {
        'Authorization': token,
        'Cookie': 'userid=$token',
      }),
    );

    if (resp.statusCode == 200) {
      final data = resp.data;
      if (data is Map && data['data'] != null) {
        final list = data['data'];
        if (list is List) {
          return list
              .map((e) => _GymScoreItem.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
    }
    return [];
  }

  Future<void> _fetchScores() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final token = await _login();
      if (token == null) {
        if (mounted) {
          setState(() {
            _errorMessage = '登录失败，请检查学号或体测密码是否正确';
            _isLoading = false;
          });
        }
        return;
      }

      final scores = await _getScores(token);
      if (mounted) {
        setState(() {
          _scores = scores;
          _isLoading = false;
        });
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout) {
          _errorMessage = '请求超时，请检查网络后重试';
        } else if (e.type == DioExceptionType.connectionError) {
          _errorMessage = '无法连接到体测服务器，请检查网络';
        } else if (e.response?.statusCode == 404) {
          _errorMessage = '接口不存在 (404)，请联系管理员';
        } else {
          _errorMessage = '请求失败：${e.message}';
        }
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '未知错误：$e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('体测成绩查询'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground(themeProvider, isDark)),
          SafeArea(
            child: _isLoading ? _buildLoading(isDark) : _buildContent(isDark),
          ),
        ],
      ),
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

  Widget _buildDefaultBg(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/images/morenbeijing.jpeg', fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
          ),
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  Widget _buildLoading(bool isDark) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在获取体测数据…'),
        ],
      ),
    );
  }

  Widget _buildContent(bool isDark) {
    if (_errorMessage != null) {
      return _buildError(isDark);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildQrCard(isDark),
          const SizedBox(height: 20),
          _buildScoreList(isDark),
        ],
      ),
    );
  }

  // ── 二维码卡片 ──
  Widget _buildQrCard(bool isDark) {
    return GlassContainer(
      padding: const EdgeInsets.all(24),
      borderRadius: 20,
      child: Column(
        children: [
          const Icon(Icons.qr_code_2, size: 20, color: Color(0xFF6366F1)),
          const SizedBox(height: 12),
          const Text(
            '体测身份码',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: widget.username,
              version: QrVersions.auto,
              size: 180,
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
          const SizedBox(height: 12),
          Text(
            '扫码进行体测身份核验',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white54 : Colors.grey[600],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '学号：${widget.username}',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  // ── 成绩列表 ──
  Widget _buildScoreList(bool isDark) {
    if (_scores.isEmpty) {
      return GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        child: Center(
          child: Text(
            '暂无体测成绩',
            style: TextStyle(
              fontSize: 15,
              color: isDark ? Colors.white54 : Colors.grey[600],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            '体测成绩 (${_scores.length}项)',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _scores.length,
          itemBuilder: (context, index) {
            final item = _scores[index];
            return _buildScoreCard(item, isDark);
          },
        ),
        const SizedBox(height: 16),
        GlassContainer(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          borderRadius: 16,
          child: const Row(
            children: [
              Icon(Icons.summarize, color: Color(0xFF6366F1)),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  '以上数据仅供参考，最终以体测中心为准',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScoreCard(_GymScoreItem item, bool isDark) {
    final statusColor = Color(item.statusColorValue);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassContainer(
        padding: const EdgeInsets.all(16),
        borderRadius: 16,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.subName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.result,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                item.statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
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
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: isDark ? Colors.white38 : Colors.grey[500]),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : Colors.grey[700],
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _fetchScores,
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
      ),
    );
  }
}

// ── 体测成绩单项模型（内联，匹配直连 API 返回格式） ──

class _GymScoreItem {
  final String subName;
  final String result;
  final String scoreStatus;

  const _GymScoreItem({
    required this.subName,
    required this.result,
    required this.scoreStatus,
  });

  factory _GymScoreItem.fromJson(Map<String, dynamic> json) {
    return _GymScoreItem(
      subName: (json['sub_name'] ?? json['item_name'] ?? json['name'] ?? '').toString(),
      result: (json['result'] ?? json['score'] ?? json['value'] ?? '').toString(),
      scoreStatus: (json['score_status'] ?? json['status'] ?? '').toString(),
    );
  }

  String get statusLabel {
    switch (scoreStatus) {
      case '1':
        return '优秀';
      case '2':
        return '及格';
      case '3':
        return '不及格';
      default:
        return scoreStatus.isNotEmpty ? scoreStatus : '--';
    }
  }

  int get statusColorValue {
    switch (scoreStatus) {
      case '1':
        return 0xFF16A34A;
      case '2':
        return 0xFF6366F1;
      case '3':
        return 0xFFEF4444;
      default:
        return 0xFF9CA3AF;
    }
  }
}
