import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/privileged_accounts.dart';
import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import 'exposure_publish_form.dart';
import 'widgets/publish_image_grid.dart';
import 'widgets/publish_image_picker.dart';
import 'widgets/publish_type_selector.dart';

/// Full-screen marketplace publish form (boardId == 2).
class MarketPublishForm extends StatefulWidget {
  final String? defaultPostType;
  final Post? editingPost;
  final List<String>? allowedPostTypes;

  const MarketPublishForm({
    super.key,
    this.defaultPostType,
    this.editingPost,
    this.allowedPostTypes,
  });

  @override
  State<MarketPublishForm> createState() => _MarketPublishFormState();
}

class _MarketPublishFormState extends State<MarketPublishForm>
    with PublishImagePickerMixin {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _priceController = TextEditingController();
  final _contactController = TextEditingController();
  String _postType = '';
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

  bool get _showsPriceField => _postType != 'lost' && _postType != 'found';

  bool get _showsTitleField => _postType != 'exposure';

  bool get _isLostOrFound => _postType == 'lost' || _postType == 'found';

  String get _pageTitle {
    if (_isEditing) return '编辑帖子';
    switch (_postType) {
      case 'exposure':
        return '曝光骗子';
      default:
        return '发布商品';
    }
  }

  String get _addButtonLabel {
    if (_canUploadUnlimitedImages) {
      return _selectedImages.isEmpty ? '添加图片' : '继续添加';
    }
    return _selectedImages.isEmpty ? '添加图片（最多9张）' : '继续添加';
  }

  String get _titleLabel => _isLostOrFound ? '物品名称' : '商品名称';

  String get _titleHint => _isLostOrFound ? '请输入物品名称' : '请输入商品名称';

  String get _contentHint {
    switch (_postType) {
      case 'exposure':
        return '详细描述被骗经过，上传截图证据...';
      case 'lost':
        return '描述丢失物品、时间、地点和联系方式...';
      case 'found':
        return '描述捡到的物品、地点、时间和领取方式...';
      default:
        return '详细描述商品或服务...';
    }
  }

  String get _contactLabel => _isLostOrFound ? '联系方式及地点（选填）' : '联系方式（选填）';

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
      _priceController.text = post.price > 0 ? post.price.toString() : '';
      _contactController.text = post.contact;
      _postType = post.postType;
      _existingImages.addAll(post.images);
    } else if (widget.defaultPostType != null) {
      _postType = widget.defaultPostType!;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _priceController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Type change
  // ---------------------------------------------------------------------------

  void _onTypeChanged(String newType) {
    if (mounted) setState(() => _postType = newType);
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_isLoading) return;

    final auth = context.read<AuthProvider>();
    if (auth.user?.eduBound != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('毕业用户仅可发布普通帖子，不能在集市发帖'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (_contentController.text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入内容')));
      }
      return;
    }

    if (_postType.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请选择帖子类型')));
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
            boardId: 2,
            content: _contentController.text,
            title: _titleController.text,
            postType: _postType,
            price: double.tryParse(_priceController.text),
            contact: _contactController.text,
            fileIds: mergedFileIds,
          )
        : await postProvider.createPost(
            boardId: 2,
            content: _contentController.text,
            title:
                _titleController.text.isNotEmpty ? _titleController.text : null,
            postType: _postType.isNotEmpty ? _postType : null,
            price: double.tryParse(_priceController.text),
            contact: _contactController.text.isNotEmpty
                ? _contactController.text
                : null,
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
            // ---- title (hidden for exposure) ----
            if (_showsTitleField) ...[
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: _titleLabel,
                  hintText: _titleHint,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ---- price + type selector row ----
            Row(
              children: [
                if (_showsPriceField) ...[
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _priceController,
                      decoration: InputDecoration(
                        labelText: _postType == 'exposure' ? '涉及金额' : '价格',
                        prefixText: _postType == 'exposure' ? '¥ ' : '¥ ',
                        hintText: _postType == 'exposure' ? '预估损失金额' : '0',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  flex: 3,
                  child: PublishTypeSelector(
                    currentType: _postType,
                    allowedTypes: widget.allowedPostTypes,
                    onChanged: _onTypeChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ---- exposure warning banner ----
            if (_postType == 'exposure') ...[
              const ExposurePublishForm(),
              const SizedBox(height: 16),
            ],

            // ---- contact ----
            TextField(
              controller: _contactController,
              decoration: InputDecoration(
                labelText: _contactLabel,
                hintText: '您的联系方式，方便他人核实',
              ),
            ),
            const SizedBox(height: 16),

            // ---- content ----
            TextField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: '详细描述',
                hintText: _contentHint,
                alignLabelWithHint: true,
              ),
              maxLines: 12,
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
