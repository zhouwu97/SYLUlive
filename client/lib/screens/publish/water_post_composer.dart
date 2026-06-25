import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/privileged_accounts.dart';
import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import 'widgets/publish_bottom_bar.dart';
import 'widgets/publish_image_grid.dart';
import 'widgets/publish_image_picker.dart';

/// Full-screen water-post composer (boardId == 1).
///
/// Uses a full-screen editor layout: title at top, content filling remaining
/// space, images below content.
class WaterPostComposer extends StatefulWidget {
  final Post? editingPost;

  const WaterPostComposer({super.key, this.editingPost});

  @override
  State<WaterPostComposer> createState() => _WaterPostComposerState();
}

class _WaterPostComposerState extends State<WaterPostComposer>
    with PublishImagePickerMixin {
  static const _maxImages = 9;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  bool _isLoading = false;
  final List<XFile> _selectedImages = [];
  final List<PostImage> _existingImages = [];

  // ---------------------------------------------------------------------------
  // PublishImagePickerMixin abstract impl
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
  // Helpers
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

  String get _pageTitle => _isEditing ? '编辑帖子' : '发布水帖';

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    final post = widget.editingPost;
    if (post != null) {
      _titleController.text = post.title;
      _contentController.text = post.content;
      _existingImages.addAll(post.images);
    }
    _contentController.addListener(_onContentChanged);
  }

  @override
  void dispose() {
    _contentController.removeListener(_onContentChanged);
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onContentChanged() => setState(() {});

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  bool _validate() {
    if (!_formKey.currentState!.validate()) return false;
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请输入内容'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Submit
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
              postType: '',
              price: 0,
              contact: '',
              fileIds: mergedFileIds,
            )
          : await postProvider.createPost(
              boardId: 1,
              content: content,
              title: title.isNotEmpty ? title : null,
              postType: null,
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
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0D1117) : const Color(0xFFFEFEFE),
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(_pageTitle),
        leading: const BackButton(),
      ),
      bottomNavigationBar: _buildBottomArea(isDark),
      body: SafeArea(
        bottom: false,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- title: lightweight, no border ----
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    hintText: '添加标题（选填）',
                    hintStyle: TextStyle(
                      color: Colors.grey,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                ),
              ),
              const Divider(height: 1),

              // ---- content: fills all remaining space ----
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextFormField(
                    controller: _contentController,
                    decoration: const InputDecoration(
                      hintText: '分享校园生活、提问或记录此刻…',
                      hintStyle: TextStyle(color: Colors.grey, fontSize: 15),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.only(top: 12),
                    ),
                    style: const TextStyle(fontSize: 15, height: 1.6),
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    validator: (v) => (v ?? '').trim().isEmpty ? '请输入内容' : null,
                  ),
                ),
              ),

              // ---- images (below content, only when present) ----
              if (_hasImages)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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

  // ---------------------------------------------------------------------------
  // Bottom area: status row + full-width publish button
  // ---------------------------------------------------------------------------

  Widget _buildBottomArea(bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // status row
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0D1117) : const Color(0xFFFEFEFE),
            border: Border(
              top: BorderSide(
                color: Colors.black.withValues(alpha: 0.05),
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '图片 $_totalImageCount/$_maxImages',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.withValues(alpha: 0.7),
                ),
              ),
              Text(
                '$_charCount 字',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        // full-width publish button
        PublishBottomBar(
          isLoading: _isLoading,
          onPressed: _isLoading ? null : _submit,
          label: _isEditing ? '保存修改' : '发布',
        ),
      ],
    );
  }
}
