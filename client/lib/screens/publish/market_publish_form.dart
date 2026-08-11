import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/market_contact_type.dart';
import '../../config/privileged_accounts.dart';
import '../../models/post.dart';
import '../../models/publish_image_item.dart';
import '../../providers/auth_provider.dart';
import '../../providers/post_provider.dart';
import '../../utils/app_feedback.dart';
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

enum _PublishField { type, title, price, content, contact }

class _MarketPublishFormState extends State<MarketPublishForm>
    with SingleTickerProviderStateMixin, PublishImagePickerMixin {
  static const _maxImages = 9;
  static const _maxDescriptionLength = 500;
  static const _marketAccent = Color(0xFFFF7A45);
  static const _marketPageBg = Color(0xFFFFFAF4);
  static const _marketMutedText = Color(0xFF747B82);
  static const _marketFormFontSize = 17.0;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _priceController = TextEditingController();
  final _contactController = TextEditingController();
  late final AnimationController _shakeController;
  String _postType = '';
  String _contactType = '';
  bool _isLoading = false;
  Set<_PublishField> _attentionFields = {};
  int _attentionPulse = 0;
  // C-2 统一图片列表（existing + local 混合，顺序即发布顺序）。
  final List<PublishImageItem> _images = [];
  int _localImageSeq = 0;

  String _nextLocalImageId() {
    _localImageSeq++;
    return 'local-${DateTime.now().millisecondsSinceEpoch}-$_localImageSeq';
  }

  final Set<String> _selectedMarketTags = {};

  bool _hasTriedSubmit = false;
  bool _skipDraftGuard = false;

  bool get _hasDraft {
    if (_isLoading || _skipDraftGuard) return false;

    final hasText = _titleController.text.trim().isNotEmpty ||
        _contentController.text.trim().isNotEmpty ||
        _priceController.text.trim().isNotEmpty ||
        _contactController.text.trim().isNotEmpty ||
        _contactType.isNotEmpty;

    final hasMediaOrTags =
        _images.any((e) => e.source == PublishImageSource.local) ||
            _selectedMarketTags.isNotEmpty ||
            _images.length != (widget.editingPost?.images.length ?? 0);

    if (!_isEditing) return hasText || hasMediaOrTags;

    final p = widget.editingPost!;
    return _postType != p.postType ||
        _titleController.text != p.title ||
        _contentController.text != p.content ||
        _priceController.text != p.price.toString() ||
        _contactType != p.contactType ||
        _contactController.text != p.contact ||
        _images.any((e) => e.source == PublishImageSource.local) ||
        _images.length != p.images.length ||
        _selectedMarketTags.join('|') != p.marketTags.join('|');
  }

  Future<void> _maybePop() async {
    if (!_hasDraft) {
      Navigator.of(context).pop();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('放弃编辑？'),
        content: const Text('当前填写的内容还没有发布，返回后会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _skipDraftGuard = true;
      Navigator.of(context).pop();
    }
  }

  List<String> get _availableMarketTags {
    switch (_postType) {
      case 'sell':
        return ['自提', '可送宿舍楼下', '可小刀', '急出'];
      case 'buy':
        return ['自提', '可上门', '长期求', '急需'];
      case 'proxy':
        return ['可跑腿', '当日完成', '可议价'];
      default:
        return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // PublishImagePickerMixin abstract impl
  // ---------------------------------------------------------------------------

  @override
  void onImageAdded(XFile image) => setState(
      () => _images.add(PublishImageItem.local(image, _nextLocalImageId())));

  // ---- 统一图片操作 ----

  void _removeImage(String id) {
    setState(() => _images.removeWhere((e) => e.id == id));
  }

  void _moveImage(String draggedId, String targetId) {
    reorderImages(_images, draggedId, targetId);
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

  // ---------------------------------------------------------------------------
  // Helpers
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
      case 'proxy':
        return '发布办事';
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
      case 'proxy':
        return '发布办事';
      case 'exposure':
        return '提交曝光';
      default:
        return '发布';
    }
  }

  String get _titleLabel {
    if (_postType == 'proxy') return '办事标题';
    return _isLostOrFound ? '物品名称' : '商品名称';
  }

  String get _priceLabel {
    switch (_postType) {
      case 'sell':
        return '出售价格';
      case 'buy':
        return '求购预算';
      case 'proxy':
        return '办事预算';
      default:
        return '价格';
    }
  }

  String get _contentHint {
    switch (_postType) {
      case 'exposure':
        return '详细描述被骗经过，上传截图证据...';
      case 'lost':
        return '描述丢失物品、时间、地点和联系方式...';
      case 'found':
        return '描述捡到的物品、地点、时间和领取方式...';
      case 'proxy':
        return '描述要办的事情、时间地点、预算和具体要求...';
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
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    final post = widget.editingPost;
    if (post != null) {
      _titleController.text = post.title;
      _contentController.text = post.content;
      _priceController.text = post.price.toString();
      _contactType = post.contactType;
      _contactController.text = post.contact;
      _postType = post.postType;
      _images.addAll(post.images.map(PublishImageItem.existing));
      _selectedMarketTags.addAll(post.marketTags);
    } else if (widget.defaultPostType != null) {
      _postType = widget.defaultPostType!;
    }
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _priceController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  void _onTypeChanged(String newType) {
    if (!mounted || _postType == newType) return;

    setState(() {
      _postType = newType;
      _attentionFields = {};
      _attentionPulse++;
      _selectedMarketTags
          .retainWhere((tag) => _availableMarketTags.contains(tag));
    });

    if (_hasTriedSubmit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _formKey.currentState?.validate();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Validation (unchanged from previous round)
  // ---------------------------------------------------------------------------

  String? _validateTitle(String? value) {
    if (!_showsTitleField) return null;
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return '请输入$_titleLabel';
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
    if (v.length > _maxDescriptionLength) {
      return '描述不能超过 $_maxDescriptionLength 字';
    }
    return null;
  }

  String? _validateContact(String? value) {
    final contact = (value ?? '').trim();
    if (_contactType.isEmpty && contact.isEmpty) return null;
    if (_contactType.isEmpty) return '请选择联系方式类型';
    if (contact.isEmpty) return marketContactInputHint(_contactType);
    if (contact.runes.length > 100) return '联系方式不能超过 100 个字符';
    if (_contactType == marketContactTypeOther &&
        (!_isEditing || contact != widget.editingPost!.contact)) {
      return '请重新选择微信、QQ或电话';
    }
    return null;
  }

  Set<_PublishField> _collectMissingRequiredFields() {
    final fields = <_PublishField>{};
    if (_postType.isEmpty) fields.add(_PublishField.type);
    if (_showsTitleField && _titleController.text.trim().isEmpty) {
      fields.add(_PublishField.title);
    }
    if (_showsPriceField &&
        _postType != 'exposure' &&
        _priceController.text.trim().isEmpty) {
      fields.add(_PublishField.price);
    }
    if (_contentController.text.trim().isEmpty) {
      fields.add(_PublishField.content);
    }
    final hasContactType = _contactType.isNotEmpty;
    final hasContact = _contactController.text.trim().isNotEmpty;
    if (hasContactType != hasContact) fields.add(_PublishField.contact);
    return fields;
  }

  Future<void> _triggerRequiredHint(Set<_PublishField> fields) async {
    if (!mounted || fields.isEmpty) return;

    final pulse = ++_attentionPulse;
    setState(() => _attentionFields = fields);
    _shakeController.forward(from: 0);

    await Future.delayed(const Duration(milliseconds: 1100));
    if (mounted && pulse == _attentionPulse) {
      setState(() => _attentionFields = {});
    }
  }

  bool _validate() {
    _hasTriedSubmit = true;
    final missingFields = _collectMissingRequiredFields();
    if (missingFields.isNotEmpty) {
      _triggerRequiredHint(missingFields);
      _formKey.currentState!.validate();
      return false;
    }
    return _formKey.currentState!.validate();
  }

  // ---------------------------------------------------------------------------
  // Submit (unchanged from previous round)
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_isLoading) return;

    final auth = context.read<AuthProvider>();
    if (auth.user?.studentVerified != true) {
      if (mounted) {
        AppFeedback.error('毕业用户仅可发布普通帖子，不能在集市发帖', context: context);
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

      // C-3：并发上传本地图（失败项可重试，不提交）。
      if (!await _uploadLocalImages(postProvider)) {
        if (mounted) {
          AppFeedback.error('图片上传失败，请点击图片重试', context: context);
        }
        return;
      }

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

      final result = _isEditing
          ? await postProvider.updatePost(
              postId: widget.editingPost!.id,
              boardId: 2,
              content: content,
              title: _showsTitleField ? title : null,
              postType: _postType,
              price: _showsPriceField ? double.tryParse(priceText) : null,
              contactType: _contactType,
              contact: contact,
              fileIds: fileIds,
              marketTags: _selectedMarketTags.toList(growable: false),
            )
          : await postProvider.createPost(
              boardId: 2,
              content: content,
              title: _showsTitleField && title.isNotEmpty ? title : null,
              postType: _postType.isNotEmpty ? _postType : null,
              price: _showsPriceField ? double.tryParse(priceText) : null,
              contactType: _contactType.isNotEmpty ? _contactType : null,
              contact: contact.isNotEmpty ? contact : null,
              fileIds: fileIds.isNotEmpty ? fileIds : null,
              marketTags: _selectedMarketTags.toList(growable: false),
            );

      if (!mounted) return;
      if (result.success) {
        _skipDraftGuard = true;
        Navigator.of(context).pop(true);
      } else {
        AppFeedback.error(result.errorMessage ?? '发布失败', context: context);
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.error('发布失败：$e', context: context);
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

    return PopScope(
      canPop: !_hasDraft,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _maybePop();
      },
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF111315) : _marketPageBg,
        extendBodyBehindAppBar: true,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          forceMaterialTransparency: true,
          centerTitle: true,
          title: Text(_pageTitle),
          titleTextStyle: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF1F2328),
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
          leading: BackButton(onPressed: _maybePop),
        ),
        bottomNavigationBar: PublishBottomBar(
          isLoading: _isLoading,
          onPressed: _isLoading ? null : _submit,
          label: _bottomBarLabel,
          accent: _marketAccent,
        ),
        body: DecoratedBox(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111315) : _marketPageBg,
          ),
          child: SafeArea(
            bottom: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildCampusHeader(isDark),
                    const SizedBox(height: 14),
                    _buildImageSection(colorScheme),
                    const SizedBox(height: 16),
                    if (_postType != 'exposure')
                      _buildMarketDetailsCard(isDark, colorScheme)
                    else ...[
                      _buildTypeSection(isDark),
                      const SizedBox(height: 14),
                      _buildExposureWarning(),
                      const SizedBox(height: 16),
                      _buildExposureAmountField(isDark),
                      const SizedBox(height: 14),
                      _buildDescriptionField(isDark, colorScheme),
                      const SizedBox(height: 14),
                      _buildContactField(isDark),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section builders
  // ---------------------------------------------------------------------------

  Widget _buildCampusHeader(bool isDark) {
    final secondaryText =
        isDark ? Colors.white.withValues(alpha: 0.58) : _marketMutedText;

    return SizedBox(
      height: 72,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -30,
            top: -22,
            child: Opacity(
              opacity: isDark ? 0.18 : 0.16,
              child: SizedBox(
                width: 176,
                height: 96,
                child: CustomPaint(
                  painter: _CampusLineArtPainter(
                    color: isDark ? Colors.white : _marketAccent,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            bottom: 9,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '校园集市',
                  style: TextStyle(
                    color: _marketAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: _marketAccent,
                    borderRadius: BorderRadius.circular(5),
                    boxShadow: [
                      BoxShadow(
                        color: _marketAccent.withValues(alpha: 0.14),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.verified_rounded,
                    color: Colors.white,
                    size: 12,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '· 2 分钟发布闲置',
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel('商品图片'),
            const Spacer(),
            Text(
              '${_totalImageCount.clamp(0, _maxImages)}/$_maxImages',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        PublishImageGrid(
          images: _images,
          canAddMore: canAddMoreImages,
          onAdd: showImageSourceDialog,
          onRemove: _removeImage,
          onReorder: _moveImage,
          onRetry: _retryImage,
          addLabel: '添加图片',
          compact: true,
          accent: _marketAccent,
        ),
      ],
    );
  }

  Widget _buildMarketDetailsCard(bool isDark, ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: const Color(0xFF2B3154).withValues(alpha: 0.045),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
        ],
      ),
      child: Column(
        children: [
          if (_showsTitleField)
            _buildLabeledTextFormField(
              key: ValueKey('market-title-$_postType'),
              field: _PublishField.title,
              label: _titleLabel,
              controller: _titleController,
              hint: '请输入$_titleLabel',
              validator: _validateTitle,
            ),
          if (_showsTitleField && _showsPriceField)
            _buildCardDivider(colorScheme),
          if (_showsPriceField)
            _buildLabeledTextFormField(
              field: _PublishField.price,
              label: _priceLabel,
              controller: _priceController,
              hint: '请输入价格',
              prefixText: '¥ ',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_priceFormatter],
              validator: _validatePrice,
            ),
          _buildCardDivider(colorScheme),
          _buildTypeRowInsideCard(colorScheme),
          _buildCardDivider(colorScheme),
          _buildDescriptionInsideCard(isDark, colorScheme),
          _buildCardDivider(colorScheme),
          _buildContactInsideCard(isDark, colorScheme),
        ],
      ),
    );
  }

  Widget _buildCardDivider(ColorScheme colorScheme) {
    return Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: colorScheme.outlineVariant.withValues(alpha: 0.30),
    );
  }

  Widget _buildLabeledTextFormField({
    Key? key,
    required _PublishField field,
    required String label,
    required TextEditingController controller,
    required String hint,
    String? prefixText,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRequiredLabel(label, field),
          const SizedBox(height: 6),
          TextFormField(
            key: key,
            controller: controller,
            decoration: _inlineInputDecoration(
              hint: hint,
              prefixText: prefixText,
            ),
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            validator: validator,
            style: const TextStyle(
              fontSize: _marketFormFontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeRowInsideCard(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(child: _buildRequiredLabel('类型', _PublishField.type)),
          PublishTypeSelector(
            currentType: _postType == 'exposure' ? '' : _postType,
            allowedTypes: widget.allowedPostTypes,
            onChanged: _onTypeChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionInsideCard(bool isDark, ColorScheme colorScheme) {
    final needsAttention = _attentionFields.contains(_PublishField.content);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRequiredLabel('描述', _PublishField.content),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDescriptionChip('自提', Icons.shopping_bag_outlined),
                  const SizedBox(width: 6),
                  _buildDescriptionChip('可送宿舍楼下', Icons.delivery_dining),
                  const SizedBox(width: 6),
                  _buildDescriptionChip('可小刀', Icons.local_offer_outlined),
                  const SizedBox(width: 6),
                  _buildDescriptionChip('急出', Icons.bolt_rounded),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _contentController,
            decoration: InputDecoration(
              hintText: _contentHint,
              hintStyle: TextStyle(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.54),
                fontSize: 14,
              ),
              filled: true,
              fillColor: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFFF8F7F5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide(
                  color: needsAttention
                      ? colorScheme.error.withValues(alpha: 0.55)
                      : Colors.transparent,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide(
                  color: needsAttention
                      ? colorScheme.error.withValues(alpha: 0.75)
                      : _marketAccent.withValues(alpha: 0.45),
                ),
              ),
              contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              counterText:
                  '${_contentController.text.length}/$_maxDescriptionLength',
              counterStyle: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            onChanged: (_) => setState(() {}),
            inputFormatters: [
              LengthLimitingTextInputFormatter(_maxDescriptionLength),
            ],
            maxLength: _maxDescriptionLength,
            minLines: 4,
            maxLines: null,
            validator: _validateContent,
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionChip(String label, IconData icon) {
    final selected = _selectedMarketTags.contains(label);
    final textColor = selected ? _marketAccent : const Color(0xFF747B82);
    final iconColor = selected
        ? _marketAccent.withValues(alpha: 0.7)
        : const Color(0xFF9AA0AE);
    final bgColor = selected
        ? _marketAccent.withValues(alpha: 0.06)
        : const Color(0xFFF7F7F8);
    final borderColor = selected
        ? _marketAccent.withValues(alpha: 0.24)
        : const Color(0xFFE8E7E6);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _toggleMarketTag(label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 3),
            Icon(icon, size: 13, color: iconColor),
          ],
        ),
      ),
    );
  }

  void _toggleMarketTag(String tag) {
    setState(() {
      if (!_selectedMarketTags.add(tag)) {
        _selectedMarketTags.remove(tag);
      }
    });
  }

  Widget _buildContactInsideCard(bool isDark, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
      child: _buildStructuredContactInput(isDark, colorScheme),
    );
  }

  Widget _buildTypeSection(bool isDark) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171B24) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _attentionFields.contains(_PublishField.type)
                  ? colorScheme.error.withValues(alpha: 0.7)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Expanded(child: _buildRequiredLabel('发布类型', _PublishField.type)),
              PublishTypeSelector(
                currentType: _postType == 'exposure' ? '' : _postType,
                allowedTypes: widget.allowedPostTypes,
                onChanged: _onTypeChanged,
              ),
            ],
          ),
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
    final needsAttention = _attentionFields.contains(_PublishField.content);
    final quietBorderColor = colorScheme.outlineVariant.withValues(alpha: 0.2);
    final activeBorderColor = needsAttention
        ? colorScheme.error.withValues(alpha: 0.75)
        : _marketAccent.withValues(alpha: 0.38);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildRequiredLabel('商品描述', _PublishField.content),
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
              borderSide: BorderSide(color: quietBorderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: needsAttention
                    ? colorScheme.error.withValues(alpha: 0.55)
                    : quietBorderColor,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: activeBorderColor),
            ),
            contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            alignLabelWithHint: true,
            counterStyle: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          inputFormatters: [
            LengthLimitingTextInputFormatter(_maxDescriptionLength),
          ],
          maxLength: _maxDescriptionLength,
          minLines: 4,
          maxLines: null,
          validator: _validateContent,
        ),
      ],
    );
  }

  Widget _buildContactField(bool isDark) {
    return _buildStructuredContactInput(
      isDark,
      Theme.of(context).colorScheme,
    );
  }

  Widget _buildStructuredContactInput(
    bool isDark,
    ColorScheme colorScheme,
  ) {
    final needsAttention = _attentionFields.contains(_PublishField.contact);
    final dropdownItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('未选择')),
      const DropdownMenuItem(
        value: marketContactTypeWeChat,
        child: Text('微信'),
      ),
      const DropdownMenuItem(value: marketContactTypeQQ, child: Text('QQ')),
      const DropdownMenuItem(
        value: marketContactTypePhone,
        child: Text('电话'),
      ),
      if (_contactType == marketContactTypeOther)
        const DropdownMenuItem(
          value: marketContactTypeOther,
          enabled: false,
          child: Text('其他方式'),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShakingAttention(
          active: needsAttention,
          controller: _shakeController,
          child: const Text(
            '联系方式（选填）',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 104,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('market-contact-type'),
                initialValue: _contactType,
                isExpanded: true,
                items: dropdownItems,
                onChanged: (value) {
                  setState(() => _contactType = value ?? '');
                  if (_hasTriedSubmit) _formKey.currentState?.validate();
                },
                decoration: _contactInputDecoration(
                  isDark: isDark,
                  colorScheme: colorScheme,
                  needsAttention: needsAttention,
                ),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: const ValueKey('market-contact-value'),
                controller: _contactController,
                keyboardType: marketContactKeyboardType(_contactType),
                textInputAction: TextInputAction.done,
                maxLength: 100,
                onChanged: (_) {
                  setState(() {});
                  if (_hasTriedSubmit) _formKey.currentState?.validate();
                },
                validator: _validateContact,
                decoration: _contactInputDecoration(
                  isDark: isDark,
                  colorScheme: colorScheme,
                  needsAttention: needsAttention,
                  hint: marketContactInputHint(_contactType),
                ).copyWith(counterText: ''),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '详情页仅显示联系方式类型，点击后复制',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  InputDecoration _contactInputDecoration({
    required bool isDark,
    required ColorScheme colorScheme,
    required bool needsAttention,
    String? hint,
  }) {
    final borderColor = needsAttention
        ? colorScheme.error.withValues(alpha: 0.65)
        : colorScheme.outlineVariant.withValues(alpha: 0.55);
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 14,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
      filled: true,
      fillColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : const Color(0xFFF7F7FA),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: _marketAccent.withValues(alpha: 0.65)),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared plain input decoration (no border — used inside containers)
  // ---------------------------------------------------------------------------

  Widget _buildRequiredLabel(String text, _PublishField field) {
    final colorScheme = Theme.of(context).colorScheme;
    final active = _attentionFields.contains(field);

    return _ShakingAttention(
      active: active,
      controller: _shakeController,
      child: _buildSectionLabel(
        text,
        color: active ? colorScheme.error : colorScheme.onSurface,
      ),
    );
  }

  Widget _buildSectionLabel(String text, {Color? color}) {
    final colorScheme = Theme.of(context).colorScheme;

    return Text(
      text,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w800,
        color: color ?? colorScheme.onSurface,
      ),
    );
  }

  InputDecoration _inlineInputDecoration({
    required String hint,
    String? prefixText,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPricePrefix = prefixText == '¥ ';

    return InputDecoration(
      hintText: hint,
      prefixIcon: isPricePrefix
          ? const _PricePrefixSymbol(
              fontSize: _marketFormFontSize,
              leftPadding: 0,
            )
          : null,
      prefixIconConstraints: isPricePrefix
          ? const BoxConstraints(minWidth: 34, minHeight: 32)
          : null,
      prefixText: isPricePrefix ? null : prefixText,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      isDense: true,
      contentPadding:
          isPricePrefix ? const EdgeInsets.only(top: 3) : EdgeInsets.zero,
      hintStyle: TextStyle(
        fontSize: _marketFormFontSize,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
      prefixStyle: TextStyle(
        fontSize: _marketFormFontSize,
        fontWeight: FontWeight.w800,
        color:
            prefixText == '¥ ' ? _marketAccent : colorScheme.onSurfaceVariant,
      ),
    );
  }

  InputDecoration _plainInputDecoration({
    required String hint,
    String? prefixText,
    IconData? suffixIcon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPricePrefix = prefixText == '¥ ';

    return InputDecoration(
      hintText: hint,
      prefixIcon: isPricePrefix
          ? const _PricePrefixSymbol(fontSize: 22, leftPadding: 16)
          : null,
      prefixIconConstraints: isPricePrefix
          ? const BoxConstraints(minWidth: 50, minHeight: 48)
          : null,
      prefixText: isPricePrefix ? null : prefixText,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      hintStyle: TextStyle(
        fontSize: 15,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.78),
        fontWeight: FontWeight.w500,
      ),
      prefixStyle: TextStyle(
        fontSize: prefixText == '¥ ' ? 22 : 15,
        color:
            prefixText == '¥ ' ? _marketAccent : colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w800,
      ),
      suffixIcon: suffixIcon == null
          ? null
          : Icon(
              suffixIcon,
              size: 26,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
    );
  }
}

class _ShakingAttention extends StatelessWidget {
  final bool active;
  final Animation<double> controller;
  final Widget child;

  const _ShakingAttention({
    required this.active,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!active) return child;

    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final progress = controller.value;
        final offset = math.sin(progress * math.pi * 8) * (1 - progress) * 7;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: child,
        );
      },
    );
  }
}

class _PricePrefixSymbol extends StatelessWidget {
  final double fontSize;
  final double leftPadding;

  const _PricePrefixSymbol({
    required this.fontSize,
    required this.leftPadding,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: leftPadding, right: 8),
      child: Align(
        widthFactor: 1,
        alignment: Alignment.center,
        child: Transform.translate(
          offset: const Offset(0, -1.0),
          child: Text(
            '¥',
            style: TextStyle(
              color: _MarketPublishFormState._marketAccent,
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

class _CampusLineArtPainter extends CustomPainter {
  final Color color;

  const _CampusLineArtPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;
    final baseY = h * 0.78;
    final centerX = w * 0.56;
    final towerW = w * 0.18;
    final wingW = w * 0.20;
    final bodyTop = h * 0.34;
    final roofTop = h * 0.13;

    canvas.drawLine(Offset(w * 0.04, baseY), Offset(w * 0.96, baseY), paint);

    final tower = RRect.fromRectAndRadius(
      Rect.fromLTWH(centerX - towerW / 2, bodyTop, towerW, baseY - bodyTop),
      const Radius.circular(3),
    );
    canvas.drawRRect(tower, paint);
    canvas.drawPath(
      Path()
        ..moveTo(centerX - towerW * 0.58, bodyTop)
        ..lineTo(centerX, roofTop)
        ..lineTo(centerX + towerW * 0.58, bodyTop),
      paint,
    );
    canvas.drawLine(Offset(centerX, roofTop), Offset(centerX, h * 0.04), paint);

    final leftWing = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        centerX - towerW / 2 - wingW,
        h * 0.46,
        wingW,
        baseY - h * 0.46,
      ),
      const Radius.circular(3),
    );
    final rightWing = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        centerX + towerW / 2,
        h * 0.46,
        wingW,
        baseY - h * 0.46,
      ),
      const Radius.circular(3),
    );
    canvas
      ..drawRRect(leftWing, paint)
      ..drawRRect(rightWing, paint);

    final clockPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9;
    canvas.drawCircle(Offset(centerX, h * 0.40), towerW * 0.17, clockPaint);

    for (final dx in [-0.13, 0.13]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(centerX + w * dx, h * 0.58),
            width: w * 0.045,
            height: h * 0.12,
          ),
          const Radius.circular(2),
        ),
        paint,
      );
    }
    for (final dx in [-0.27, -0.20, 0.20, 0.27]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(centerX + w * dx, h * 0.61),
            width: w * 0.035,
            height: h * 0.12,
          ),
          const Radius.circular(2),
        ),
        paint,
      );
    }

    final door = RRect.fromRectAndRadius(
      Rect.fromLTWH(centerX - towerW * 0.17, h * 0.63, towerW * 0.34, h * 0.15),
      const Radius.circular(5),
    );
    canvas.drawRRect(door, paint);
  }

  @override
  bool shouldRepaint(covariant _CampusLineArtPainter oldDelegate) {
    return color != oldDelegate.color;
  }
}
