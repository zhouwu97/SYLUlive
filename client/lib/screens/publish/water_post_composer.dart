import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../../config/privileged_accounts.dart';
import '../../config/water_post_taxonomy.dart';
import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
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
  final List<XFile> _selectedImages = [];
  final List<PostImage> _existingImages = [];

  // ---------------------------------------------------------------------------
  // PublishImagePickerMixin 抽象成员实现
  // ---------------------------------------------------------------------------

  @override
  List<XFile> get selectedImages => _selectedImages;

  @override
  List<PostImage> get existingImages => _existingImages;

  @override
  void onImageAdded(XFile image) => setState(() => _selectedImages.add(image));

  @override
  void onNewImageRemoved(int index) =>
      setState(() => _selectedImages.removeAt(index));

  @override
  void onExistingImageRemoved(int index) =>
      setState(() => _existingImages.removeAt(index));

  // ---------------------------------------------------------------------------
  // 辅助状态
  // ---------------------------------------------------------------------------

  bool get _isEditing => widget.editingPost != null;

  bool get _canUploadUnlimitedImages {
    final studentId = context.read<AuthProvider>().user?.studentId;
    return PrivilegedAccounts.canUploadUnlimitedImages(studentId);
  }

  int get _totalImageCount => _existingImages.length + _selectedImages.length;

  @override
  bool get canAddMoreImages =>
      _canUploadUnlimitedImages || _totalImageCount < _maxImages;

  int get _charCount => _contentController.text.length;

  bool get _hasImages => _totalImageCount > 0 || canAddMoreImages;

  String get _pageTitle => _isEditing ? '编辑水帖' : '发布水帖';

  WaterPostCategory get _selectedCategory =>
      waterCategoryOf(_selectedPostType) ?? waterCategoryOf('campus_life')!;

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
      _existingImages.addAll(post.images);
      _selectedPostType = isValidWaterPostCategory(post.postType)
          ? post.postType
          : 'campus_life';
    } else {
      _selectedPostType = isValidWaterPostCategory(widget.initialPostType)
          ? widget.initialPostType!
          : 'campus_life';
    }
    _titleController.addListener(_onTitleChanged);
    _contentController.addListener(_onContentChanged);
  }

  @override
  void dispose() {
    _titleController.removeListener(_onTitleChanged);
    _contentController.removeListener(_onContentChanged);
    _titleWarningController.dispose();
    _titleFocusNode.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onTitleChanged() {
    if (!_titleNeedsAttention || _titleController.text.trim().isEmpty) {
      return;
    }
    _titleWarningController.stop();
    _titleWarningController.reset();
    setState(() => _titleNeedsAttention = false);
  }

  void _onContentChanged() => setState(() {});

  // ---------------------------------------------------------------------------
  // 校验
  // ---------------------------------------------------------------------------

  bool _validate() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final isFormValid = _formKey.currentState!.validate();
    if (title.isEmpty) {
      _showTitleRequiredHint();
      return false;
    }
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

  void _showTitleRequiredHint() {
    if (!mounted) return;
    _titleFocusNode.requestFocus();
    setState(() => _titleNeedsAttention = true);
    _titleWarningController.forward(from: 0);
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

      final List<int> fileIds = [];
      bool hasUploadError = false;
      for (final image in _selectedImages) {
        final fileId = await postProvider.uploadImage(image.path);
        if (fileId != null) {
          fileIds.add(fileId);
        } else {
          hasUploadError = true;
          break;
        }
      }

      if (hasUploadError) {
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

      final mergedFileIds = [
        ..._existingImages.map((image) => image.fileId),
        ...fileIds,
      ];

      final result = _isEditing
          ? await postProvider.updatePost(
              postId: widget.editingPost!.id,
              boardId: 1,
              content: content,
              title: title,
              postType: _selectedPostType,
              price: 0,
              contact: '',
              fileIds: mergedFileIds,
            )
          : await postProvider.createPost(
              boardId: 1,
              content: content,
              title: title,
              postType: _selectedPostType,
              price: null,
              contact: null,
              fileIds: mergedFileIds.isNotEmpty ? mergedFileIds : null,
            );

      if (!mounted) return;
      if (result.success) {
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage ?? '发布失败'),
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

  // ---------------------------------------------------------------------------
  // 界面构建
  // ---------------------------------------------------------------------------

  Future<void> _showCategorySheet() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          itemCount: kWaterPostCategories.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '选择分类',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF16181D),
                  ),
                ),
              );
            }
            final category = kWaterPostCategories[index - 1];
            final selected = category.value == _selectedPostType;
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.of(context).pop(category.value),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: category.color.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        category.icon,
                        size: 17,
                        color: category.color,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            category.label,
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
                            category.hint,
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
                    if (selected)
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
      setState(() => _selectedPostType = selected);
    }
  }

  Widget _buildCategorySelector(bool isDark) {
    final category = _selectedCategory;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _showCategorySheet,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.06) : _softTeal,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Text(
                '分类',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : _teal,
                ),
              ),
              const Spacer(),
              Icon(category.icon, size: 22, color: _teal),
              const SizedBox(width: 8),
              Text(
                category.label,
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
                    existingImages: _existingImages,
                    selectedImages: _selectedImages,
                    canAddMore: canAddMoreImages,
                    onAddImage: showImageSourceDialog,
                    onRemoveNewImage: onNewImageRemoved,
                    onRemoveExistingImage: onExistingImageRemoved,
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
