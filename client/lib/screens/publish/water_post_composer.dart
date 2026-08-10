import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../../config/privileged_accounts.dart';
import '../../config/water_post_taxonomy.dart';
import '../../models/post.dart';
import '../../models/publish_image_item.dart';
import '../../models/water_section.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import '../../providers/water_section_provider.dart';
import '../../services/post_draft_service.dart';
import '../../widgets/water_section/section_avatar.dart';
import 'widgets/publish_image_grid.dart';
import 'widgets/publish_image_picker.dart';
import 'widgets/water_post_bottom_bar.dart';

/// 水帖发布/编辑页（boardId == 1）。
///
/// 采用全屏编辑布局：顶部标题，中间正文自适应填充，底部保留图片和发布工具栏。
class WaterPostComposer extends StatefulWidget {
  final Post? editingPost;
  final String? initialPostType;

  const WaterPostComposer({super.key, this.editingPost, this.initialPostType});

  @override
  State<WaterPostComposer> createState() => _WaterPostComposerState();
}

class _WaterPostComposerState extends State<WaterPostComposer>
    with SingleTickerProviderStateMixin, PublishImagePickerMixin {
  static const _maxImages = 9;
  static const _maxContentLength = 2000;
  static const Color _teal = Color(0xFF12B8A6);
  static const Color _softTeal = Color(0xFFEAFBF8);
  static const Color _hintLight = Color(0xFFA7ABB2);
  static const Color _dividerLight = Color(0xFFE1E4E8);
  static const Color _titleWarning = Color(0xFFE5484D);
  static const double _titleFontSize = 18.5;
  static const double _contentFontSize = 14.5;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _titleFocusNode = FocusNode();
  late final AnimationController _titleWarningController;
  bool _isLoading = false;
  bool _titleNeedsAttention = false;
  String _selectedPostType = 'campus_life';
  int? _selectedTagId;

  // C-2 统一图片列表（existing + local 混合，顺序即发布顺序）。
  final List<PublishImageItem> _images = [];
  int _localImageSeq = 0;

  String _nextLocalImageId() {
    _localImageSeq++;
    return 'local-${DateTime.now().millisecondsSinceEpoch}-$_localImageSeq';
  }

  // C-1 草稿：防抖自动保存，发布成功清理。
  final PostDraftService _draftService = PostDraftService();
  Timer? _draftDebounce;
  static const Duration _draftDebounceDuration = Duration(milliseconds: 800);

  // ---------------------------------------------------------------------------
  // PublishImagePickerMixin 抽象成员实现
  // ---------------------------------------------------------------------------

  @override
  void onImageAdded(XFile image) {
    _scheduleDraftSave();
    setState(() => _images.add(PublishImageItem.local(image, _nextLocalImageId())));
  }

  // ---------------------------------------------------------------------------
  // 辅助状态
  // ---------------------------------------------------------------------------

  bool get _isEditing => widget.editingPost != null;

  bool get _canUploadUnlimitedImages {
    final studentId = context.read<AuthProvider>().user?.studentId;
    return PrivilegedAccounts.canUploadUnlimitedImages(studentId);
  }

  int get _totalImageCount => _images.length;

  @override
  bool get canAddMoreImages =>
      _canUploadUnlimitedImages || _totalImageCount < _maxImages;

  // ---- 统一图片操作 ----

  void _removeImage(String id) {
    _scheduleDraftSave();
    setState(() => _images.removeWhere((e) => e.id == id));
  }

  /// 拖拽排序：把 dragged 移到 target 所在位置（语义见 reorderImages）。
  void _moveImage(String draggedId, String targetId) {
    reorderImages(_images, draggedId, targetId);
    _scheduleDraftSave();
    setState(() {});
  }

  /// 上传所有本地图（并发 ≤3），更新每个 item 的 uploadState / progress / fileId。
  /// 全部成功返回 true；任一失败返回 false（失败项留在 failed 态，可重试）。
  Future<bool> _uploadLocalImages(PostProvider postProvider) {
    return uploadImagesConcurrently(
      _images,
      maxConcurrent: 3,
      upload: (item) => postProvider.uploadImage(
        item.localFile!,
        onProgress: (sent, total) {
          if (total > 0) {
            item.progress = sent / total;
            if (mounted) setState(() {});
          }
        },
      ),
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// 重试单个失败图片：清空 fileId，置为 waiting，下次提交时重新上传。
  void _retryImage(String id) {
    for (final item in _images) {
      if (item.id == id && item.source == PublishImageSource.local) {
        item.fileId = null;
        item.uploadState = PublishImageUploadState.waiting;
        item.progress = 0;
      }
    }
    setState(() {});
  }

  /// 按 UI 顺序组装 file_ids（上传完成后调用；未成功上传的 local 返回 null）。
  List<int>? _orderedFileIds() {
    final fileIds = <int>[];
    for (final item in _images) {
      switch (item.source) {
        case PublishImageSource.existing:
          fileIds.add(item.existingImage!.fileId);
        case PublishImageSource.local:
          if (item.fileId == null) return null;
          fileIds.add(item.fileId!);
      }
    }
    return fileIds;
  }

  int get _charCount => _contentController.text.length;

  bool get _hasImages => _totalImageCount > 0 || canAddMoreImages;

  String get _pageTitle => _isEditing ? '编辑水帖' : '发布水帖';

  String _userFacingPostError(String? message) {
    final text = message ?? (_isEditing ? '更新失败' : '发布失败');
    if (text.contains('禁言')) {
      final action = _isEditing ? '编辑' : '发布';
      return '$text\n如认为禁言有误，可在通知中查看处理原因，并联系版块管理员申诉。解除后可继续$action。';
    }
    return text;
  }

  WaterPostCategory get _selectedCategory =>
      waterCategoryOf(_selectedPostType) ?? waterCategoryOf('campus_life')!;

  WaterSection get _selectedSection {
    final provider = context.read<WaterSectionProvider>();
    final fromProvider = provider.getBySlug(_selectedPostType);
    if (fromProvider != null) return fromProvider;
    final legacy = _selectedCategory;
    return WaterSection.fromLegacyCategory(legacy);
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _titleWarningController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _titleNeedsAttention = false);
          _titleWarningController.reset();
        }
      });
    final post = widget.editingPost;
    if (post != null) {
      _titleController.text = post.title;
      _contentController.text = post.content;
      _images.addAll(post.images.map(PublishImageItem.existing));
      _selectedTagId = post.waterTagId;
    }
    final rawPostType = post?.postType ?? widget.initialPostType;
    _selectedPostType = rawPostType != null && rawPostType.trim().isNotEmpty
        ? rawPostType.trim()
        : 'campus_life';
    _titleController.addListener(_onTitleChanged);
    _contentController.addListener(_onContentChanged);
    if (!_isEditing) {
      unawaited(_restoreDraft());
    }
    // 加载版块列表供标签选择
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<WaterSectionProvider>();
      if (provider.sections.isEmpty) provider.loadSections();
    });
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    unawaited(_persistDraft()); // 退出前落盘当前草稿（编辑态不保存）
    _titleController.removeListener(_onTitleChanged);
    _contentController.removeListener(_onContentChanged);
    _titleWarningController.dispose();
    _titleFocusNode.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onTitleChanged() {
    _scheduleDraftSave();
    if (!_titleNeedsAttention || _titleController.text.trim().isEmpty) {
      return;
    }
    _titleWarningController.stop();
    _titleWarningController.reset();
    setState(() => _titleNeedsAttention = false);
  }

  void _onContentChanged() {
    _scheduleDraftSave();
    setState(() {});
  }

  // ── C-1 草稿 ─────────────────────────────────────────────────────

  Future<void> _restoreDraft() async {
    final draft = await _draftService.load();
    if (draft == null || draft.isEmpty || !mounted) return;
    if (_titleController.text.isEmpty) {
      _titleController.text = draft.title;
    }
    if (_contentController.text.isEmpty) {
      _contentController.text = draft.content;
    }
    if (_selectedPostType == 'campus_life' && draft.postType.isNotEmpty) {
      _selectedPostType = draft.postType;
    }
    _selectedTagId ??= draft.waterTagId;
    for (final path in draft.draftImagePaths) {
      final file = File(path);
      if (await file.exists()) {
        _images.add(PublishImageItem.local(XFile(path), _nextLocalImageId()));
      }
    }
    if (mounted) setState(() {});
  }

  /// 防抖自动保存草稿（标题/正文/图片变化时调用）。
  void _scheduleDraftSave() {
    if (_isEditing) return;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(_draftDebounceDuration, _persistDraft);
  }

  Future<void> _persistDraft() async {
    if (_isEditing) return;
    final draft = PostDraft(
      title: _titleController.text.trim(),
      content: _contentController.text.trim(),
      postType: _selectedPostType,
      waterTagId: _selectedTagId,
      draftImagePaths: _images
          .where((e) => e.source == PublishImageSource.local)
          .map((e) => e.localFile!.path)
          .toList(),
      updatedAt: DateTime.now(),
    );
    if (draft.isEmpty) {
      await _draftService.clear();
      return;
    }
    await _draftService.save(draft);
  }

  // ---------------------------------------------------------------------------
  // 校验
  // ---------------------------------------------------------------------------

  bool _validate() {
    final content = _contentController.text.trim();
    final isFormValid = _formKey.currentState!.validate();
    // C-1：标题可选，正文 required。
    if (content.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('写点内容再发布吧'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
    if (content.length > _maxContentLength) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('正文最多 2000 字'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
    return isFormValid;
  }

  // ---------------------------------------------------------------------------
  // 提交
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_isLoading) return;
    if (!_validate()) return;

    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    if (mounted) setState(() => _isLoading = true);

    try {
      final postProvider = context.read<PostProvider>();

      // C-3：并发上传本地图（失败项可重试，不提交）。
      if (!await _uploadLocalImages(postProvider)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('图片上传失败，请点击图片重试'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // C-2：file_ids 严格等于 UI 图片顺序（existing + local 混合）。
      final fileIds = _orderedFileIds();
      if (fileIds == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('图片上传失败，请检查网络或图片是否过大'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final result = _isEditing
          ? await postProvider.updatePost(
              postId: widget.editingPost!.id,
              boardId: 1,
              content: content,
              title: title,
              postType: _selectedPostType,
              waterTagId: _selectedTagId,
              price: 0,
              contact: '',
              fileIds: fileIds,
            )
          : await postProvider.createPost(
              boardId: 1,
              content: content,
              title: title,
              postType: _selectedPostType,
              waterTagId: _selectedTagId,
              price: null,
              contact: null,
              fileIds: fileIds.isNotEmpty ? fileIds : null,
            );

      if (!mounted) return;
      if (result.success) {
        _draftDebounce?.cancel();
        unawaited(_draftService.clear()); // 发布成功清理草稿
        _showSubmitSuccessFeedback(result.post);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_userFacingPostError(result.errorMessage)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发布失败：$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  ExpAward? _firstAwardWhere(
    List<ExpAward> awards,
    bool Function(ExpAward award) test,
  ) {
    for (final award in awards) {
      if (test(award)) return award;
    }
    return null;
  }

  void _showSubmitSuccessFeedback(Post? post) {
    final awards = post?.expAwards ?? const <ExpAward>[];
    final globalAward = _firstAwardWhere(awards, (a) => a.scope == 'global');
    final sectionAward =
        _firstAwardWhere(awards, (a) => a.scope == 'water_section');
    final lines = <String>[_isEditing ? '保存成功' : '发布成功'];

    final expParts = <String>[];
    if (globalAward != null && globalAward.exp > 0) {
      expParts.add('全站经验 +${globalAward.exp}');
    }
    if (sectionAward != null && sectionAward.exp > 0) {
      final sectionName = sectionAward.sectionTitle.isNotEmpty
          ? sectionAward.sectionTitle
          : _selectedSection.title;
      expParts.add('$sectionName经验 +${sectionAward.exp}');
    }
    if (expParts.isNotEmpty) {
      lines.add(expParts.join(' · '));
    }
    if (sectionAward != null && sectionAward.levelUp) {
      final sectionName = sectionAward.sectionTitle.isNotEmpty
          ? sectionAward.sectionTitle
          : _selectedSection.title;
      final title = sectionAward.titleAfter.isNotEmpty
          ? '「${sectionAward.titleAfter}」'
          : '';
      lines.add('$sectionName升级到 Lv.${sectionAward.levelAfter}$title');
    } else if (globalAward != null && globalAward.levelUp) {
      lines.add('全站等级升级到 Lv.${globalAward.levelAfter}');
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lines.first,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final line in lines.skip(1)) ...[
              const SizedBox(height: 2),
              Text(line),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 界面构建
  // ---------------------------------------------------------------------------

  Future<void> _showCategorySheet() async {
    final provider = context.read<WaterSectionProvider>();
    final sections = provider.sections.isNotEmpty
        ? provider.activeSections
        : kWaterPostCategories.map(WaterSection.fromLegacyCategory).toList();
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          itemCount: sections.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '选择版块',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF16181D),
                  ),
                ),
              );
            }
            final sec = sections[index - 1];
            final isSelected = sec.slug == _selectedPostType;
            final color = colorHexToColor(sec.colorHex, fallback: Colors.teal);
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.of(context).pop(sec.slug),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                child: Row(
                  children: [
                    SectionAvatar(
                      section: sec,
                      size: 30,
                      radius: 30, // make it circular
                      accentColor: color,
                      isDark: isDark,
                      showBorder: true,
                      borderColor: color.withValues(alpha: 0.15),
                      borderWidth: 1,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sec.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF20232A),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            sec.subtitle.isNotEmpty
                                ? sec.subtitle
                                : sec.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? Colors.white54
                                  : const Color(0xFF7B818C),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(
                        Icons.check_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedPostType = selected;
        _selectedTagId = null;
      });
    }
  }

  Widget _buildCategorySelector(bool isDark) {
    final section = _selectedSection;
    final color =
        section.colorHex.isNotEmpty ? colorHexToColor(section.colorHex) : _teal;
    final tags = section.enabledTags
        .where((tag) => !tag.isTeamRecruitment)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _showCategorySheet,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.06) : _softTeal,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '版块',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : _teal,
                    ),
                  ),
                  const Spacer(),
                  SectionAvatar(
                    section: section,
                    size: 24,
                    radius: 8,
                    accentColor: color,
                    isDark: isDark,
                    showBorder: true,
                    borderColor: color.withValues(alpha: 0.15),
                    borderWidth: 1,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    section.title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : const Color(0xFF20232A),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: _teal,
                  ),
                ],
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: tags.map((tag) {
                    final selected = _selectedTagId == tag.id;
                    return GestureDetector(
                      onTap: () {
                        setState(
                            () => _selectedTagId = selected ? null : tag.id);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: selected
                              ? color.withValues(alpha: 0.2)
                              : color.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(999),
                          border: selected
                              ? Border.all(color: color.withValues(alpha: 0.4))
                              : null,
                        ),
                        child: Text(
                          tag.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                selected ? FontWeight.w800 : FontWeight.w500,
                            color: selected
                                ? color
                                : (isDark
                                    ? Colors.white60
                                    : const Color(0xFF667085)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
              if (section.noticeText.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 14,
                        color: section.isSensitive
                            ? Colors.orange.shade600
                            : color),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        section.noticeText,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color:
                              isDark ? Colors.white60 : const Color(0xFF7B818C),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (section.isSensitive) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.privacy_tip_outlined,
                        size: 14, color: Colors.orange.shade600),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '该版块内容更容易触发管理审核，请避免泄露隐私、攻击他人或发布无法核实的信息。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: isDark
                              ? Colors.orange.shade200
                              : Colors.orange.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0D1117) : Colors.white,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 58,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          color: _teal,
          iconSize: 28,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          _pageTitle,
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: true,
      ),
      bottomNavigationBar: _buildBottomArea(isDark),
      body: SafeArea(
        bottom: false,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildCategorySelector(isDark),
              AnimatedBuilder(
                animation: _titleWarningController,
                builder: (context, child) {
                  final offset = _titleNeedsAttention
                      ? math.sin(_titleWarningController.value * math.pi * 6) *
                          6
                      : 0.0;
                  return Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: TextFormField(
                    controller: _titleController,
                    focusNode: _titleFocusNode,
                    decoration: InputDecoration(
                      hintText: '添加标题',
                      hintStyle: TextStyle(
                        color:
                            _titleNeedsAttention ? _titleWarning : _hintLight,
                        fontSize: _titleFontSize,
                        fontWeight: FontWeight.w500,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    style: TextStyle(
                      fontSize: _titleFontSize,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, color: _dividerLight),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextFormField(
                    controller: _contentController,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(_maxContentLength),
                    ],
                    decoration: const InputDecoration(
                      hintText: '分享校园生活、提问或记录此时此刻···',
                      hintStyle: TextStyle(
                        color: _hintLight,
                        fontSize: _contentFontSize,
                        fontWeight: FontWeight.w500,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.only(top: 28),
                      errorStyle: TextStyle(fontSize: 13),
                    ),
                    style: TextStyle(
                      fontSize: _contentFontSize,
                      height: 1.55,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.82)
                          : const Color(0xFF333333),
                    ),
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                  ),
                ),
              ),
              if (_hasImages)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                  child: PublishImageGrid(
                    images: _images,
                    canAddMore: canAddMoreImages,
                    onAdd: showImageSourceDialog,
                    onRemove: _removeImage,
                    onReorder: _moveImage,
                    onRetry: _retryImage,
                    compact: true,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomArea(bool isDark) {
    return WaterPostBottomBar(
      isLoading: _isLoading,
      imageCount: _totalImageCount,
      maxImages: _maxImages,
      charCount: _charCount,
      maxContentLength: _maxContentLength,
      publishLabel: _isEditing ? '保存修改' : '发布',
      onPublish: _isLoading ? null : _submit,
    );
  }
}
