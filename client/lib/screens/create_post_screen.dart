import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../config/api_constants.dart';
import '../config/privileged_accounts.dart';
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../widgets/glass_container.dart';

class CreatePostScreen extends StatefulWidget {
  final int boardId;
  final String? defaultPostType;
  final Post? editingPost;
  final List<String>? allowedPostTypes;

  const CreatePostScreen({
    super.key,
    required this.boardId,
    this.defaultPostType,
    this.editingPost,
    this.allowedPostTypes,
  });

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _priceController = TextEditingController();
  final _contactController = TextEditingController();
  final _imagePicker = ImagePicker();
  String _postType = '';
  bool _isLoading = false;
  final List<XFile> _selectedImages = [];
  final List<PostImage> _existingImages = [];

  bool get _isEditing => widget.editingPost != null;
  bool get _canUploadUnlimitedImages {
    final studentId = context.read<AuthProvider>().user?.studentId;
    return PrivilegedAccounts.canUploadUnlimitedImages(studentId);
  }

  int get _totalImageCount => _existingImages.length + _selectedImages.length;
  bool get _canAddMoreImages =>
      _canUploadUnlimitedImages || _totalImageCount < 9;

  @override
  void initState() {
    super.initState();
    final editingPost = widget.editingPost;
    if (editingPost != null) {
      _titleController.text = editingPost.title;
      _contentController.text = editingPost.content;
      _priceController.text = editingPost.price > 0
          ? editingPost.price.toString()
          : '';
      _contactController.text = editingPost.contact;
      _postType = editingPost.postType;
      _existingImages.addAll(editingPost.images);
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

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _imagePicker.pickImage(source: source);
      if (image != null) {
        final length = await image.length();
        if (length > 10 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('图片大小不能超过 10MB'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        if (_canAddMoreImages) {
          if (mounted) {
            setState(() {
              _selectedImages.add(image);
            });
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('最多只能添加9张图片')));
          }
        }
      }
    } catch (e) {
      debugPrint('选择图片失败: $e');
    }
  }

  void _removeImage(int index) {
    if (mounted) {
      setState(() {
        _selectedImages.removeAt(index);
      });
    }
  }

