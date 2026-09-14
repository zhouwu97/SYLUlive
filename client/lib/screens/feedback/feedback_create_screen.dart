import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/device_diagnostics_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/image_upload_widget.dart';

class FeedbackCreateScreen extends StatefulWidget {
  final String? initialRouteName;

  const FeedbackCreateScreen({super.key, this.initialRouteName});

  @override
  State<FeedbackCreateScreen> createState() => _FeedbackCreateScreenState();
}

class _FeedbackCreateScreenState extends State<FeedbackCreateScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _stepsController = TextEditingController();
  final TextEditingController _actualController = TextEditingController();
  final TextEditingController _expectedController = TextEditingController();

  String _type = 'bug'; // 'bug', 'suggestion', 'other'
  List<UploadedImage> _uploadedImages = [];
  bool _includeDiagnostics = true;
  bool _expandRepro = false;
  bool _isSubmitting = false;

  DeviceDiagnosticsInfo? _diagInfo;

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _stepsController.dispose();
    _actualController.dispose();
    _expectedController.dispose();
    super.dispose();
  }

  Future<void> _loadDiagnostics() async {
    final info = await DeviceDiagnosticsService.collect(
      currentRoute: widget.initialRouteName ?? '客户端反馈',
    );
    if (mounted) {
      setState(() => _diagInfo = info);
    }
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final desc = _descController.text.trim();

    if (title.isEmpty) {
      AppFeedback.showSnackBar(context, '请输入问题标题', isError: true);
      return;
    }
    if (desc.isEmpty) {
      AppFeedback.showSnackBar(context, '请详细描述发生了什么', isError: true);
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final auth = context.read<AuthProvider>();

      final data = <String, dynamic>{
        'type': _type,
        'title': title,
        'description': desc,
        'steps_to_reproduce': _type == 'bug' && _expandRepro
            ? _stepsController.text.trim()
            : null,
        'actual_result': _type == 'bug' && _expandRepro
            ? _actualController.text.trim()
            : null,
        'expected_result': _type == 'bug' && _expandRepro
            ? _expectedController.text.trim()
            : null,
        'image_ids': _uploadedImages.map((e) => e.fileId).toList(),
      };

      if (_includeDiagnostics && _diagInfo != null) {
        data['app_version'] = _diagInfo!.appVersion;
        data['build_number'] = _diagInfo!.buildNumber;
        data['os_version'] =
            '${_diagInfo!.osName} ${_diagInfo!.osVersion}'.trim();
        data['device_model'] = _diagInfo!.deviceModel;
        data['network_type'] = _diagInfo!.networkType;
        data['current_route'] = _diagInfo!.currentRoute;
        data['diagnostics_json'] = _diagInfo!.toJsonString();
      }

      final response = await auth.dio.post('/feedback/tickets', data: data);

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (mounted) {
          AppFeedback.showSnackBar(context, '工单已提交，我们会持续跟进！');
          Navigator.pop(context, true);
        }
      } else {
        if (mounted) {
          AppFeedback.showSnackBar(context, '提交失败，请稍后重试', isError: true);
        }
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '提交失败：$e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showDiagnosticsDialog() {
    if (_diagInfo == null) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1E2226) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '设备与环境诊断数据',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.teal.shade900.withValues(alpha: 0.3)
                      : const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 16, color: Color(0xFF059669)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '隐私安全保证：诊断信息已严格排除 JWT、Cookie、教务密码及聊天内容。',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF059669)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.3)
                          : const Color(0xFFF8FAF9),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                        color:
                            isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                      ),
                    ),
                    child: Text(
                      _diagInfo!.toJsonString(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: const Text('我知道了'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTypeChip(String type, String label, IconData icon) {
    final isSelected = _type == type;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _type = type;
          // 复现信息只属于问题反馈，切换类型后立即收起，避免误填。
          if (type != 'bug') _expandRepro = false;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.brandPrimary.withValues(alpha: isDark ? 0.25 : 0.1)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : const Color(0xFFF8FAF9)),
            border: Border.all(
              color: isSelected
                  ? AppColors.brandPrimary
                  : (isDark ? Colors.white12 : const Color(0xFFE2EFEA)),
              width: isSelected ? 1.6 : 0.8,
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? AppColors.brandPrimary
                    : (isDark ? Colors.white70 : Colors.grey[700]),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? AppColors.brandPrimary
                      : (isDark ? Colors.white70 : Colors.grey[800]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiagnosticsCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE8EEE9),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.phonelink_setup_rounded,
                      size: 18, color: AppColors.brandPrimary),
                  SizedBox(width: 8),
                  Text(
                    '设备诊断信息',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Switch.adaptive(
                value: _includeDiagnostics,
                activeTrackColor: AppColors.brandPrimary,
                onChanged: (val) => setState(() => _includeDiagnostics = val),
              ),
            ],
          ),
          if (_includeDiagnostics && _diagInfo != null) ...[
            const SizedBox(height: 6),
            Text(
              _diagInfo!.summaryText,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.grey[600],
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: _showDiagnosticsDialog,
                child: const Text(
                  '查看诊断信息 >',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.brandPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = themeProvider.isCleanBackgroundMode && !isDark
        ? const Color(0xFFFFFAF4)
        : Theme.of(context).colorScheme.surface;

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        title: const Text(
          '新建反馈',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: pageBg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 反馈类型
            const Text(
              '反馈类型',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildTypeChip('bug', '问题反馈', Icons.bug_report_outlined),
                const SizedBox(width: 10),
                _buildTypeChip('suggestion', '功能建议', Icons.lightbulb_outline),
                const SizedBox(width: 10),
                _buildTypeChip('other', '其他', Icons.chat_bubble_outline),
              ],
            ),
            const SizedBox(height: 20),

            // 问题标题
            const Text(
              '问题标题',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              maxLength: 60,
              decoration: InputDecoration(
                hintText:
                    _type == 'bug' ? '例如：课表重新同步后课程时间没有更新' : '例如：希望课表支持临时调整课程',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white38 : Colors.grey[400],
                ),
                filled: true,
                fillColor: isDark ? const Color(0xFF1E2226) : Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                  ),
                ),
                counterText: '',
              ),
            ),
            const SizedBox(height: 20),

            // 详细描述
            const Text(
              '详细描述',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descController,
              maxLines: 5,
              maxLength: 1000,
              decoration: InputDecoration(
                hintText:
                    _type == 'bug' ? '请描述发生了什么，什么情况下会出现……' : '请描述你的想法与期望如何使用……',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white38 : Colors.grey[400],
                ),
                filled: true,
                fillColor: isDark ? const Color(0xFF1E2226) : Colors.white,
                contentPadding: const EdgeInsets.all(16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // 复现信息只对问题反馈开放，建议和其他类型保持简洁描述链路。
            if (_type == 'bug')
              GestureDetector(
                onTap: () => setState(() => _expandRepro = !_expandRepro),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        _expandRepro
                            ? Icons.remove_circle_outline
                            : Icons.add_circle_outline,
                        size: 18,
                        color: AppColors.brandPrimary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _expandRepro ? '收起复现信息' : '＋ 补充复现信息 (可选)',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.brandPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_type == 'bug' && _expandRepro) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.03)
                      : const Color(0xFFF9FBFA),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('复现步骤',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _stepsController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: '1. 点击……\n2. 切换到……\n3. 出现报错……',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('实际结果',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _actualController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: '实际看到的结果……',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('期望结果',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _expectedController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: '期望应该发生什么……',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),

            // 相关截图（最多6张）
            const Text(
              '相关截图 (最多 6 张)',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ImageUploadWidget(
              maxImages: 6,
              onImagesUploaded: (imgs) {
                setState(() => _uploadedImages = imgs);
              },
            ),

            const SizedBox(height: 24),

            // 设备诊断信息卡片
            _buildDiagnosticsCard(isDark),

            const SizedBox(height: 32),

            // 提交按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Text(
                        '提交反馈',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
