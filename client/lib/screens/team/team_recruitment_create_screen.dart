import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../models/team_recruitment.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../utils/team_share_link.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/cached_avatar.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/team/team_form_section.dart';
import '../../widgets/team/team_recruitment_card.dart';
import '../../widgets/team/team_ui_tokens.dart';
import '../../widgets/water_team/team_deadline_picker.dart';
import 'team_recruitment_detail_screen.dart';

class TeamRecruitmentCreateScreen extends StatefulWidget {
  final TeamRecruitment? initialValue;
  const TeamRecruitmentCreateScreen({super.key, this.initialValue});

  @override
  State<TeamRecruitmentCreateScreen> createState() =>
      _TeamRecruitmentCreateScreenState();
}

class _TeamRecruitmentCreateScreenState
    extends State<TeamRecruitmentCreateScreen> {
  final _formKey = GlobalKey<FormState>();

  // 基础信息
  final _titleController = TextEditingController();
  String _category = 'competition';

  // 招募名额与方向
  int _neededCount = 2;
  final List<String> _roles = [];
  final _customRoleController = TextEditingController();
  bool _showCustomRoleInput = false;

  // 招募说明：结构化模板 vs 自由编辑
  bool _isStructuredMode = true;
  final _introController = TextEditingController();
  final _progressController = TextEditingController();
  final _expectationController = TextEditingController();
  final _cooperationController = TextEditingController();
  final _resourceController = TextEditingController();
  final _freeDescriptionController = TextEditingController();

  // 时间与图片
  DateTime? _deadline;
  final List<PostImage> _existingImages = [];
  final List<XFile> _images = [];
  bool _imagesChanged = false;

  // 预置推荐方向词库（根据场景动态变化）
  static const Map<String, List<String>> _recommendedRolesByCategory = {
    'competition': [
      '算法攻坚',
      '数学建模',
      'Python/MATLAB',
      '论文写作',
      '数据分析',
      '答辩PPT',
      '前端开发',
      '后端开发',
      '嵌入式硬件',
      '文档整理',
    ],
    'project': [
      '产品经理',
      'UI/UX设计',
      'Flutter开发',
      'Vue/React前端',
      'Go/Java后端',
      'Python/AI',
      'STM32嵌入式',
      '机械结构',
      '商业计划书',
      '路演答辩',
    ],
    'study': [
      '考研数学',
      '考研英语',
      '专业课研讨',
      '每日早起打卡',
      '四六级刷题',
      '期末复习',
      '错题复盘',
      '自习监督',
    ],
    'activity': [
      '摄影摄像',
      '文案策划',
      '活动主持',
      '后勤组织',
      '视频剪辑',
      '运动搭子',
      '自驾拼车',
      '桌游同好',
    ],
    'other': [
      '技术交流',
      '经验共享',
      '兴趣同好',
      '日常互助',
      '资源共享',
    ],
  };

  @override
  void initState() {
    super.initState();
    final value = widget.initialValue;
    if (value != null) {
      _titleController.text = value.title;
      _category = value.category;
      _neededCount = value.neededCount.clamp(1, 20);
      _roles.addAll(value.roles);
      _existingImages.addAll(value.images);
      _deadline = value.deadline;

      // 解析已有描述：若包含结构化标签则填入模板，否则进入自由编辑模式
      _parseDescription(value.description);
    }
  }

  void _parseDescription(String desc) {
    if (desc.contains('【队伍简介】') ||
        desc.contains('【我们希望你】') ||
        desc.contains('【当前进度】') ||
        desc.contains('【合作安排】') ||
        desc.contains('【已有资源】')) {
      _isStructuredMode = true;
      _introController.text = _extractSection(desc, '【队伍简介】');
      _progressController.text = _extractSection(desc, '【当前进度】');
      _expectationController.text = _extractSection(desc, '【我们希望你】');
      _cooperationController.text = _extractSection(desc, '【合作安排】');
      _resourceController.text = _extractSection(desc, '【已有资源】');
    } else {
      _isStructuredMode = false;
      _freeDescriptionController.text = desc;
      if (desc.trim().isNotEmpty) {
        _introController.text = desc.trim();
      }
    }
  }

  String _extractSection(String text, String tag) {
    final startIndex = text.indexOf(tag);
    if (startIndex == -1) return '';
    final contentStart = startIndex + tag.length;
    final nextTags = [
      '【队伍简介】',
      '【当前进度】',
      '【我们希望你】',
      '【合作安排】',
      '【已有资源】'
    ];
    int nearestEnd = text.length;
    for (final nextTag in nextTags) {
      if (nextTag == tag) continue;
      final idx = text.indexOf(nextTag, contentStart);
      if (idx != -1 && idx < nearestEnd) {
        nearestEnd = idx;
      }
    }
    return text.substring(contentStart, nearestEnd).trim();
  }

  String _buildCombinedDescription() {
    if (!_isStructuredMode) {
      return _freeDescriptionController.text.trim();
    }
    final sb = StringBuffer();
    final intro = _introController.text.trim();
    final progress = _progressController.text.trim();
    final expectation = _expectationController.text.trim();
    final cooperation = _cooperationController.text.trim();
    final resource = _resourceController.text.trim();

    if (intro.isNotEmpty) {
      sb.writeln('【队伍简介】\n$intro');
    }
    if (progress.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      sb.writeln('【当前进度】\n$progress');
    }
    if (expectation.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      sb.writeln('【我们希望你】\n$expectation');
    }
    if (cooperation.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      sb.writeln('【合作安排】\n$cooperation');
    }
    if (resource.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      sb.writeln('【已有资源】\n$resource');
    }
    return sb.toString().trim();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _customRoleController.dispose();
    _introController.dispose();
    _progressController.dispose();
    _expectationController.dispose();
    _cooperationController.dispose();
    _resourceController.dispose();
    _freeDescriptionController.dispose();
    super.dispose();
  }

  void _addRole(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _roles.contains(trimmed)) return;
    if (trimmed.length > 20 || _roles.length >= 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('方向最多 8 项，每项不超过 20 字')),
      );
      return;
    }
    setState(() {
      _roles.add(trimmed);
      _customRoleController.clear();
      _showCustomRoleInput = false;
    });
  }

  void _removeRole(String role) {
    setState(() => _roles.remove(role));
  }

  Future<void> _pickImages() async {
    final images = await ImagePicker().pickMultiImage(imageQuality: 88);
    if (images.isNotEmpty && mounted) {
      final remaining = 9 - _existingImages.length - _images.length;
      if (remaining <= 0) return;
      setState(() {
        _images.addAll(images.take(remaining));
        _imagesChanged = true;
      });
    }
  }

  void _removeImage(int index, {required bool isExisting}) {
    setState(() {
      if (isExisting) {
        _existingImages.removeAt(index);
      } else {
        _images.removeAt(index);
      }
      _imagesChanged = true;
    });
  }

  Future<void> _pickDeadline() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initialDate = _deadline != null && !_deadline!.isBefore(today)
        ? _deadline!
        : now.add(const Duration(days: 7));
    final picked = await TeamDeadlinePicker.show(
      context,
      firstDate: today,
      lastDate: DateTime(now.year + 2),
      initialDate: initialDate,
      accentColor: TeamUiTokens.accent(isDark),
    );
    if (picked != null && mounted) {
      setState(() =>
          _deadline = DateTime(picked.year, picked.month, picked.day, 23, 59));
    }
  }

  void _clearDeadline() {
    setState(() => _deadline = null);
  }

  // 构建临时招募对象用于实时预览（支持已满员/已截止/即将截止状态准确计算）
  TeamRecruitment _buildSyntheticPreviewRecruitment(User? currentUser) {
    final description = _buildCombinedDescription();
    final accepted = widget.initialValue?.acceptedCount ?? 0;
    final remaining = (_neededCount - accepted).clamp(0, 999);
    final isClosed = widget.initialValue?.status == 'closed';
    final isExpired = _deadline != null && _deadline!.isBefore(DateTime.now());
    final effectiveStatus = isClosed
        ? 'closed'
        : (isExpired
            ? 'expired'
            : (remaining == 0
                ? 'full'
                : (_deadline != null &&
                        _deadline!.isBefore(
                            DateTime.now().add(const Duration(days: 3)))
                    ? 'deadline_soon'
                    : 'recruiting')));
    final status = isClosed
        ? 'closed'
        : (isExpired ? 'expired' : (remaining == 0 ? 'full' : 'recruiting'));

    return TeamRecruitment(
      id: widget.initialValue?.id ?? 9999,
      postId: widget.initialValue?.postId ?? 9999,
      category: _category,
      title: _titleController.text.trim().isEmpty
          ? '招募标题预览'
          : _titleController.text.trim(),
      description: description.isEmpty ? '暂未填写招募详情' : description,
      neededCount: _neededCount,
      acceptedCount: accepted,
      remainingCount: remaining,
      roles: _roles.isEmpty ? ['虚位以待'] : _roles,
      deadline: _deadline,
      status: status,
      effectiveStatus: effectiveStatus,
      applicationCount: widget.initialValue?.applicationCount ?? 0,
      pendingApplicationCount:
          widget.initialValue?.pendingApplicationCount ?? 0,
      createdAt: widget.initialValue?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      author: TeamRecruitmentAuthor(
        id: currentUser?.id ?? 0,
        name: currentUser?.nickname ?? '理工同学',
        avatar: currentUser?.avatar ?? '',
        major:
            '${currentUser?.eduCollege ?? ''} · ${currentUser?.eduMajor ?? '沈阳理工大学'}',
      ),
      images: _existingImages,
    );
  }

  void _showPreview() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentUser = context.read<AuthProvider>().user;
    final previewItem = _buildSyntheticPreviewRecruitment(currentUser);
    final totalImagesCount = _existingImages.length + _images.length;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: TeamUiTokens.pageBg(isDark),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                // 顶部抓手与标题
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.remove_red_eye_rounded,
                          size: 20, color: CampusTheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '组队展示效果实时预览',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: TeamUiTokens.title(isDark),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        '💡 组队广场卡片样式',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: TeamUiTokens.subtitle(isDark),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TeamRecruitmentCard(
                        recruitment: previewItem,
                        onTap: () {},
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '💡 招募详情与 Web 分享页排版',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: TeamUiTokens.subtitle(isDark),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: TeamUiTokens.cardBg(isDark),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: TeamUiTokens.border(isDark)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              previewItem.title,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '招募名额：${previewItem.neededCount} 人 · 已招募 ${previewItem.acceptedCount} 人'
                              '${previewItem.remainingCount > 0 ? " (还需 ${previewItem.remainingCount} 人)" : " (名额已满)"}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: CampusTheme.primary),
                            ),
                            const SizedBox(height: 8),
                            if (previewItem.roles.isNotEmpty)
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: previewItem.roles
                                    .map((r) => Chip(
                                          label: Text('🎯 $r'),
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                        ))
                                    .toList(),
                              ),
                            const SizedBox(height: 12),
                            const Divider(height: 1),
                            const SizedBox(height: 12),
                            Text(
                              previewItem.description,
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.6,
                                color: TeamUiTokens.title(isDark),
                              ),
                            ),
                            // 本地与已有图片统一展示
                            if (totalImagesCount > 0) ...[
                              const SizedBox(height: 16),
                              const Divider(height: 1),
                              const SizedBox(height: 12),
                              Text(
                                '项目展示图片 ($totalImagesCount 张)',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 90,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: totalImagesCount,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(width: 8),
                                  itemBuilder: (context, idx) {
                                    final isCover = idx == 0;
                                    final isExisting =
                                        idx < _existingImages.length;
                                    return Stack(
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: SizedBox(
                                            width: 90,
                                            height: 90,
                                            child: isExisting
                                                ? AppCachedImage.public(
                                                    imageUrl:
                                                        _existingImages[idx]
                                                            .url,
                                                    fit: BoxFit.cover,
                                                  )
                                                : Image.file(
                                                    File(_images[idx -
                                                            _existingImages
                                                                .length]
                                                        .path),
                                                    fit: BoxFit.cover,
                                                  ),
                                          ),
                                        ),
                                        if (isCover)
                                          Positioned(
                                            left: 4,
                                            top: 4,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.black
                                                    .withValues(alpha: 0.7),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                '封面',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final description = _buildCombinedDescription();
    if (description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写招募详情或队伍介绍')),
      );
      return;
    }

    final provider = context.read<TeamRecruitmentProvider>();
    final existing = widget.initialValue;

    if (existing == null) {
      final created = await provider.create(
        category: _category,
        title: _titleController.text.trim(),
        description: description,
        neededCount: _neededCount,
        roles: _roles,
        deadline: _deadline,
        images: _images,
      );
      if (!mounted) return;
      if (created == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('发布失败，请检查网络后重试')),
        );
        return;
      }

      // 发布成功闭环：展示分享成就面板
      _showPublishSuccessSheet(created);
      return;
    }

    final result = await provider.updateRecruitment(
      recruitmentId: existing.id,
      category: _category,
      title: _titleController.text.trim(),
      description: description,
      neededCount: _neededCount,
      roles: _roles,
      deadline: _deadline,
      imageFileIds: _imagesChanged
          ? _existingImages
              .map((image) => image.fileId)
              .where((fileId) => fileId > 0)
              .toList()
          : null,
      images: _images,
    );
    if (!mounted) return;
    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.errorMessage ?? '保存失败，请稍后重试')),
      );
      return;
    }
    Navigator.pop(context, true);
  }

  // 发布成功闭环 Sheet
  void _showPublishSuccessSheet(TeamRecruitment created) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final webUrl = TeamShareLink.webUri(created.id).toString();

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: TeamUiTokens.pageBg(isDark),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: CampusTheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: CampusTheme.primary,
                  size: 38,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '组队招募发布成功！',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: TeamUiTokens.title(isDark),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '大家现在已经可以在组队广场与公开分享页看到你的招募',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: TeamUiTokens.subtitle(isDark),
                ),
              ),
              const SizedBox(height: 20),

              // 招募微缩卡片
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: TeamUiTokens.cardBg(isDark),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TeamUiTokens.border(isDark)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      created.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '已招募 ${created.acceptedCount} / 招募名额 ${created.neededCount} 人 · ${teamCategoryLabel(created.category)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: CampusTheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 分享给同学（主操作）
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: TeamUiTokens.primaryButtonStyle(isDark),
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: const Text('分享给同学 (微信 / QQ / 朋友圈)'),
                  onPressed: () async {
                    await Share.share(
                      '【沈理校园组队邀请】${created.title}\n\n查看招募详情并快速入队：$webUrl',
                      subject: '沈理校园组队邀请',
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),

              // 复制分享链接
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  style: TeamUiTokens.secondaryButtonStyle(isDark),
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text('复制组队分享链接'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: webUrl));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('✓ 组队链接已复制到剪贴板')),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(height: 10),

              // 查看详情或返回
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx); // 关闭 sheet
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TeamRecruitmentDetailScreen(
                            recruitmentId: created.id,
                          ),
                        ),
                      );
                    },
                    child: const Text('查看招募详情 →'),
                  ),
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx); // 关闭 sheet
                      Navigator.pop(context, true); // 返回广场
                    },
                    child: Text(
                      '返回组队中心',
                      style: TextStyle(color: TeamUiTokens.subtitle(isDark)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TeamRecruitmentProvider>();
    final authProvider = context.watch<AuthProvider>();
    final currentUser = authProvider.user;

    final submitting = provider.isCreating ||
        (widget.initialValue != null &&
            provider.updatingIds.contains(widget.initialValue!.id));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = TeamUiTokens.pageBg(isDark);
    final borderColor = TeamUiTokens.border(isDark);

    // 编辑模式下的名额下限：不能低于已被接受的成员数
    final acceptedCount = widget.initialValue?.acceptedCount ?? 0;
    final minNeeded = (acceptedCount > 0 ? acceptedCount : 1).clamp(1, 20);

    return Scaffold(
      backgroundColor: pageColor,
      appBar: AppBar(
        backgroundColor: pageColor,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.initialValue == null ? '发起组队' : '编辑招募'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.remove_red_eye_outlined, size: 17),
            label: const Text('预览'),
            onPressed: _showPreview,
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: pageColor,
          border: Border(top: BorderSide(color: borderColor)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      style: TeamUiTokens.secondaryButtonStyle(isDark),
                      onPressed: _showPreview,
                      child: const Text('预览效果'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      style: TeamUiTokens.primaryButtonStyle(isDark),
                      onPressed: submitting ? null : _submit,
                      child: Text(submitting
                          ? '提交中…'
                          : (widget.initialValue == null ? '发布组队' : '保存修改')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // 顶部：发布身份展示
            _buildPublisherIdentityCard(currentUser, isDark, borderColor),
            const SizedBox(height: TeamUiTokens.sectionGap),

            // 01 基本信息
            TeamFormSection(
              title: '01 基本信息',
              children: [
                const Text('组队场景',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [
                    ('🏆 学科竞赛', 'competition'),
                    ('💻 项目协作', 'project'),
                    ('📚 学习互助', 'study'),
                    ('🎉 活动组队', 'activity'),
                    ('💬 其他组队', 'other')
                  ].map((item) {
                    final selected = _category == item.$2;
                    return ChoiceChip(
                      label: Text(item.$1),
                      selected: selected,
                      selectedColor: TeamUiTokens.accentSoft(isDark),
                      labelStyle: TextStyle(
                        color: selected
                            ? TeamUiTokens.accent(isDark)
                            : TeamUiTokens.subtitle(isDark),
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                            color: selected ? Colors.transparent : borderColor),
                      ),
                      onSelected: (val) {
                        if (val) setState(() => _category = item.$2);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('招募标题',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(
                      '${_titleController.text.length}/100',
                      style: TextStyle(
                          fontSize: 11, color: TeamUiTokens.subtitle(isDark)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _titleController,
                  maxLength: 100,
                  buildCounter: (_,
                          {required currentLength,
                          required isFocused,
                          maxLength}) =>
                      null,
                  decoration: InputDecoration(
                    hintText: '例如：第十六届蓝桥杯软件赛寻找算法与前端队友',
                    hintStyle: TextStyle(
                        color: TeamUiTokens.subtitle(isDark), fontSize: 13),
                    helperText: '建议包含：赛事/项目名称 + 期望招募方向',
                    helperStyle: TextStyle(
                        color: TeamUiTokens.subtitle(isDark), fontSize: 11),
                    filled: true,
                    fillColor: Colors.transparent,
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(TeamUiTokens.fieldRadius),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(TeamUiTokens.fieldRadius),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(TeamUiTokens.fieldRadius),
                      borderSide: BorderSide(
                          color: TeamUiTokens.accent(isDark), width: 1.5),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final trimmed = (v ?? '').trim();
                    if (trimmed.isEmpty) return '请输入招募标题';
                    if (trimmed.length < 4) return '标题至少需要4个字';
                    return null;
                  },
                ),
              ],
            ),
            const SizedBox(height: TeamUiTokens.sectionGap),

            // 02 招募队友 (名额与期望方向)
            TeamFormSection(
              title: '02 招募队友',
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('希望再招几名队友？',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          acceptedCount > 0
                              ? '已有 $acceptedCount 名队员通过申请 (招募名额不能低于 $minNeeded 人)'
                              : '已通过申请的队友会计入招募进度（不含队长本人）',
                          style: TextStyle(
                              fontSize: 11,
                              color: acceptedCount > 0
                                  ? CampusTheme.primary
                                  : TeamUiTokens.subtitle(isDark)),
                        ),
                      ],
                    ),
                    // Stepper
                    Container(
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                                width: 34, height: 34),
                            onPressed: _neededCount > minNeeded
                                ? () => setState(() => _neededCount--)
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              '$_neededCount 人',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: CampusTheme.primary,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                                width: 34, height: 34),
                            onPressed: _neededCount < 20
                                ? () => setState(() => _neededCount++)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('期望技能 / 招募方向',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(
                      '已选 ${_roles.length}/8',
                      style: TextStyle(
                        fontSize: 11,
                        color: _roles.length >= 8
                            ? Colors.red
                            : TeamUiTokens.subtitle(isDark),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // 已选标签
                if (_roles.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _roles.map((role) {
                        return Chip(
                          label: Text(role),
                          backgroundColor: TeamUiTokens.accentSoft(isDark),
                          labelStyle: TextStyle(
                            color: TeamUiTokens.accent(isDark),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                          deleteIcon: const Icon(Icons.close_rounded, size: 15),
                          deleteIconColor: TeamUiTokens.accent(isDark),
                          onDeleted: () => _removeRole(role),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: TeamUiTokens.accent(isDark)
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '点击下方推荐标签快速添加，或自定义输入',
                      style: TextStyle(
                          fontSize: 12, color: TeamUiTokens.subtitle(isDark)),
                    ),
                  ),

                // 推荐标签库
                Text(
                  '推荐方向：',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: TeamUiTokens.subtitle(isDark),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: (_recommendedRolesByCategory[_category] ??
                          _recommendedRolesByCategory['other']!)
                      .map((recRole) {
                    final alreadyAdded = _roles.contains(recRole);
                    return ActionChip(
                      label: Text(alreadyAdded ? '✓ $recRole' : '+ $recRole'),
                      labelStyle: TextStyle(
                        fontSize: 11,
                        color: alreadyAdded
                            ? TeamUiTokens.subtitle(isDark)
                            : TeamUiTokens.title(isDark),
                        fontWeight:
                            alreadyAdded ? FontWeight.w400 : FontWeight.w600,
                      ),
                      backgroundColor: isDark ? Colors.white10 : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: borderColor),
                      ),
                      onPressed: alreadyAdded ? null : () => _addRole(recRole),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 10),

                // 自定义方向输入
                if (!_showCustomRoleInput)
                  TextButton.icon(
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                    label: const Text('自定义其他方向'),
                    style: TextButton.styleFrom(
                      foregroundColor: TeamUiTokens.accent(isDark),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () =>
                        setState(() => _showCustomRoleInput = true),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _customRoleController,
                          maxLength: 20,
                          buildCounter: (_,
                                  {required currentLength,
                                  required isFocused,
                                  maxLength}) =>
                              null,
                          decoration: InputDecoration(
                            hintText: '输入自定义方向 (如: UI/答辩)',
                            hintStyle: TextStyle(
                                color: TeamUiTokens.subtitle(isDark),
                                fontSize: 12),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: borderColor),
                            ),
                          ),
                          onSubmitted: _addRole,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: TeamUiTokens.primaryButtonStyle(isDark),
                        onPressed: () =>
                            _addRole(_customRoleController.text),
                        child: const Text('添加'),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: TeamUiTokens.sectionGap),

            // 03 招募详情 (结构化 vs 自由编辑)
            TeamFormSection(
              title: '03 招募详情',
              children: [
                // 模式切换 Segment
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _isStructuredMode ? '结构化信息模板' : '自由编辑模式',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('📋 结构化模板'),
                          selected: _isStructuredMode,
                          selectedColor: TeamUiTokens.accentSoft(isDark),
                          labelStyle: TextStyle(
                            fontSize: 11,
                            color: _isStructuredMode
                                ? TeamUiTokens.accent(isDark)
                                : TeamUiTokens.subtitle(isDark),
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (val) {
                            if (val && !_isStructuredMode) {
                              // 切回结构化模式：防止数据丢失，若自由文本无标签则保存在简介中
                              final freeText =
                                  _freeDescriptionController.text.trim();
                              if (freeText.isNotEmpty) {
                                _parseDescription(freeText);
                                if (_introController.text.isEmpty &&
                                    _progressController.text.isEmpty &&
                                    _expectationController.text.isEmpty &&
                                    _cooperationController.text.isEmpty &&
                                    _resourceController.text.isEmpty) {
                                  _introController.text = freeText;
                                }
                              }
                              setState(() => _isStructuredMode = true);
                            }
                          },
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: const Text('✍️ 自由编辑'),
                          selected: !_isStructuredMode,
                          selectedColor: TeamUiTokens.accentSoft(isDark),
                          labelStyle: TextStyle(
                            fontSize: 11,
                            color: !_isStructuredMode
                                ? TeamUiTokens.accent(isDark)
                                : TeamUiTokens.subtitle(isDark),
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (val) {
                            if (val && _isStructuredMode) {
                              // 将当前结构化内容合并到自由文本框
                              final combined = _buildCombinedDescription();
                              if (combined.isNotEmpty) {
                                _freeDescriptionController.text = combined;
                              }
                              setState(() => _isStructuredMode = false);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                if (_isStructuredMode) ...[
                  // 结构化输入块
                  _buildStructuredField(
                    label: '队伍 / 项目简介',
                    hintText: '介绍目前在做什么、参加什么比赛或项目背景...',
                    controller: _introController,
                    isDark: isDark,
                    borderColor: borderColor,
                    isRequired: true,
                    minLines: 3,
                  ),
                  const SizedBox(height: 12),
                  _buildStructuredField(
                    label: '当前进度 / 已有基础',
                    hintText: '例如：已有2名成员，已完成初步算法调研或初版Demo...',
                    controller: _progressController,
                    isDark: isDark,
                    borderColor: borderColor,
                    minLines: 2,
                  ),
                  const SizedBox(height: 12),
                  _buildStructuredField(
                    label: '我们希望你',
                    hintText: '例如：熟练掌握C++/Java，有团队责任心，每周可投入充足时间...',
                    controller: _expectationController,
                    isDark: isDark,
                    borderColor: borderColor,
                    isRequired: true,
                    minLines: 3,
                  ),
                  const SizedBox(height: 12),
                  _buildStructuredField(
                    label: '合作与沟通安排',
                    hintText: '例如：每周三次线上讨论，赛前周末集中复盘...',
                    controller: _cooperationController,
                    isDark: isDark,
                    borderColor: borderColor,
                    minLines: 2,
                  ),
                  const SizedBox(height: 12),
                  _buildStructuredField(
                    label: '已有资源 (选填)',
                    hintText: '例如：往届真题解析、校内获奖学长笔记库、导师指导支持...',
                    controller: _resourceController,
                    isDark: isDark,
                    borderColor: borderColor,
                    minLines: 2,
                  ),
                ] else ...[
                  TextFormField(
                    controller: _freeDescriptionController,
                    maxLines: 12,
                    minLines: 6,
                    maxLength: 5000,
                    decoration: InputDecoration(
                      hintText:
                          '介绍你的队伍愿景、参赛目标、已有成员基础与对新队友的期望...\n支持多段落与排版。',
                      hintStyle: TextStyle(
                          color: TeamUiTokens.subtitle(isDark), fontSize: 13),
                      filled: true,
                      fillColor: Colors.transparent,
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(TeamUiTokens.fieldRadius),
                        borderSide: BorderSide(color: borderColor),
                      ),
                    ),
                    validator: (v) {
                      if (!_isStructuredMode && (v == null || v.trim().isEmpty)) {
                        return '请填写招募详情说明';
                      }
                      return null;
                    },
                  ),
                ],
              ],
            ),
            const SizedBox(height: TeamUiTokens.sectionGap),

            // 04 展示与时间
            TeamFormSection(
              title: '04 展示与时间',
              children: [
                // 截止时间
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('招募截止时间',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          _deadline == null
                              ? '长期有效 (招满即止)'
                              : '截止：${_deadline!.year}年${_deadline!.month}月${_deadline!.day}日',
                          style: TextStyle(
                            fontSize: 12,
                            color: _deadline == null
                                ? TeamUiTokens.subtitle(isDark)
                                : CampusTheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        if (_deadline != null)
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            tooltip: '设为长期有效',
                            onPressed: _clearDeadline,
                          ),
                        OutlinedButton(
                          style: TeamUiTokens.secondaryButtonStyle(isDark),
                          onPressed: _pickDeadline,
                          child: Text(_deadline == null ? '设置截止日期' : '修改日期'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // 图片与封面
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('项目展示图片',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(
                      '${_existingImages.length + _images.length}/9 张',
                      style: TextStyle(
                          fontSize: 11, color: TeamUiTokens.subtitle(isDark)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '💡 第一张图片将自动作为组队大厅与分享卡片的展示封面',
                  style: TextStyle(
                      fontSize: 11, color: TeamUiTokens.subtitle(isDark)),
                ),
                const SizedBox(height: 10),

                // 图片网格
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: _existingImages.length +
                      _images.length +
                      ((_existingImages.length + _images.length < 9) ? 1 : 0),
                  itemBuilder: (context, index) {
                    final total = _existingImages.length + _images.length;
                    if (index == total) {
                      // 添加按钮
                      return InkWell(
                        onTap: _pickImages,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: borderColor, style: BorderStyle.solid),
                            borderRadius: BorderRadius.circular(12),
                            color: isDark ? Colors.white10 : Colors.grey[50],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_photo_alternate_outlined,
                                  color: TeamUiTokens.subtitle(isDark)),
                              const SizedBox(height: 4),
                              Text('添加图片',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: TeamUiTokens.subtitle(isDark))),
                            ],
                          ),
                        ),
                      );
                    }

                    final isExisting = index < _existingImages.length;
                    final isCover = index == 0;

                    return Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: isExisting
                                ? AppCachedImage.public(
                                    imageUrl: _existingImages[index].url,
                                    fit: BoxFit.cover,
                                  )
                                : Image.file(
                                    File(_images[
                                            index - _existingImages.length]
                                        .path),
                                    fit: BoxFit.cover,
                                  ),
                          ),
                        ),
                        // 封面 Badge
                        if (isCover)
                          Positioned(
                            left: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                '封面',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        // 删除按钮
                        Positioned(
                          right: 4,
                          top: 4,
                          child: GestureDetector(
                            onTap: () => _removeImage(
                              isExisting
                                  ? index
                                  : index - _existingImages.length,
                              isExisting: isExisting,
                            ),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 顶部发布人身份卡片
  Widget _buildPublisherIdentityCard(
      User? user, bool isDark, Color borderColor) {
    final avatarUrl = user?.avatar.isNotEmpty == true
        ? '${ApiConstants.baseUrl}${user!.avatar}'
        : null;
    final nickname = user?.nickname ?? '理工同学';
    final college = user?.eduCollege ?? '';
    final major = user?.eduMajor ?? '沈阳理工大学在校生';
    final grade = user?.eduGrade ?? '';
    final majorText = [college, major, grade]
        .where((s) => s.isNotEmpty)
        .join(' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TeamUiTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(TeamUiTokens.cardRadius),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CachedAvatar(
                imageUrl: avatarUrl,
                radius: 20,
                fallbackText: nickname,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: TeamUiTokens.title(isDark),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: CampusTheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '✓ 校园认证',
                            style: TextStyle(
                              color: CampusTheme.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      majorText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: TeamUiTokens.subtitle(isDark),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '你的昵称、头像与院系专业将作为发起人身份公开展示在 App 组队广场与分享页中',
            style: TextStyle(
              fontSize: 10,
              color: TeamUiTokens.subtitle(isDark),
            ),
          ),
        ],
      ),
    );
  }

  // 结构化输入子控件
  Widget _buildStructuredField({
    required String label,
    required String hintText,
    required TextEditingController controller,
    required bool isDark,
    required Color borderColor,
    bool isRequired = false,
    int minLines = 2,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: TeamUiTokens.title(isDark),
              ),
            ),
            if (isRequired)
              const Text(
                ' *',
                style: TextStyle(color: Colors.red, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          minLines: minLines,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle:
                TextStyle(color: TeamUiTokens.subtitle(isDark), fontSize: 12),
            filled: true,
            fillColor: isDark ? Colors.white10 : Colors.grey[50],
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  BorderSide(color: TeamUiTokens.accent(isDark), width: 1.5),
            ),
          ),
          validator: (v) {
            if (isRequired && (v == null || v.trim().isEmpty)) {
              return '请填写$label';
            }
            return null;
          },
        ),
      ],
    );
  }
}
