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
import '../../models/topic.dart';
import '../../models/water_section.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import '../../providers/water_section_provider.dart';
import '../../services/post_draft_service.dart';
import '../../services/topic_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/water_section/section_avatar.dart';
import 'widgets/publish_image_picker.dart';
import 'widgets/publish_media_section.dart';
import 'widgets/publish_section_selector.dart';
import 'widgets/publish_topic_section.dart';
import 'widgets/topic_picker_sheet.dart';
import 'widgets/water_post_bottom_bar.dart';

class _PublishSessionChanged implements Exception {
  const _PublishSessionChanged();
}

/// 水帖发布/编辑页（boardId == 1）。
///
/// 采用整体滚动编辑布局：顶部标题、正文、话题与媒体顺序自然延展。
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
  static const _maxTopics = 5;
  static const _maxContentLength = 2000;
  static const Color _hintLight = Color(0xFFA7ABB2);
  static const Color _titleWarning = Color(0xFFE5484D);
  static const double _titleFontSize = 18;
  static const double _contentFontSize = 15;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _titleFocusNode = FocusNode();
  late final AnimationController _titleWarningController;
  bool _isLoading = false;
  bool _titleNeedsAttention = false;
  String _selectedPostType = 'campus_life';
  int? _selectedTagId;
  bool _hasExplicitInitialPostType = false;

  late final TopicService _topicService;
  final List<TopicSelection> _selectedTopics = [];
  List<Topic> _recommendedTopics = const [];
  bool _topicLoading = false;
  Timer? _topicDebounce;
  String _lastTopicQuery = '';
  int _topicRequestGeneration = 0;

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

  // 发布成功后禁止 dispose/定时器再次把已发布内容写回草稿。
  bool _draftPersistenceDisabled = false;
  Future<void>? _draftWriteInFlight;

  // ---------------------------------------------------------------------------
  // PublishImagePickerMixin 抽象成员实现
  // ---------------------------------------------------------------------------

  @override
  void onImageAdded(XFile image) {
    _scheduleDraftSave();
    setState(
        () => _images.add(PublishImageItem.local(image, _nextLocalImageId())));
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
  Future<bool> _uploadLocalImages(
    PostProvider postProvider, {
    required AuthProvider auth,
    required int accountId,
    required int accountSessionEpoch,
  }) {
    return uploadImagesConcurrently(
      _images,
      maxConcurrent: 3,
      upload: (item) async {
        _ensurePublishSession(auth, accountId, accountSessionEpoch);
        final fileId = await postProvider.uploadImage(
          item.localFile!,
          onProgress: (sent, total) {
            if (total > 0 &&
                _ownsPublishSession(auth, accountId, accountSessionEpoch)) {
              item.progress = sent / total;
              if (mounted) setState(() {});
            }
          },
        );
        _ensurePublishSession(auth, accountId, accountSessionEpoch);
        return fileId;
      },
      onStateChanged: () {
        if (mounted &&
            _ownsPublishSession(auth, accountId, accountSessionEpoch)) {
          setState(() {});
        }
      },
    );
  }

  bool _ownsPublishSession(
    AuthProvider auth,
    int accountId,
    int accountSessionEpoch,
  ) {
    return auth.user?.id == accountId &&
        auth.accountSessionEpoch == accountSessionEpoch;
  }

  void _ensurePublishSession(
    AuthProvider auth,
    int accountId,
    int accountSessionEpoch,
  ) {
    if (!_ownsPublishSession(auth, accountId, accountSessionEpoch)) {
      throw const _PublishSessionChanged();
    }
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
    _topicService = TopicService(context.read<AuthProvider>().dio);
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
    _hasExplicitInitialPostType =
        post != null || (widget.initialPostType?.trim().isNotEmpty ?? false);
    if (post != null) {
      _titleController.text = post.title;
      _contentController.text = post.content;
      _images.addAll(post.images.map(PublishImageItem.existing));
      // 普通 Composer 不再暴露 legacy WaterTag；编辑旧帖时一并清空。
      _selectedTagId = null;
      _selectedTopics.addAll(
        post.topics.map(
          (topic) => TopicSelection.existing(id: topic.id, name: topic.name),
        ),
      );
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
    _scheduleTopicRecommendationRefresh();
    // 加载版块列表供标签选择
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<WaterSectionProvider>();
      if (provider.sections.isEmpty) provider.loadSections();
    });
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _topicDebounce?.cancel();
    _topicRequestGeneration++;
    if (!_draftPersistenceDisabled) {
      unawaited(_persistDraft()); // 普通退出仍保留当前草稿
    }
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
    _scheduleTopicRecommendationRefresh();
    if (!_titleNeedsAttention || _titleController.text.trim().isEmpty) {
      return;
    }
    _titleWarningController.stop();
    _titleWarningController.reset();
    setState(() => _titleNeedsAttention = false);
  }

  void _onContentChanged() {
    _scheduleDraftSave();
    _scheduleTopicRecommendationRefresh();
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
    if (!_hasExplicitInitialPostType && draft.postType.isNotEmpty) {
      _selectedPostType = draft.postType;
    }
    // 兼容旧草稿结构，但不把普通 WaterTag 恢复到新 Composer。
    _selectedTagId = null;
    _selectedTopics
      ..clear()
      ..addAll(draft.topics);
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
    if (_isEditing || _draftPersistenceDisabled) return;
    final write = _writeDraft();
    _draftWriteInFlight = write;
    try {
      await write;
    } finally {
      if (identical(_draftWriteInFlight, write)) {
        _draftWriteInFlight = null;
      }
    }
  }

  Future<void> _handleBack() async {
    if (_isLoading) return;
    _draftDebounce?.cancel();
    await _persistDraft();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _writeDraft() async {
    final draft = PostDraft(
      title: _titleController.text.trim(),
      content: _contentController.text.trim(),
      postType: _selectedPostType,
      waterTagId: _selectedTagId,
      topics: List<TopicSelection>.unmodifiable(_selectedTopics),
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

  void _scheduleTopicRecommendationRefresh({bool immediate = false}) {
    _topicDebounce?.cancel();
    final delay = immediate ? Duration.zero : const Duration(milliseconds: 500);
    _topicDebounce = Timer(delay, _refreshTopicRecommendations);
  }

  Future<void> _refreshTopicRecommendations() async {
    final rawQuery =
        '${_titleController.text.trim()} ${_contentController.text.trim()}'
            .trim();
    final query = rawQuery.runes.length < 4 ? '' : rawQuery;
    if (query == _lastTopicQuery && _recommendedTopics.isNotEmpty) return;
    final requestGeneration = ++_topicRequestGeneration;
    final section = _selectedPostType;
    _lastTopicQuery = query;
    if (mounted) setState(() => _topicLoading = true);
    try {
      final topics = await _topicService.recommend(
        query: query,
        section: section,
        limit: 8,
      );
      if (!mounted ||
          requestGeneration != _topicRequestGeneration ||
          section != _selectedPostType) {
        return;
      }
      setState(() {
        _recommendedTopics = topics;
      });
    } catch (_) {
      // 推荐是增强能力；失败时保留已有推荐或空态，不打扰发帖。
    } finally {
      if (mounted && requestGeneration == _topicRequestGeneration) {
        setState(() => _topicLoading = false);
      }
    }
  }

  void _addTopic(TopicSelection selection) {
    if (_selectedTopics.any(
        (item) => item.id == selection.id && item.name == selection.name)) {
      return;
    }
    if (_selectedTopics.length >= 5) {
      AppFeedback.error('最多选择 5 个话题', context: context);
      return;
    }
    setState(() => _selectedTopics.add(selection));
    _scheduleDraftSave();
  }

  void _removeTopic(TopicSelection selection) {
    setState(() => _selectedTopics.remove(selection));
    _scheduleDraftSave();
  }

  Future<void> _openTopicPicker() async {
    final result = await showTopicPickerSheet(
      context,
      service: _topicService,
      section: _selectedPostType,
      recommendedTopics: _recommendedTopics,
      selectedTopics: _selectedTopics,
      maxTopics: _maxTopics,
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedTopics
        ..clear()
        ..addAll(result);
    });
    _scheduleDraftSave();
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
        AppFeedback.error('写点内容再发布吧', context: context);
      }
      return false;
    }
    if (content.length > _maxContentLength) {
      if (mounted) {
        AppFeedback.error('正文最多 2000 字', context: context);
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

    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    if (accountId == null || accountId <= 0) {
      AppFeedback.error('请先登录后再发布', context: context);
      return;
    }
    final accountSessionEpoch = auth.accountSessionEpoch;
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    if (mounted) setState(() => _isLoading = true);

    try {
      final postProvider = context.read<PostProvider>();

      // C-3：并发上传本地图（失败项可重试，不提交）。
      if (!await _uploadLocalImages(
        postProvider,
        auth: auth,
        accountId: accountId,
        accountSessionEpoch: accountSessionEpoch,
      )) {
        if (mounted) {
          AppFeedback.error('图片上传失败，请点击图片重试', context: context);
        }
        return;
      }
      _ensurePublishSession(auth, accountId, accountSessionEpoch);

      // C-2：file_ids 严格等于 UI 图片顺序（existing + local 混合）。
      final fileIds = _orderedFileIds();
      if (fileIds == null) {
        if (mounted) {
          AppFeedback.error(
            '图片上传失败，请检查网络或图片是否过大',
            context: context,
          );
        }
        return;
      }

      _ensurePublishSession(auth, accountId, accountSessionEpoch);
      final result = _isEditing
          ? await postProvider.updatePost(
              postId: widget.editingPost!.id,
              boardId: 1,
              content: content,
              title: title,
              postType: _selectedPostType,
              waterTagId: _selectedTagId,
              topics: List<TopicSelection>.unmodifiable(_selectedTopics),
              price: 0,
              contact: '',
              fileIds: fileIds,
              sendWaterTagField: true,
            )
          : await postProvider.createPost(
              boardId: 1,
              content: content,
              title: title,
              postType: _selectedPostType,
              waterTagId: _selectedTagId,
              topics: List<TopicSelection>.unmodifiable(_selectedTopics),
              price: null,
              contact: null,
              fileIds: fileIds.isNotEmpty ? fileIds : null,
            );

      _ensurePublishSession(auth, accountId, accountSessionEpoch);
      if (!mounted) return;
      if (result.success) {
        _draftDebounce?.cancel();

        final pendingWrite = _draftWriteInFlight;
        if (pendingWrite != null) {
          try {
            await pendingWrite;
          } catch (_) {
            // 草稿写入失败不应阻断已成功的帖子发布；下面仍执行清理。
          }
        }
        _ensurePublishSession(auth, accountId, accountSessionEpoch);
        _draftPersistenceDisabled = true;
        await _draftService.clear();

        _ensurePublishSession(auth, accountId, accountSessionEpoch);
        final successMessage = _submitSuccessMessage(result.post);
        if (!mounted) return;
        Navigator.of(context).pop(true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          AppFeedback.success(successMessage);
        });
      } else {
        AppFeedback.error(
          _userFacingPostError(result.errorMessage),
          context: context,
        );
      }
    } on _PublishSessionChanged {
      if (mounted) {
        AppFeedback.error(
          '登录状态已变化，本次发布已取消，请重新确认',
          context: context,
        );
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.error('发布失败：$e', context: context);
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

  String _submitSuccessMessage(Post? post) {
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

    return lines.join('\n');
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
      _scheduleDraftSave();
      _scheduleTopicRecommendationRefresh(immediate: true);
    }
  }

  Widget _buildCategorySelector() {
    return PublishSectionSelector(
      section: _selectedSection,
      onTap: _showCategorySheet,
    );
  }

  Widget _buildTopicEditor() {
    return PublishTopicSection(
      selectedTopics: _selectedTopics,
      recommendedTopics: _recommendedTopics,
      loading: _topicLoading,
      maxTopics: _maxTopics,
      onAdd: _openTopicPicker,
      onRemove: _removeTopic,
      onSelectRecommendation: _addTopic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? AppColors.surfacePrimaryDark : AppColors.surfacePrimaryLight,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 56,
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back_rounded),
          color: AppColors.brandPrimary,
          iconSize: 26,
          onPressed: _handleBack,
        ),
        title: Text(
          _pageTitle,
          style: TextStyle(
            color:
                isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      bottomNavigationBar: _buildBottomArea(),
      body: SafeArea(
        bottom: false,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCategorySelector(),
                AnimatedBuilder(
                  animation: _titleWarningController,
                  builder: (context, child) {
                    final offset = _titleNeedsAttention
                        ? math.sin(
                                _titleWarningController.value * math.pi * 6) *
                            6
                        : 0.0;
                    return Transform.translate(
                      offset: Offset(offset, 0),
                      child: child,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.xl,
                      AppSpacing.lg,
                      0,
                    ),
                    child: TextFormField(
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      decoration: InputDecoration(
                        hintText: '添加标题（选填）',
                        hintStyle: TextStyle(
                          color:
                              _titleNeedsAttention ? _titleWarning : _hintLight,
                          fontSize: _titleFontSize,
                          fontWeight: FontWeight.w600,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                      ),
                      style: TextStyle(
                        fontSize: _titleFontSize,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimaryLight,
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Divider(
                    height: 1,
                    color: isDark
                        ? AppColors.composerDividerDark
                        : AppColors.composerDividerLight,
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
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
                      contentPadding: EdgeInsets.only(top: AppSpacing.lg),
                      errorStyle: TextStyle(fontSize: 13),
                    ),
                    style: TextStyle(
                      fontSize: _contentFontSize,
                      height: 1.55,
                      color: isDark
                          ? AppColors.textPrimaryDark
                          : AppColors.textPrimaryLight,
                    ),
                    minLines: 6,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                  ),
                ),
                _buildTopicEditor(),
                PublishMediaSection(
                  images: _images,
                  canAddMore: canAddMoreImages,
                  maxImages: _maxImages,
                  onAdd: showImageSourceDialog,
                  onRemove: _removeImage,
                  onReorder: _moveImage,
                  onRetry: _retryImage,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomArea() {
    return WaterPostBottomBar(
      isLoading: _isLoading,
      charCount: _charCount,
      maxContentLength: _maxContentLength,
      publishLabel: _isEditing ? '保存修改' : '发布',
      onPublish: _isLoading ? null : _submit,
    );
  }
}
