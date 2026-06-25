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
class WaterPostComposer extends StatefulWidget {
  final Post? editingPost;

  const WaterPostComposer({super.key, this.editingPost});

  @override
  State<WaterPostComposer> createState() => _WaterPostComposerState();
}

class _WaterPostComposerState extends State<WaterPostComposer>
    with PublishImagePickerMixin {
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
      _canUploadUnlimitedImages || _totalImageCount < 9;

  String get _pageTitle => _isEditing ? '编辑帖子' : '发布水帖';

  String get _addButtonLabel {
    final hasAnyImage = _totalImageCount > 0;
    if (_canUploadUnlimitedImages) {
      return hasAnyImage ? '继续添加' : '添加图片';
    }
    return hasAnyImage ? '继续添加' : '添加图片（最多9张）';
  }

  // ---------------------------------------------------------------------------
  // Styling
  // ---------------------------------------------------------------------------

  InputDecoration _inputDecoration({
    required String label,
    String? hint,
    bool alignLabelWithHint = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: alignLabelWithHint,
      filled: true,
      fillColor: colorScheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  Widget _buildSectionCard({required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: child,
    );
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
          SnackBar(
            content: Text('发布失败：$e'),
            backgroundColor: Colors.red,
          ),
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
    final topPadding = MediaQuery.of(context).padding.top + kToolbarHeight;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF06080D) : const Color(0xFFF4F6FB),
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(_pageTitle),
        leading: const BackButton(),
      ),
      bottomNavigationBar: PublishBottomBar(
        isLoading: _isLoading,
        onPressed: _isLoading ? null : _submit,
        label: _isEditing ? '保存' : '发布',
      ),
      body: Stack(
        children: [
          // ---- background gradient (matches market_screen) ----
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? const [
                          Color(0xFF06080D),
                          Color(0xFF10131A),
                          Color(0xFF06080D),
                        ]
                      : const [
                          Color(0xFFF4F6FB),
                          Color(0xFFEFF3F8),
                          Color(0xFFF8FAFC),
                        ],
                ),
              ),
            ),
          ),

          // ---- form body ----
          SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              topPadding + 8,
              16,
              100, // clearance for bottom bar
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---- title: lightweight, no heavy border ----
                  TextFormField(
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
                  const SizedBox(height: 4),

                  // ---- divider ----
                  Divider(
                    color: Colors.grey.withValues(alpha: 0.2),
                    height: 1,
                  ),
                  const SizedBox(height: 16),

                  // ---- content: lightweight editor ----
                  TextFormField(
                    controller: _contentController,
                    decoration: const InputDecoration(
                      hintText: '分享校园生活、提问或记录此刻…',
                      hintStyle: TextStyle(color: Colors.grey, fontSize: 15),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: const TextStyle(fontSize: 15, height: 1.6),
                    maxLines: 8,
                    minLines: 4,
                    validator: (v) => (v ?? '').trim().isEmpty ? '请输入内容' : null,
                  ),
                  const SizedBox(height: 24),

                  // ---- image section ----
                  _buildSectionCard(
                    child: PublishImageGrid(
                      existingImages: _existingImages,
                      selectedImages: _selectedImages,
                      canAddMore: canAddMoreImages,
                      addButtonLabel: _addButtonLabel,
                      onAddImage: showImageSourceDialog,
                      onRemoveNewImage: onNewImageRemoved,
                      onRemoveExistingImage: onExistingImageRemoved,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
