import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../models/water_section.dart';
import '../../models/water_section_icon_review.dart';
import '../../providers/auth_provider.dart';
import '../../providers/water_section_provider.dart';

class WaterSectionDisplayEditScreen extends StatefulWidget {
  final WaterSection section;

  const WaterSectionDisplayEditScreen({super.key, required this.section});

  @override
  State<WaterSectionDisplayEditScreen> createState() =>
      _WaterSectionDisplayEditScreenState();
}

class _WaterSectionDisplayEditScreenState
    extends State<WaterSectionDisplayEditScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _subtitleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _iconKeyController;
  late final TextEditingController _publishActionController;
  late final TextEditingController _emptyTitleController;
  late final TextEditingController _emptyDescriptionController;
  late final TextEditingController _noticeTextController;
  late final TextEditingController _starterQuestionsController;

  late String _defaultSort;
  String _colorHex = '';
  String? _coverUrl;
  String? _coverPortraitUrl;
  String? _coverLandscapeUrl;
  String? _coverSquareUrl;
  String? _avatarUrl;
  WaterSectionIconReview? _pendingIconReview;
  bool _isLoadingReview = true;
  bool _isSubmitting = false;
  bool _isUploadingCover = false;
  bool _isUploadingAvatar = false;

  static const List<String> _presetColors = [
    '#10B981', '#3B82F6', '#6366F1', '#8B5CF6', '#EC4899', '#EF4444',
    '#F97316', '#EAB308', '#14B8A6', '#06B6D4', '#84CC16', '#64748B',
    '#7ED321',
  ];

  @override
  void initState() {
    super.initState();
    final section = widget.section;
    _titleController = TextEditingController(text: section.title);
    _subtitleController = TextEditingController(text: section.subtitle);
    _descriptionController = TextEditingController(text: section.description);
    _iconKeyController = TextEditingController(text: section.iconKey);
    _colorHex = section.colorHex;
    _publishActionController =
        TextEditingController(text: section.publishActionText);
    _emptyTitleController = TextEditingController(text: section.emptyTitle);
    _emptyDescriptionController =
        TextEditingController(text: section.emptyDescription);
    _noticeTextController = TextEditingController(text: section.noticeText);
    _starterQuestionsController =
        TextEditingController(text: section.starterQuestions.join('\n'));
    _defaultSort = _normalizeSort(section.defaultSort);
    _coverUrl = section.coverUrl.isNotEmpty ? section.coverUrl : null;
    _coverPortraitUrl =
        section.coverPortraitUrl.isNotEmpty ? section.coverPortraitUrl : null;
    _coverLandscapeUrl =
        section.coverLandscapeUrl.isNotEmpty ? section.coverLandscapeUrl : null;
    _coverSquareUrl =
        section.coverSquareUrl.isNotEmpty ? section.coverSquareUrl : null;
    _avatarUrl = section.avatarUrl.isNotEmpty ? section.avatarUrl : null;

    // 添加监听，为了实时预览
    _titleController.addListener(_onFieldChanged);
    _subtitleController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);
    _publishActionController.addListener(_onFieldChanged);

    _loadIconReviewStatus();
  }

  Future<void> _loadIconReviewStatus() async {
    try {
      final provider = context.read<WaterSectionProvider>();
      final service = provider.iconReviewService;
      if (service == null) return;
      final state = await service.getCurrentSectionIconReview(widget.section.slug);
      if (mounted) {
        setState(() {
          _pendingIconReview = state.pending;
          _isLoadingReview = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingReview = false);
      }
    }
  }

  void _onFieldChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _titleController.removeListener(_onFieldChanged);
    _subtitleController.removeListener(_onFieldChanged);
    _descriptionController.removeListener(_onFieldChanged);
    _publishActionController.removeListener(_onFieldChanged);

    _titleController.dispose();
    _subtitleController.dispose();
    _descriptionController.dispose();
    _iconKeyController.dispose();
    _publishActionController.dispose();
    _emptyTitleController.dispose();
    _emptyDescriptionController.dispose();
    _noticeTextController.dispose();
    _starterQuestionsController.dispose();
    super.dispose();
  }

  String _normalizeSort(String sort) {
    switch (sort) {
      case 'recommend':
        return 'all';
      case 'latest':
        return 'time';
      case 'all':
      case 'time':
      case 'featured':
      case 'following':
        return sort;
      default:
        return 'all';
    }
  }

  Future<String?> _cropAndUpload(
      String sourcePath, String title, CropAspectRatio preset) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      maxWidth: 1920,
      maxHeight: 1920,
      compressQuality: 85,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: title,
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          lockAspectRatio: true,
        ),
        IOSUiSettings(
          title: title,
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
      aspectRatio: preset,
    );

    if (cropped == null) return null;
    final croppedBytes = await cropped.readAsBytes();
    final croppedName =
        'section_cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
    
    if (!mounted) return null;
    final auth = context.read<AuthProvider>();
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        croppedBytes,
        filename: croppedName,
        contentType: DioMediaType('image', 'jpeg'),
      ),
    });
    final uploadRes = await auth.dio.post('/upload', data: formData);
    if (uploadRes.statusCode == 200 && uploadRes.data['url'] != null) {
      return uploadRes.data['url'] as String;
    }
    return null;
  }

  Future<void> _pickAndUploadCover() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    if (!mounted) return;

    setState(() => _isUploadingCover = true);
    try {
      final sourcePath = picked.path;
      final portraitUrl = await _cropAndUpload(sourcePath, '裁剪手机版块背景 (3:4)',
          const CropAspectRatio(ratioX: 3, ratioY: 4));
      if (portraitUrl == null) throw Exception('取消或失败');

      final landscapeUrl = await _cropAndUpload(sourcePath, '裁剪横向封面 (16:9)',
          const CropAspectRatio(ratioX: 16, ratioY: 9));
      if (landscapeUrl == null) throw Exception('取消或失败');

      final squareUrl = await _cropAndUpload(sourcePath, '裁剪方形封面 (1:1)',
          const CropAspectRatio(ratioX: 1, ratioY: 1));
      if (squareUrl == null) throw Exception('取消或失败');

      if (mounted) {
        setState(() {
          _coverPortraitUrl = portraitUrl;
          _coverLandscapeUrl = landscapeUrl;
          _coverSquareUrl = squareUrl;
          _coverUrl = portraitUrl;
        });
        _showSnack('三组封面图已上传，保存后生效');
      }
    } catch (e) {
      if (mounted) _showSnack('上传中断或失败: $e');
    } finally {
      if (mounted) setState(() => _isUploadingCover = false);
    }
  }

  Future<void> _submitNewIcon() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    if (!mounted) return;

    setState(() => _isUploadingAvatar = true);
    try {
      final avatarUrl = await _cropAndUpload(picked.path, '裁剪版块头像 (1:1)',
          const CropAspectRatio(ratioX: 1, ratioY: 1));
      if (avatarUrl == null) throw Exception('取消或失败');

      if (mounted) {
        final provider = context.read<WaterSectionProvider>();
        final service = provider.iconReviewService;
        if (service != null) {
          final review = await service.submitSectionIconReview(widget.section.slug, avatarUrl, '更换版块头像申请');
          setState(() {
            _pendingIconReview = review;
          });
          _showSnack('图标审核申请已提交，等待管理员审核');
        }
      }
    } catch (e) {
      if (mounted) _showSnack('上传中断或失败: $e');
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  Future<void> _cancelIconReview() async {
    if (_pendingIconReview == null) return;
    try {
      final provider = context.read<WaterSectionProvider>();
      final service = provider.iconReviewService;
      if (service != null) {
        await service.cancelSectionIconReview(widget.section.slug, _pendingIconReview!.id);
        setState(() {
          _pendingIconReview = null;
        });
        _showSnack('已撤销审核申请');
      }
    } catch (e) {
      if (mounted) _showSnack('撤销失败: $e');
    }
  }

  void _clearCover() {
    setState(() {
      _coverUrl = null;
      _coverPortraitUrl = null;
      _coverLandscapeUrl = null;
      _coverSquareUrl = null;
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final questions = _starterQuestionsController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (title.isEmpty) {
      _showSnack('标题不能为空');
      return;
    }
    if (_colorHex.isNotEmpty &&
        !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(_colorHex)) {
      _showSnack('颜色必须为空或符合 #RRGGBB');
      return;
    }
    if (questions.length > 10) {
      _showSnack('引导问题最多 10 条');
      return;
    }

    setState(() => _isSubmitting = true);
    final provider = context.read<WaterSectionProvider>();
    final ok = await provider.updateSectionDisplay(
      slug: widget.section.slug,
      fields: {
        'title': title,
        'subtitle': _subtitleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'icon_key': _iconKeyController.text.trim(),
        'color_hex': _colorHex,
        'cover_url': _coverUrl ?? '',
        'cover_portrait_url': _coverPortraitUrl ?? '',
        'cover_landscape_url': _coverLandscapeUrl ?? '',
        'cover_square_url': _coverSquareUrl ?? '',
        'publish_action_text': _publishActionController.text.trim(),
        'empty_title': _emptyTitleController.text.trim(),
        'empty_description': _emptyDescriptionController.text.trim(),
        'notice_text': _noticeTextController.text.trim(),
        'starter_questions': questions,
        'default_sort': _defaultSort,
        'reason': '编辑版块展示',
      },
    );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存版块展示设置')),
      );
      Navigator.pop(context, true);
    } else {
      _showSnack(provider.error ?? '保存失败');
    }
  }

  Color get _activeColor {
    return _colorHex.isNotEmpty
        ? colorHexToColor(_colorHex)
        : Theme.of(context).colorScheme.primary;
  }

  InputDecoration _inputDecoration(String label, {String? hint, required bool isDark}) {
    final borderColor = isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE5E7EB);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: isDark ? const Color(0xFF1E2226) : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _activeColor, width: 1.3),
      ),
    );
  }

  Widget _buildCard({required String title, required List<Widget> children, required bool isDark, String? subtitle}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1D21) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFEDEFF3),
        ),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : const Color(0xFF7B818C),
              ),
            ),
          ],
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildPreviewCard(bool isDark) {
    final title = _titleController.text.isNotEmpty ? _titleController.text : '校园生活';
    final subtitle = _subtitleController.text.isNotEmpty ? _subtitleController.text : '日常、宿舍、食堂、校园见闻';
    final desc = _descriptionController.text.isNotEmpty ? _descriptionController.text : '分享校园日常...';
    final btnText = _publishActionController.text.isNotEmpty ? _publishActionController.text : '发布帖子';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            _activeColor.withValues(alpha: isDark ? 0.2 : 0.1),
            _activeColor.withValues(alpha: isDark ? 0.05 : 0.02),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: _activeColor.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? Colors.white12 : Colors.white,
                  image: _avatarUrl != null && _avatarUrl!.isNotEmpty
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(
                              ApiConstants.fullUrl(_avatarUrl!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: _avatarUrl == null || _avatarUrl!.isEmpty
                    ? Icon(
                        iconKeyToIconData(widget.section.iconKey, fallbackSlug: widget.section.slug),
                        color: _activeColor,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF20232A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white70 : const Color(0xFF525A66),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black26 : Colors.white54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('预览', style: TextStyle(fontSize: 10, color: _activeColor, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            desc,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white60 : const Color(0xFF525A66),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _activeColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                btnText,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualCard(bool isDark) {
    return _buildCard(
      title: '视觉设置',
      isDark: isDark,
      children: [
        // 头像审核区块
        if (_isLoadingReview)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
        else if (_pendingIconReview != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFFFEDD5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    image: DecorationImage(
                      image: CachedNetworkImageProvider(ApiConstants.fullUrl(_pendingIconReview!.newAvatarUrl)),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '头像更新审核中',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.orange[300] : Colors.orange[800],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '您有一条更换版块头像的申请正在等待管理员审核。',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : const Color(0xFF525A66),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _cancelIconReview,
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('撤销申请'),
                ),
              ],
            ),
          )
        else
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white10 : const Color(0xFFF3F4F6),
                  shape: BoxShape.circle,
                  image: _avatarUrl != null && _avatarUrl!.isNotEmpty
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(ApiConstants.fullUrl(_avatarUrl!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                  border: Border.all(
                    color: isDark ? Colors.white12 : const Color(0xFFE5E7EB),
                  ),
                ),
                child: _avatarUrl == null || _avatarUrl!.isEmpty
                    ? Icon(Icons.image_outlined, color: isDark ? Colors.white38 : Colors.black26)
                    : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '版块头像',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF20232A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    OutlinedButton(
                      onPressed: _isUploadingAvatar ? null : _submitNewIcon,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _isUploadingAvatar
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('更换新头像', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        const SizedBox(height: 20),
        
        // 背景图
        Text(
          '版块背景图',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : const Color(0xFF20232A),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          height: 120,
          decoration: BoxDecoration(
            color: isDark ? Colors.white10 : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE5E7EB)),
            image: _coverLandscapeUrl != null && _coverLandscapeUrl!.isNotEmpty
                ? DecorationImage(
                    image: CachedNetworkImageProvider(ApiConstants.fullUrl(_coverLandscapeUrl!)),
                    fit: BoxFit.cover,
                  )
                : (_coverPortraitUrl != null && _coverPortraitUrl!.isNotEmpty
                    ? DecorationImage(
                        image: CachedNetworkImageProvider(ApiConstants.fullUrl(_coverPortraitUrl!)),
                        fit: BoxFit.cover,
                      )
                    : null),
          ),
          child: _coverLandscapeUrl == null || _coverLandscapeUrl!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wallpaper_outlined, color: isDark ? Colors.white38 : Colors.black26, size: 28),
                      const SizedBox(height: 4),
                      Text('未设置背景图', style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black38)),
                    ],
                  ),
                )
              : null,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '建议上传 16:9 或 3:4，系统自动适配',
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
            ),
            Row(
              children: [
                if (_coverPortraitUrl != null && _coverPortraitUrl!.isNotEmpty)
                  TextButton(
                    onPressed: _clearCover,
                    style: TextButton.styleFrom(foregroundColor: Colors.red, minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    child: const Text('清除', style: TextStyle(fontSize: 12)),
                  ),
                OutlinedButton(
                  onPressed: _isUploadingCover ? null : _pickAndUploadCover,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isUploadingCover
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('上传', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        
        // 主题色
        Text(
          '主题颜色',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : const Color(0xFF20232A),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _presetColors.map((hex) {
            final color = Color(int.parse(hex.substring(1), radix: 16) + 0xFF000000);
            final isSelected = _colorHex.toUpperCase() == hex.toUpperCase();
            return GestureDetector(
              onTap: () {
                setState(() {
                  _colorHex = hex;
                });
              },
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isSelected ? 0.2 : 1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? color : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Container(
                    width: isSelected ? 24 : 36,
                    height: isSelected ? 24 : 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildBasicInfoCard(bool isDark) {
    return _buildCard(
      title: '基础信息',
      isDark: isDark,
      children: [
        TextField(
          controller: _titleController,
          decoration: _inputDecoration('标题', isDark: isDark),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _subtitleController,
          decoration: _inputDecoration('副标题', isDark: isDark),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionController,
          maxLines: 3,
          decoration: _inputDecoration('说明', isDark: isDark),
        ),
        const SizedBox(height: 16),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              '高级设置',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF20232A),
              ),
            ),
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _iconKeyController,
                decoration: _inputDecoration('图标 Key (用于系统识别)', isDark: isDark),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPublishEmptyCard(bool isDark) {
    return _buildCard(
      title: '发布与空状态',
      isDark: isDark,
      children: [
        TextField(
          controller: _publishActionController,
          decoration: _inputDecoration('发帖按钮文案', isDark: isDark),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _emptyTitleController,
          decoration: _inputDecoration('空状态标题', isDark: isDark),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _emptyDescriptionController,
          maxLines: 2,
          decoration: _inputDecoration('空状态描述', isDark: isDark),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _noticeTextController,
          maxLines: 3,
          decoration: _inputDecoration('发布提醒', isDark: isDark),
        ),
      ],
    );
  }

  Widget _buildPromptQuestionsCard(bool isDark) {
    return _buildCard(
      title: '引导问题',
      subtitle: '每行一个，展示在空状态或发帖引导中',
      isDark: isDark,
      children: [
        TextField(
          controller: _starterQuestionsController,
          maxLines: 6,
          decoration: _inputDecoration('每行输入一个问题', isDark: isDark).copyWith(
            hintText: '食堂哪家强？\n宿舍怎么样？',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF111315) : const Color(0xFFF9FAFB);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF111315) : Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: const BackButton(),
        title: const Text(
          '编辑版块展示',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting 
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('保存', style: TextStyle(color: _activeColor, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  _buildPreviewCard(isDark),
                  _buildVisualCard(isDark),
                  _buildBasicInfoCard(isDark),
                  _buildPublishEmptyCard(isDark),
                  _buildPromptQuestionsCard(isDark),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF111315) : Colors.white,
                border: Border(
                  top: BorderSide(
                    color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFEDEFF3),
                  ),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: _activeColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text(
                          '保存展示设置',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
