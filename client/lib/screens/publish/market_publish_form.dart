import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/privileged_accounts.dart';
import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import 'exposure_publish_form.dart';
import 'widgets/publish_bottom_bar.dart';
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
  static const _maxImages = 9;

  final _formKey = GlobalKey<FormState>();
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
      _canUploadUnlimitedImages || _totalImageCount < _maxImages;

  bool get _showsPriceField => _postType != 'lost' && _postType != 'found';

  bool get _showsTitleField => _postType != 'exposure';

  bool get _isLostOrFound => _postType == 'lost' || _postType == 'found';

  String get _pageTitle {
    if (_isEditing) return '编辑帖子';
    switch (_postType) {
      case 'sell':
        return '发布出售';
      case 'buy':
        return '发布求购';
      case 'lost':
        return '发布失物';
      case 'found':
        return '发布招领';
      case 'exposure':
        return '曝光骗子';
      default:
        return '发布商品';
    }
  }

  String get _bottomBarLabel {
    if (_isEditing) return '保存修改';
    switch (_postType) {
      case 'sell':
        return '发布出售';
      case 'buy':
        return '发布求购';
      case 'lost':
        return '发布失物';
      case 'found':
        return '发布招领';
      case 'exposure':
        return '提交曝光';
      default:
        return '发布';
    }
  }

  String get _titleLabel => _isLostOrFound ? '物品名称' : '商品名称';

  String get _contentHint {
    switch (_postType) {
      case 'exposure':
        return '详细描述被骗经过，上传截图证据...';
      case 'lost':
        return '描述丢失物品、时间、地点和联系方式...';
      case 'found':
        return '描述捡到的物品、地点、时间和领取方式...';
      default:
        return '描述物品成色、使用情况、瑕疵、配件和交易要求……';
    }
  }

  // ---------------------------------------------------------------------------
  // Price formatter
  // ---------------------------------------------------------------------------

  static final _priceFormatter = TextInputFormatter.withFunction(
    (oldValue, newValue) {
      final valid = RegExp(r'^\d{0,8}(\.\d{0,2})?$').hasMatch(newValue.text);
      return valid ? newValue : oldValue;
    },
  );

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
      _priceController.text = post.price.toString();
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

  void _onTypeChanged(String newType) {
    if (mounted) setState(() => _postType = newType);
  }

  // ---------------------------------------------------------------------------
  // Validation (unchanged from previous round)
  // ---------------------------------------------------------------------------

  String? _validateTitle(String? value) {
    if (!_showsTitleField) return null;
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return _isLostOrFound ? '请输入物品名称' : '请输入商品名称';
    }
    return null;
  }

  String? _validatePrice(String? value) {
    if (!_showsPriceField) return null;
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return _postType == 'exposure' ? null : '请输入价格';
    }
    final price = double.tryParse(v);
    if (price == null) return '请输入合法价格';
    if (price < 0) return '价格不能小于 0';
    return null;
  }

  String? _validateContent(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return '请输入详细描述';
    return null;
  }

  bool _validate() {
    if (!_formKey.currentState!.validate()) return false;
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入内容'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Submit (unchanged from previous round)
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

    if (_postType.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请选择帖子类型')),
        );
      }
      return;
    }

    if (!_validate()) return;

    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final priceText = _priceController.text.trim();
    final contact = _contactController.text.trim();

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
              boardId: 2,
              content: content,
              title: _showsTitleField ? title : null,
              postType: _postType,
              price: _showsPriceField ? double.tryParse(priceText) : null,
              contact: contact,
              fileIds: mergedFileIds,
            )
          : await postProvider.createPost(
              boardId: 2,
              content: content,
              title: _showsTitleField && title.isNotEmpty ? title : null,
              postType: _postType.isNotEmpty ? _postType : null,
              price: _showsPriceField ? double.tryParse(priceText) : null,
              contact: contact.isNotEmpty ? contact : null,
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF06080D) : const Color(0xFFF6F7FA),
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
        label: _bottomBarLabel,
      ),
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // =====================================================
                // 1. 商品图片（置顶，不套卡片）
                // =====================================================
                _buildImageSection(colorScheme),
                const SizedBox(height: 24),

                // =====================================================
                // 2. 基本信息（白色容器，字段间分割线）
                // =====================================================
                if (_postType != 'exposure')
                  _buildBasicInfoCard(isDark, colorScheme),
                if (_postType != 'exposure') const SizedBox(height: 20),

                // =====================================================
                // 3. 发布类型 + 曝光入口
                // =====================================================
                _buildTypeSection(isDark),
                const SizedBox(height: 20),

                // =====================================================
                // 4. 曝光：警告横幅 + 涉及金额
                // =====================================================
                if (_postType == 'exposure') ...[
                  _buildExposureWarning(),
                  const SizedBox(height: 16),
                  _buildExposureAmountField(isDark),
                  const SizedBox(height: 20),
                ],

                // =====================================================
                // 5. 商品描述（浅灰填充，更高）
                // =====================================================
                _buildDescriptionField(isDark, colorScheme),
                const SizedBox(height: 20),

                // =====================================================
                // 6. 联系方式（弱化）
                // =====================================================
                _buildContactField(isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section builders
  // ---------------------------------------------------------------------------

  Widget _buildImageSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // header row
        Row(
          children: [
            const Text(
              '商品图片',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '$_totalImageCount/$_maxImages',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        PublishImageGrid(
          existingImages: _existingImages,
          selectedImages: _selectedImages,
          canAddMore: canAddMoreImages,
          onAddImage: showImageSourceDialog,
          onRemoveNewImage: onNewImageRemoved,
          onRemoveExistingImage: onExistingImageRemoved,
        ),
        const SizedBox(height: 8),
        Text(
          '清晰实拍更容易成交，第一张将作为封面',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildBasicInfoCard(bool isDark, ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // title field
          if (_showsTitleField)
            TextFormField(
              controller: _titleController,
              decoration: _plainInputDecoration(hint: _titleLabel),
              validator: _validateTitle,
            ),
          // divider
          if (_showsTitleField && _showsPriceField)
            Divider(
                height: 1,
                indent: 16,
                color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
          // price field
          if (_showsPriceField)
            TextFormField(
              controller: _priceController,
              decoration:
                  _plainInputDecoration(hint: '请输入价格', prefixText: '¥ '),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_priceFormatter],
              validator: _validatePrice,
            ),
        ],
      ),
    );
  }

  Widget _buildTypeSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '发布类型',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        PublishTypeSelector(
          currentType: _postType == 'exposure' ? '' : _postType,
          allowedTypes: widget.allowedPostTypes,
          onChanged: _onTypeChanged,
        ),
        const SizedBox(height: 8),
        // exposure link
        GestureDetector(
          onTap: () => _onTypeChanged('exposure'),
          child: Row(
            children: [
              Icon(
                _postType == 'exposure'
                    ? Icons.chevron_right
                    : Icons.chevron_right,
                size: 16,
                color: _postType == 'exposure'
                    ? Colors.orange
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                _postType == 'exposure' ? '曝光举报（已选中）' : '发现违规或诈骗？前往曝光举报',
                style: TextStyle(
                  fontSize: 13,
                  color: _postType == 'exposure'
                      ? Colors.orange
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: _postType == 'exposure'
                      ? FontWeight.w500
                      : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExposureWarning() {
    return const ExposurePublishForm();
  }

  Widget _buildExposureAmountField(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: TextFormField(
        controller: _priceController,
        decoration: _plainInputDecoration(hint: '预估损失金额', prefixText: '¥ '),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [_priceFormatter],
      ),
    );
  }

  Widget _buildDescriptionField(bool isDark, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '商品描述',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _contentController,
          decoration: InputDecoration(
            hintText: _contentHint,
            hintStyle: TextStyle(
              color: Colors.grey.withValues(alpha: 0.6),
              fontSize: 14,
            ),
            filled: true,
            fillColor: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : const Color(0xFFF7F7FA),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: colorScheme.primary.withValues(alpha: 0.35),
              ),
            ),
            contentPadding: const EdgeInsets.all(16),
            alignLabelWithHint: true,
          ),
          minLines: 5,
          maxLines: null,
          validator: _validateContent,
        ),
      ],
    );
  }

  Widget _buildContactField(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '联系方式',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '选填，建议优先通过站内私信联系',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : const Color(0xFFF7F7FA),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextFormField(
            controller: _contactController,
            decoration: _plainInputDecoration(
              hint: 'QQ / 微信 / 手机号（选填）',
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Shared plain input decoration (no border — used inside containers)
  // ---------------------------------------------------------------------------

  InputDecoration _plainInputDecoration({
    required String hint,
    String? prefixText,
  }) {
    return InputDecoration(
      hintText: hint,
      prefixText: prefixText,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    );
  }
}
