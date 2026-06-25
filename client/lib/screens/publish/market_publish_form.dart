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
      _canUploadUnlimitedImages || _totalImageCount < 9;

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

  String get _addButtonLabel {
    final hasAnyImage = _totalImageCount > 0;
    if (_canUploadUnlimitedImages) {
      return hasAnyImage ? '继续添加' : '添加图片';
    }
    return hasAnyImage ? '继续添加' : '添加图片（最多9张）';
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
  // Price formatter
  // ---------------------------------------------------------------------------

  static final _priceFormatter = TextInputFormatter.withFunction(
    (oldValue, newValue) {
      final valid = RegExp(r'^\d{0,8}(\.\d{0,2})?$').hasMatch(newValue.text);
      return valid ? newValue : oldValue;
    },
  );

  // ---------------------------------------------------------------------------
  // Styling
  // ---------------------------------------------------------------------------

  InputDecoration _inputDecoration({
    required String label,
    String? hint,
    String? prefixText,
    bool alignLabelWithHint = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefixText,
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

  Widget _buildSectionCard({required List<Widget> children}) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
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

  // ---------------------------------------------------------------------------
  // Type change (no controller clearing — pollution is handled at submit time)
  // ---------------------------------------------------------------------------

  void _onTypeChanged(String newType) {
    if (mounted) setState(() => _postType = newType);
  }

  // ---------------------------------------------------------------------------
  // Validation
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
      return _postType == 'exposure' ? null : '请输入价格'; // optional for exposure
    }
    final price = double.tryParse(v);
    if (price == null) return '请输入合法价格';
    if (price < 0) return '价格不能小于 0';
    return null;
  }

  String? _validateContent(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      switch (_postType) {
        case 'exposure':
          return '请描述被骗经过';
        case 'lost':
        case 'found':
          return '请输入详细描述';
        default:
          return '请输入详细描述';
      }
    }
    return null;
  }

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

      // Type-gated parameter building: fields that don't apply to the
      // current _postType are forced to null so stale controller values
      // from a previous type selection never leak into the request.
      // updatePost() converts null → '' / 0 on the wire, which clears
      // inapplicable fields on the server.
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
                  // =========================================================
                  // 1. Type selector — always visible at the top
                  // =========================================================
                  _buildSectionCard(children: [
                    PublishTypeSelector(
                      currentType: _postType,
                      allowedTypes: widget.allowedPostTypes,
                      onChanged: _onTypeChanged,
                    ),
                  ]),

                  // =========================================================
                  // 2. Basic info: title + price
                  // =========================================================
                  _buildSectionCard(children: [
                    // title (hidden for exposure)
                    if (_showsTitleField) ...[
                      TextFormField(
                        controller: _titleController,
                        decoration: _inputDecoration(
                          label: _titleLabel,
                          hint: _titleHint,
                        ),
                        validator: _validateTitle,
                      ),
                    ],
                    // price (hidden for lost/found)
                    if (_showsPriceField) ...[
                      if (_showsTitleField) const SizedBox(height: 14),
                      TextFormField(
                        controller: _priceController,
                        decoration: _inputDecoration(
                          label: _postType == 'exposure' ? '涉及金额' : '价格',
                          hint: _postType == 'exposure' ? '预估损失金额' : '0',
                          prefixText: '¥ ',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [_priceFormatter],
                        validator: _validatePrice,
                      ),
                    ],
                    // edge case: exposure shows no title and no price
                    // (price is hidden for exposure per _showsPriceField? wait — it's TRUE for exposure since exposure != 'lost' && exposure != 'found')
                    // Actually exposure DOES show price — let's keep it.
                  ]),

                  // =========================================================
                  // 3. Warning banner (exposure only)
                  // =========================================================
                  if (_postType == 'exposure') ...[
                    _buildSectionCard(children: [
                      const ExposurePublishForm(),
                    ]),
                  ],

                  // =========================================================
                  // 4. Contact
                  // =========================================================
                  _buildSectionCard(children: [
                    TextFormField(
                      controller: _contactController,
                      decoration: _inputDecoration(
                        label: _contactLabel,
                        hint: '您的联系方式，方便他人核实',
                      ),
                    ),
                  ]),

                  // =========================================================
                  // 5. Description
                  // =========================================================
                  _buildSectionCard(children: [
                    TextFormField(
                      controller: _contentController,
                      decoration: _inputDecoration(
                        label: '详细描述',
                        hint: _contentHint,
                        alignLabelWithHint: true,
                      ),
                      maxLines: 6,
                      minLines: 3,
                      validator: _validateContent,
                    ),
                  ]),

                  // =========================================================
                  // 6. Images
                  // =========================================================
                  _buildSectionCard(children: [
                    PublishImageGrid(
                      existingImages: _existingImages,
                      selectedImages: _selectedImages,
                      canAddMore: canAddMoreImages,
                      addButtonLabel: _addButtonLabel,
                      onAddImage: showImageSourceDialog,
                      onRemoveNewImage: onNewImageRemoved,
                      onRemoveExistingImage: onExistingImageRemoved,
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
