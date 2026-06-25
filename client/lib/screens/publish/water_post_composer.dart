import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/privileged_accounts.dart';
import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import 'widgets/publish_image_grid.dart';
import 'widgets/publish_image_picker.dart';

/// Full-screen water-post composer (boardId == 1).
class WaterPostComposer extends StatefulWidget {
  final Post? editingPost;

  const WaterPostComposer({super.key, this.editingPost});

  @override
  State<WaterPostComposer> createState() => _WaterPostComposerState();
}

class _WaterPostComposerState extends State<WaterPostComposer>
    with PublishImagePickerMixin {
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
      _canUploadUnlimitedImages || _totalImageCount < 9;

  String get _pageTitle => _isEditing ? '编辑帖子' : '发布水贴';

  String get _addButtonLabel {
    if (_canUploadUnlimitedImages) {
      return _selectedImages.isEmpty ? '添加图片' : '继续添加';
    }
    return _selectedImages.isEmpty ? '添加图片（最多9张）' : '继续添加';
  }

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
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_isLoading) return;

    if (_contentController.text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入内容')));
      }
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    final postProvider = context.read<PostProvider>();

    // upload images one by one (preserving original serial upload order)
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
        setState(() => _isLoading = false);
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
            content: _contentController.text,
            title: _titleController.text,
            postType: '',
            price: 0,
            contact: '',
            fileIds: mergedFileIds,
          )
        : await postProvider.createPost(
            boardId: 1,
            content: _contentController.text,
            title:
                _titleController.text.isNotEmpty ? _titleController.text : null,
            postType: null,
            price: null,
            contact: null,
            fileIds: mergedFileIds.isNotEmpty ? mergedFileIds : null,
          );

    if (mounted) setState(() => _isLoading = false);

    if (result.success && mounted) {
      Navigator.pop(context, true);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? '发布失败'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(_pageTitle),
        leading: const BackButton(),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _submit,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isEditing ? '保存' : '发布'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- title (water post) ----
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '标题（选填）',
                hintText: '给帖子起个标题吧',
              ),
            ),
            const SizedBox(height: 16),

            // ---- content ----
            TextField(
              controller: _contentController,
              decoration: const InputDecoration(
                labelText: '内容',
                hintText: '分享你的想法...',
                alignLabelWithHint: true,
              ),
              maxLines: 10,
            ),
            const SizedBox(height: 16),

            // ---- images ----
            PublishImageGrid(
              existingImages: _existingImages,
              selectedImages: _selectedImages,
              canAddMore: canAddMoreImages,
              addButtonLabel: _addButtonLabel,
              onAddImage: showImageSourceDialog,
              onRemoveNewImage: onNewImageRemoved,
              onRemoveExistingImage: onExistingImageRemoved,
            ),
          ],
        ),
      ),
    );
  }
}