  void _removeExistingImage(int index) {
    if (mounted) {
      setState(() {
        _existingImages.removeAt(index);
      });
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final auth = context.read<AuthProvider>();
    if (widget.boardId == 2 && auth.user?.eduBound != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('毕业用户仅可发布普通帖子，不能在集市发帖'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_contentController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入内容')));
      return;
    }

    if (widget.boardId == 2 && _postType.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请选择帖子类型')));
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    final postProvider = context.read<PostProvider>();

    // 先上传图片
    List<int> fileIds = [];
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
        setState(() {
          _isLoading = false;
        });
      }
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
            boardId: widget.boardId,
            content: _contentController.text,
            title: _titleController.text,
            postType: _postType,
            price: double.tryParse(_priceController.text),
            contact: _contactController.text,
            fileIds: mergedFileIds,
          )
        : await postProvider.createPost(
            boardId: widget.boardId,
            content: _contentController.text,
            title: _titleController.text.isNotEmpty
                ? _titleController.text
                : null,
            postType: _postType.isNotEmpty ? _postType : null,
            price: double.tryParse(_priceController.text),
            contact: _contactController.text.isNotEmpty
                ? _contactController.text
                : null,
            fileIds: mergedFileIds.isNotEmpty ? mergedFileIds : null,
          );

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          _isEditing
              ? '编辑帖子'
              : widget.boardId == 2
              ? (_postType == 'exposure' ? '曝光骗子' : '发布商品')
              : '发布水贴',
        ),
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
            // 校园集市/曝光额外字段
            if (widget.boardId == 2) ...[
              // 类型选择
              if (_postType != 'exposure') ...[
                TextField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: (_postType == 'lost' || _postType == 'found')
                        ? '物品名称'
                        : '商品名称',
                    hintText: (_postType == 'lost' || _postType == 'found')
                        ? '请输入物品名称'
                        : '请输入商品名称',
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  if (_postType != 'lost' && _postType != 'found') ...[
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
                    child: DropdownButtonFormField<String>(
                      decoration: const InputDecoration(labelText: '类型'),
                      initialValue: _postType.isEmpty ? null : _postType,
                      items: [
                        if (widget.allowedPostTypes == null ||
                            widget.allowedPostTypes!.contains('sell'))
                          const DropdownMenuItem(
                            value: 'sell',
                            child: Text('出售'),
                          ),
                        if (widget.allowedPostTypes == null ||
                            widget.allowedPostTypes!.contains('buy'))
                          const DropdownMenuItem(
                            value: 'buy',
                            child: Text('求购'),
                          ),
                        if (widget.allowedPostTypes == null ||
                            widget.allowedPostTypes!.contains('proxy'))
                          const DropdownMenuItem(
                            value: 'proxy',
                            child: Text('代课'),
                          ),
                        if (widget.allowedPostTypes == null ||
                            widget.allowedPostTypes!.contains('lost'))
                          const DropdownMenuItem(
                            value: 'lost',
                            child: Text('求问失物'),
                          ),
                        if (widget.allowedPostTypes == null ||
                            widget.allowedPostTypes!.contains('found'))
                          const DropdownMenuItem(
                            value: 'found',
                            child: Text('寻找失主'),
                          ),
                        if (widget.allowedPostTypes == null ||
                            widget.allowedPostTypes!.contains('exposure'))
                          const DropdownMenuItem(
                            value: 'exposure',
                            child: Text('曝光'),
                          ),
                      ],
                      onChanged: (value) {
                        if (mounted) {
                          setState(() {
                            _postType = value ?? '';
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_postType == 'exposure')
                GlassContainer(
                  padding: const EdgeInsets.all(12),
                  borderRadius: 12,
                  blur: 10,
                  opacity: 0.1,
                  child: Row(
                    children: [
                      Icon(Icons.warning, color: Colors.orange[700]),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '曝光骗子需提供充分证据，我们会对内容进行审核',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_postType == 'exposure') const SizedBox(height: 16),
              TextField(
                controller: _contactController,
                decoration: InputDecoration(
                  labelText: (_postType == 'lost' || _postType == 'found')
                      ? '联系方式及地点（选填）'
                      : '联系方式（选填）',
                  hintText: '您的联系方式，方便他人核实',
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 水贴内容
            if (widget.boardId == 1) ...[
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: '标题（选填）',
                  hintText: '给帖子起个标题吧',
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 内容
            TextField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: widget.boardId == 1 ? '内容' : '详细描述',
                hintText: widget.boardId == 1
                    ? '分享你的想法...'
                    : (_postType == 'exposure'
                          ? '详细描述被骗经过，上传截图证据...'
                          : (_postType == 'lost'
                                ? '描述丢失物品、时间、地点和联系方式...'
                                : _postType == 'found'
                                ? '描述捡到的物品、地点、时间和领取方式...'
                                : '详细描述商品或服务...')),
                alignLabelWithHint: true,
              ),
              maxLines: widget.boardId == 2 ? 12 : 10,
            ),
            const SizedBox(height: 16),

            // 图片上传
            if (_existingImages.isNotEmpty || _selectedImages.isNotEmpty) ...[
              SizedBox(
                height: 100,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount:
                      _existingImages.length +
                      _selectedImages.length +
                      (_canAddMoreImages ? 1 : 0),
                  itemBuilder: (context, index) {
                    final totalImages =
                        _existingImages.length + _selectedImages.length;
                    if (index == totalImages) {
                      // Add more button
                      return GestureDetector(
                        onTap: _showImageSourceDialog,
                        child: Container(
                          width: 100,
                          height: 100,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey[400]!),
                            color: Colors.grey[100],
                          ),
                          child: Icon(
                            Icons.add,
                            color: Colors.grey[600],
                            size: 32,
                          ),
                        ),
                      );
                    }
                    if (index < _existingImages.length) {
                      final image = _existingImages[index];
                      return Stack(
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: CachedNetworkImage(
                                imageUrl: ApiConstants.fullUrl(image.url),
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  color: Colors.grey[300],
                                  child: const Icon(Icons.broken_image),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 12,
                            child: GestureDetector(
                              onTap: () => _removeExistingImage(index),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    final image =
                        _selectedImages[index - _existingImages.length];
                    return Stack(
                      children: [
                        Container(
                          width: 100,
                          height: 100,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(image.path),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey[300],
                                child: const Icon(Icons.broken_image),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 12,
                          child: GestureDetector(
                            onTap: () =>
                                _removeImage(index - _existingImages.length),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton.icon(
              onPressed: _showImageSourceDialog,
              icon: const Icon(Icons.add_photo_alternate),
              label: Text(
                _canUploadUnlimitedImages
                    ? (_selectedImages.isEmpty ? '添加图片' : '继续添加')
                    : (_selectedImages.isEmpty ? '添加图片（最多9张）' : '继续添加'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
