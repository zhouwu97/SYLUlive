import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen_dish.dart';
import '../models/canteen_review.dart';
import '../models/canteen_review_draft.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../services/canteen_review_draft_repository.dart';
import '../theme/app_colors.dart';
import '../widgets/canteen/canteen_review_image_picker.dart';
import '../widgets/canteen/canteen_theme.dart';
import 'canteen_dish_detail_screen.dart' show showDishPhotoUploadSheet;

const List<({String key, String label})> kCanteenTagOptions = [
  (key: 'taste_good', label: '味道不错'),
  (key: 'portion_enough', label: '分量足'),
  (key: 'price_fair', label: '价格合适'),
  (key: 'serving_fast', label: '出餐快'),
  (key: 'queue_long', label: '排队久'),
  (key: 'recommended_window', label: '推荐窗口'),
  (key: 'clean', label: '卫生干净'),
  (key: 'service_warm', label: '服务热情'),
  (key: 'environment_clean', label: '环境整洁'),
  (key: 'good_value', label: '性价比高'),
];

/// 商家评价编辑器全屏页面。
///
/// 具备星级打分、体验标签、200字输入、3张图片上传状态机、推荐菜品选择、
/// 跨账号隔离草稿存储、防抖与生命周期自动保存、多端冲突检测与退出保护。
enum CanteenReviewEditorMode { create, edit }

class CanteenReviewEditorScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  final String? canteenImage;
  final double averageStar;
  final int ratingCount;
  final int dishCount;
  final int dishPhotoCount;
  final CanteenReviewEditorMode mode;
  final Map<String, dynamic>? existingReview;
  final CanteenReviewDraftRepository? draftRepositoryOverride;

  const CanteenReviewEditorScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
    this.canteenImage,
    this.averageStar = 0,
    this.ratingCount = 0,
    this.dishCount = 0,
    this.dishPhotoCount = 0,
    this.mode = CanteenReviewEditorMode.create,
    this.existingReview,
    this.draftRepositoryOverride,
  }) : assert(
          mode == CanteenReviewEditorMode.edit
              ? existingReview != null
              : existingReview == null,
          '创建态不能传入 existingReview，编辑态必须传入 existingReview',
        );

  @override
  State<CanteenReviewEditorScreen> createState() =>
      _CanteenReviewEditorScreenState();
}

enum _DraftSaveStatus { idle, saving, saved }

class _CanteenReviewEditorScreenState extends State<CanteenReviewEditorScreen>
    with WidgetsBindingObserver {
  late final CanteenReviewDraftRepository _draftRepo;
  late final TextEditingController _commentController;
  late final TextEditingController _dishInputController;

  int _star = 0;
  // 仅用于旧版星级草稿/历史评价的展示，不参与 V2 请求的五维评分。
  CanteenReviewDimensions _dimensions = const CanteenReviewDimensions();
  List<String> _selectedTags = [];
  List<String> _recommendedDishes = [];
  List<CanteenReviewDraftImage> _draftImages = [];
  List<CanteenDish> _allDishes = [];
  List<CanteenDishSuggestion> _dishSuggestions = [];
  final Map<int, CanteenDishReviewInput> _dishReviews = {};
  final Map<int, String> _dishReviewNames = {};
  final Map<String, int> _selectedDishIds = {};

  bool _isSubmitting = false;
  _DraftSaveStatus _saveStatus = _DraftSaveStatus.idle;
  Timer? _debounceTimer;
  Timer? _dishSuggestionTimer;
  Timer? _statusTimer;
  final Set<Future<void>> _draftSavesInFlight = {};
  bool _draftWritesBlocked = false;

  bool _isDirty = false;
  DateTime? _baseRatingUpdatedAt;

  int get _userId {
    final user = context.read<AuthProvider>().user;
    return user?.id ?? 0;
  }

  bool get _isEditing => widget.mode == CanteenReviewEditorMode.edit;

  int? get _existingReviewId {
    final raw = widget.existingReview?['review_event_id'] ??
        widget.existingReview?['latest_review_event_id'];
    return raw is num ? raw.toInt() : int.tryParse('$raw');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _draftRepo =
        widget.draftRepositoryOverride ?? const CanteenReviewDraftRepository();
    _commentController = TextEditingController();
    _commentController.addListener(_onFormChanged);
    _dishInputController = TextEditingController();

    _initFormAndDraft();
    _loadDishesQuietly();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _dishSuggestionTimer?.cancel();
    _statusTimer?.cancel();
    _commentController.dispose();
    _dishInputController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveDraftNow();
    }
  }

  Future<void> _initFormAndDraft() async {
    final userId = _userId;
    if (userId <= 0) return;

    final existing = widget.existingReview;
    if (existing != null) {
      _baseRatingUpdatedAt =
          DateTime.tryParse(existing['updated_at']?.toString() ?? '');
    }

    final draft = await _draftRepo.loadDraft(
      userId: userId,
      canteenId: widget.canteenId,
      mode: _isEditing ? 'edit' : 'create',
      reviewEventId: _isEditing ? _existingReviewId : null,
    );

    if (!mounted) return;

    // Case A: 新建评价 + 发现草稿
    if (!_isEditing && draft != null) {
      _applyDraft(draft);
      _showDraftRestoredToast(
        draft.updatedAt,
        requiresDimensionCompletion: !draftDimensionsAreComplete(draft),
      );
      return;
    }

    // Case B: 修改评价 + 无本地草稿
    if (_isEditing && draft == null) {
      _applyExistingRating(existing!);
      return;
    }

    // Case C & D: 修改评价 + 有本地草稿
    if (_isEditing && draft != null) {
      final remoteUpdated = _baseRatingUpdatedAt;
      final draftBaseUpdated = draft.baseRatingUpdatedAt;

      if (remoteUpdated != null &&
          draftBaseUpdated != null &&
          remoteUpdated.isAfter(draftBaseUpdated)) {
        // Case D: 远端在其他设备更新过，冲突提示
        _showConflictDialog(draft, existing!);
      } else {
        // Case C: 草稿基于当前版本，恢复草稿
        _applyDraft(draft);
        _showDraftRestoredToast(
          draft.updatedAt,
          requiresDimensionCompletion: !draftDimensionsAreComplete(draft),
        );
      }
      return;
    }
  }

  void _applyDraft(CanteenReviewDraft draft, {DateTime? rebaseTo}) {
    setState(() {
      // star 只为旧草稿/旧客户端保留，V2 编辑状态不再把它当作五维评分来源。
      _star = draft.star;
      _dimensions = CanteenReviewDimensions(
        taste: draft.tasteScore,
        value: draft.valueScore,
        queue: draft.queueScore,
        hygiene: draft.hygieneScore,
        service: draft.serviceScore,
      );
      _commentController.text = draft.comment;
      _selectedTags = List.from(draft.tags);
      _recommendedDishes = List.from(draft.recommendedDishes);
      _selectedDishIds
        ..clear()
        ..addEntries(
          draft.dishReviews
              .where((item) => item.dishId > 0 && item.name.trim().isNotEmpty)
              .map((item) => MapEntry(item.name.toLowerCase(), item.dishId)),
        );
      _dishReviews
        ..clear()
        ..addEntries(
          draft.dishReviews.map(
            (item) => MapEntry(
              item.dishId,
              CanteenDishReviewInput(
                dishId: item.dishId,
                taste: item.taste,
                value: item.value,
                portion: item.portion,
                comment: item.comment,
              ),
            ),
          ),
        );
      _dishReviewNames
        ..clear()
        ..addEntries(
            draft.dishReviews.map((item) => MapEntry(item.dishId, item.name)));
      _draftImages = List.from(draft.images);
      _baseRatingUpdatedAt = rebaseTo ?? draft.baseRatingUpdatedAt;
      _isDirty = false;
    });
  }

  void _applyExistingRating(Map<String, dynamic> existing) {
    final star = (existing['star'] as num?)?.toInt() ?? 0;
    final dimensions = _dimensionsFromJson(existing);
    final comment = existing['comment']?.toString() ?? '';
    final imagesList = _parseImagesList(existing['images']);
    final tagsList = _parseTagsList(existing['tags']);
    final dishNames = _parseDishNames(existing);
    final dishReviews = _parseDishReviews(existing);

    setState(() {
      _star = star;
      _dimensions = dimensions;
      _commentController.text = comment;
      _selectedTags = tagsList;
      _recommendedDishes = dishNames;
      _selectedDishIds
        ..clear()
        ..addEntries(_recommendedDishIdNames(existing));
      _dishReviews
        ..clear()
        ..addEntries(dishReviews.map((item) => MapEntry(item.dishId, item)));
      _dishReviewNames
        ..clear()
        ..addEntries(dishReviews.map((item) =>
            MapEntry(item.dishId, _dishNameForId(existing, item.dishId))));
      _draftImages = imagesList
          .map((url) => CanteenReviewDraftImage(
                type: ReviewDraftImageType.publishedRemote,
                url: url,
              ))
          .toList();
      _isDirty = false;
    });
  }

  List<CanteenDishReviewInput> _parseDishReviews(
      Map<String, dynamic> existing) {
    final raw = existing['dish_reviews'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) {
          final data = Map<String, dynamic>.from(item);
          return CanteenDishReviewInput(
            dishId: (data['dish_id'] as num?)?.toInt() ?? 0,
            taste: (data['taste_score'] as num?)?.toInt() ??
                (data['taste'] as num?)?.toInt() ??
                0,
            value: (data['value_score'] as num?)?.toInt() ??
                (data['value'] as num?)?.toInt() ??
                0,
            portion: (data['portion_score'] as num?)?.toInt() ??
                (data['portion'] as num?)?.toInt() ??
                0,
            comment: data['comment']?.toString() ?? '',
          );
        })
        .where((item) => item.dishId > 0)
        .toList();
  }

  List<CanteenReviewDraftDishReview> get _draftDishReviews =>
      _dishReviews.values.map((review) {
        final name = _allDishes
                .where((dish) => dish.id == review.dishId)
                .map((dish) => dish.name)
                .firstOrNull ??
            _dishReviewNames[review.dishId] ??
            _recommendedDishes
                .where((dish) => _findDish(dish)?.id == review.dishId)
                .firstOrNull ??
            '';
        return CanteenReviewDraftDishReview(
          dishId: review.dishId,
          name: name,
          taste: review.taste,
          value: review.value,
          portion: review.portion,
          comment: review.comment,
        );
      }).toList();

  CanteenReviewDimensions _dimensionsFromJson(Map<String, dynamic> json) {
    int score(String key) {
      final raw = json[key];
      if (raw is num) return raw.toInt();
      return int.tryParse('$raw') ?? 0;
    }

    return CanteenReviewDimensions(
      taste: score('taste_score'),
      value: score('value_score'),
      queue: score('queue_score'),
      hygiene: score('hygiene_score'),
      service: score('service_score'),
    );
  }

  bool draftDimensionsAreComplete(CanteenReviewDraft draft) {
    return draft.tasteScore > 0 &&
        draft.valueScore > 0 &&
        draft.queueScore > 0 &&
        draft.hygieneScore > 0 &&
        draft.serviceScore > 0;
  }

  List<String> _parseImagesList(dynamic raw) {
    if (raw == null || raw.toString().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  List<String> _parseTagsList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  List<String> _parseDishNames(Map<String, dynamic> existing) {
    final recs = existing['recommended_dishes'];
    if (recs is List) {
      return recs
          .map((e) {
            if (e is Map) return e['name']?.toString().trim() ?? '';
            return e.toString().trim();
          })
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return [];
  }

  String _dishNameForId(Map<String, dynamic> existing, int dishId) {
    final raw = existing['recommended_dishes'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map && (item['dish_id'] as num?)?.toInt() == dishId) {
          return item['name']?.toString() ?? '';
        }
      }
    }
    return '';
  }

  Iterable<MapEntry<String, int>> _recommendedDishIdNames(
      Map<String, dynamic> existing) sync* {
    final raw = existing['recommended_dishes'];
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name']?.toString().trim() ?? '';
      final dishId = (item['dish_id'] as num?)?.toInt() ?? 0;
      if (name.isNotEmpty && dishId > 0) {
        yield MapEntry(name.toLowerCase(), dishId);
      }
    }
  }

  void _showDraftRestoredToast(
    DateTime updatedAt, {
    bool requiresDimensionCompletion = false,
  }) {
    final timeStr =
        '${updatedAt.hour.toString().padLeft(2, '0')}:${updatedAt.minute.toString().padLeft(2, '0')}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(requiresDimensionCompletion
            ? '已恢复 $timeStr 保存的草稿，请补全五项评分'
            : '已恢复 $timeStr 保存的草稿'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showConflictDialog(
    CanteenReviewDraft draft,
    Map<String, dynamic> existing,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final remoteUpdated = _baseRatingUpdatedAt;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: CanteenTheme.surfaceBg(isDark),
        title: Text(
          '发现评价冲突',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: CanteenTheme.textPrimaryColor(isDark),
          ),
        ),
        content: Text(
          '你的评价在其他设备已有更新。是否恢复本地草稿并基于最新版本继续编辑？',
          style: TextStyle(
            fontSize: 14,
            color: CanteenTheme.textSecondaryColor(isDark),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              _applyExistingRating(existing);
            },
            child: const Text('使用最新已发布评价'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              _applyDraft(draft, rebaseTo: remoteUpdated);
            },
            child: const Text('恢复本机草稿'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadDishesQuietly() async {
    final dishes =
        await context.read<CanteenProvider>().loadDishes(widget.canteenId);
    if (!mounted) return;
    setState(() {
      _allDishes = dishes ?? [];
    });
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() => _isDirty = true);
    } else {
      _isDirty = true;
    }
    _scheduleAutosave();
  }

  void _scheduleAutosave() {
    _debounceTimer?.cancel();
    if (_saveStatus != _DraftSaveStatus.saving) {
      setState(() => _saveStatus = _DraftSaveStatus.saving);
    }
    _debounceTimer = Timer(const Duration(milliseconds: 700), () {
      _saveDraftNow();
    });
  }

  Future<void> _saveDraftNow() {
    final save = _saveDraftInternal();
    _draftSavesInFlight.add(save);
    save.then<void>(
      (_) {
        _draftSavesInFlight.remove(save);
      },
      onError: (Object error, StackTrace stackTrace) {
        _draftSavesInFlight.remove(save);
      },
    );
    return save;
  }

  Future<void> _waitForDraftSaves() async {
    while (_draftSavesInFlight.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_draftSavesInFlight));
    }
  }

  Future<void> _saveDraftInternal() async {
    _debounceTimer?.cancel();
    final userId = _userId;
    if (userId <= 0 || _isSubmitting || _draftWritesBlocked) return;

    final draft = CanteenReviewDraft(
      userId: userId,
      canteenId: widget.canteenId,
      mode: _isEditing ? 'edit' : 'create',
      reviewEventId: _isEditing ? _existingReviewId : null,
      // star 只为旧草稿读取兼容保留；V2 提交使用下方五个显式维度。
      star: _star,
      tasteScore: _dimensions.taste,
      valueScore: _dimensions.value,
      queueScore: _dimensions.queue,
      hygieneScore: _dimensions.hygiene,
      serviceScore: _dimensions.service,
      comment: _commentController.text,
      tags: _selectedTags,
      recommendedDishes: _recommendedDishes,
      dishReviews: _draftDishReviews,
      images: _draftImages,
      updatedAt: DateTime.now(),
      baseRatingUpdatedAt: _baseRatingUpdatedAt,
    );

    if (_isSubmitting || _draftWritesBlocked) return;
    await _draftRepo.saveDraft(draft);
    if (!mounted) return;
    setState(() => _saveStatus = _DraftSaveStatus.saved);
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _saveStatus == _DraftSaveStatus.saved) {
        setState(() => _saveStatus = _DraftSaveStatus.idle);
      }
    });
  }

  // ── 退出保护 ──────────────────────────────────────────────────

  Future<void> _handleExit() async {
    if (_isSubmitting) return;

    final isFormClean = _dimensions.taste == 0 &&
        _dimensions.value == 0 &&
        _dimensions.queue == 0 &&
        _dimensions.hygiene == 0 &&
        _dimensions.service == 0 &&
        _commentController.text.trim().isEmpty &&
        _selectedTags.isEmpty &&
        _recommendedDishes.isEmpty &&
        _draftImages.isEmpty;

    if (isFormClean || !_isDirty) {
      Navigator.of(context).pop(false);
      return;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: CanteenTheme.borderColor(isDark),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '保存这次评价？',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '你填写的评分和内容还没有发布。',
                  style: TextStyle(
                    fontSize: 13,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    await _saveDraftNow();
                    if (!mounted) return;
                    Navigator.pop(sheetContext);
                    Navigator.of(context).pop(false);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: CanteenTheme.accentColor(isDark),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(CanteenTheme.radiusSm),
                    ),
                  ),
                  child: const Text('保存草稿并退出',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    await _draftRepo.deleteDraft(
                      userId: _userId,
                      canteenId: widget.canteenId,
                      mode: _isEditing ? 'edit' : 'create',
                      reviewEventId: _isEditing ? _existingReviewId : null,
                    );
                    if (!mounted) return;
                    Navigator.pop(sheetContext);
                    Navigator.of(context).pop(false);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    minimumSize: const Size.fromHeight(46),
                    side: BorderSide(color: CanteenTheme.borderColor(isDark)),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(CanteenTheme.radiusSm),
                    ),
                  ),
                  child: const Text('放弃本次修改'),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    '继续编辑',
                    style: TextStyle(
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 发布状态机 ──────────────────────────────────────────────────

  Future<void> _submitReview() async {
    if (_isSubmitting) return;

    // 发布过程中禁止延迟自动保存把已成功清除的旧草稿重新写回来。
    _debounceTimer?.cancel();
    _statusTimer?.cancel();

    final missingLocalImage = _draftImages.any(
      (image) =>
          image.type == ReviewDraftImageType.localPending &&
          image.localPath != null &&
          !File(image.localPath!).existsSync(),
    );
    if (missingLocalImage) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿中的图片本地文件已丢失，请重新选择或删除该图片后发布')),
      );
      return;
    }

    if (!_dimensions.isComplete) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先为商家打个分吧')),
      );
      return;
    }

    final existingScoreVersion =
        (widget.existingReview?['score_version'] as num?)?.toInt() ?? 0;
    if (_isEditing &&
        (_existingReviewId == null ||
            (existingScoreVersion != 0 && existingScoreVersion < 2))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条评价不是可修改的新版评价，请从最近一条评价重新进入')),
      );
      return;
    }

    // 只有已经存在并被服务端确认的菜品才能建立推荐关系；模糊候选只提示，
    // 自由输入必须先通过“带照片的菜品投稿”进入审核，不能在评价提交时静默丢失。
    final unresolvedDishes = _recommendedDishes
        .where((name) => _findDish(name) == null)
        .toList(growable: false);
    if (unresolvedDishes.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('“${unresolvedDishes.first}”尚未收录，请先上传菜品照片并等待审核')),
      );
      return;
    }

    final partialDishReviews = _dishReviews.values
        .where((review) =>
            (review.taste > 0 || review.value > 0 || review.portion > 0) &&
            !(review.taste >= 1 && review.value >= 1 && review.portion >= 1))
        .toList(growable: false);
    if (partialDishReviews.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请补全已开始评分的菜品三项评分，或清空后再提交')),
      );
      return;
    }

    _draftWritesBlocked = true;
    setState(() => _isSubmitting = true);

    final authProvider = context.read<AuthProvider>();
    final canteenProvider = context.read<CanteenProvider>();
    final dio = authProvider.dio;
    final finalImages = <String>[];

    // 1. 上传本地待上传图片（断线重试状态机保护）
    final updatedDraftImages = List<CanteenReviewDraftImage>.from(_draftImages);
    var hasUploadError = false;

    for (var i = 0; i < updatedDraftImages.length; i++) {
      final img = updatedDraftImages[i];

      if (img.type == ReviewDraftImageType.publishedRemote &&
          img.url != null &&
          img.url!.isNotEmpty) {
        finalImages.add(img.url!);
      } else if (img.type == ReviewDraftImageType.uploadedPending &&
          img.url != null &&
          img.url!.isNotEmpty) {
        finalImages.add(img.url!);
      } else if (img.type == ReviewDraftImageType.localPending &&
          img.localPath != null) {
        try {
          final file = File(img.localPath!);
          if (!file.existsSync()) {
            hasUploadError = true;
            if (mounted) {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('草稿中的图片本地文件已丢失，请重新选择或删除该图片后发布')),
              );
            }
            break;
          }

          final bytes = await file.readAsBytes();
          final fileName = img.localPath!.split(Platform.pathSeparator).last;
          final formData = FormData.fromMap({
            'file': MultipartFile.fromBytes(bytes, filename: fileName),
          });

          final uploadResp = await dio.post(
            '/upload',
            data: formData,
            options: Options(
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

          if (uploadResp.statusCode == 200 &&
              uploadResp.data != null &&
              uploadResp.data['url'] != null) {
            final url = uploadResp.data['url'].toString();
            final fileId = (uploadResp.data['file_id'] as num?)?.toInt();

            final uploadedImg = img.copyWith(
              type: ReviewDraftImageType.uploadedPending,
              fileId: fileId,
              url: url,
            );
            updatedDraftImages[i] = uploadedImg;
            finalImages.add(url);

            // 每张上传成功立即暂存进度，以便失败后重试不用重传
            setState(() => _draftImages = updatedDraftImages);
            await _draftRepo.saveDraft(
              CanteenReviewDraft(
                userId: _userId,
                canteenId: widget.canteenId,
                mode: _isEditing ? 'edit' : 'create',
                reviewEventId: _isEditing ? _existingReviewId : null,
                star: _star,
                tasteScore: _dimensions.taste,
                valueScore: _dimensions.value,
                queueScore: _dimensions.queue,
                hygieneScore: _dimensions.hygiene,
                serviceScore: _dimensions.service,
                comment: _commentController.text,
                tags: _selectedTags,
                recommendedDishes: _recommendedDishes,
                dishReviews: _draftDishReviews,
                images: updatedDraftImages,
                updatedAt: DateTime.now(),
                baseRatingUpdatedAt: _baseRatingUpdatedAt,
              ),
            );
          } else {
            hasUploadError = true;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('部分图片上传失败，请检查网络后重试')),
              );
            }
            break;
          }
        } catch (e) {
          debugPrint('Error uploading draft image during submit: $e');
          hasUploadError = true;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('部分图片上传失败，请检查网络后重试')),
            );
          }
          break;
        }
      }
    }

    if (hasUploadError) {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
      return;
    }

    // 创建态永远新增 ReviewEvent；只有显式编辑态才 PATCH 最近一条 V2 评价。
    final result = _isEditing
        ? await canteenProvider.updateReview(
            _existingReviewId!,
            dimensions: _dimensions,
            comment: _commentController.text.trim(),
            images: finalImages,
            tags: _selectedTags,
            dishIds: _recommendedDishIds,
            dishNames: _recommendedDishes,
            dishReviews: _completedDishReviews,
            baseUpdatedAt: _baseRatingUpdatedAt,
          )
        : await canteenProvider.submitReview(
            widget.canteenId,
            dimensions: _dimensions,
            comment: _commentController.text.trim(),
            images: finalImages,
            tags: _selectedTags,
            dishIds: _recommendedDishIds,
            dishNames: _recommendedDishes,
            dishReviews: _completedDishReviews,
            baseUpdatedAt: _baseRatingUpdatedAt,
          );

    if (!mounted) return;
    if (result.success) {
      // 3. 发布成功：清除草稿与本地草稿图片目录
      await _waitForDraftSaves();
      await _draftRepo.deleteDraft(
        userId: _userId,
        canteenId: widget.canteenId,
        mode: _isEditing ? 'edit' : 'create',
        reviewEventId: _isEditing ? _existingReviewId : null,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEditing ? '评价已更新' : '评价发布成功'),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } else {
      setState(() => _isSubmitting = false);
      _draftWritesBlocked = false;
      if ((result.errorCode == 'review_conflict' ||
              result.errorCode == 'rating_conflict') &&
          mounted) {
        if (result.remoteUpdatedAt != null) {
          _baseRatingUpdatedAt = result.remoteUpdatedAt;
        }
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final resolveAction = await showDialog<String>(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            backgroundColor: CanteenTheme.surfaceBg(isDark),
            title: Text(
              '评价版本冲突',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: CanteenTheme.textPrimaryColor(isDark),
              ),
            ),
            content: Text(
              '当前评价已在其他设备更新。你可以选择强制覆盖为当前内容，或保留当前草稿并退出。',
              style: TextStyle(
                fontSize: 14,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, 'save_and_exit'),
                child: const Text('保留草稿并退出'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogCtx, 'overwrite'),
                child: const Text('强制覆盖'),
              ),
            ],
          ),
        );

        if (resolveAction == 'overwrite') {
          _baseRatingUpdatedAt = null;
          await _submitReview();
          return;
        } else if (resolveAction == 'save_and_exit' && mounted) {
          await _saveDraftNow();
          if (mounted) {
            Navigator.of(context).pop(false);
          }
          return;
        }
      }

      final errMsg =
          result.errorMessage ?? canteenProvider.errorMessage ?? '提交失败，请稍后重试';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errMsg)),
      );
    }
  }

  List<int> get _recommendedDishIds => _recommendedDishes
      .map(
          (name) => _selectedDishIds[name.toLowerCase()] ?? _findDish(name)?.id)
      .whereType<int>()
      .toList(growable: false);

  List<CanteenDishReviewInput> get _completedDishReviews => _dishReviews.values
      .where((review) =>
          review.taste >= 1 && review.value >= 1 && review.portion >= 1)
      .toList(growable: false);

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleExit();
      },
      child: Scaffold(
        backgroundColor: CanteenTheme.pageBg(isDark),
        appBar: _buildAppBar(isDark),
        bottomNavigationBar: _buildBottomBar(isDark, accent),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_isEditing) ...[
                _buildCreateNotice(isDark),
                const SizedBox(height: 16),
              ],
              _buildStarRatingCard(isDark, accent),
              const SizedBox(height: 16),
              _buildDishSectionCard(isDark, accent),
              const SizedBox(height: 16),
              _buildExperienceTagsCard(isDark, accent),
              const SizedBox(height: 16),
              _buildCommentInputCard(isDark),
              const SizedBox(height: 16),
              _buildPhotoSectionCard(isDark),
              const SizedBox(height: 16),
              _buildCreditNotice(isDark),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(bool isDark) {
    final String statusText;
    switch (_saveStatus) {
      case _DraftSaveStatus.saving:
        statusText = '保存中…';
        break;
      case _DraftSaveStatus.saved:
        statusText = '草稿已保存';
        break;
      case _DraftSaveStatus.idle:
        statusText = '保存草稿';
        break;
    }

    return AppBar(
      backgroundColor: CanteenTheme.pageBg(isDark),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        onPressed: _handleExit,
      ),
      title: Text(
        _isEditing ? '修改评价' : '发布评价',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: CanteenTheme.textPrimaryColor(isDark),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saveStatus == _DraftSaveStatus.saving
              ? null
              : () async {
                  await _saveDraftNow();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('草稿已保存'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                    Navigator.of(context).pop(false);
                  }
                },
          child: Text(
            statusText,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _saveStatus == _DraftSaveStatus.saving
                  ? CanteenTheme.textTertiaryColor(isDark)
                  : CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildCreateNotice(bool isDark) {
    return _buildNoticeSurface(
      isDark,
      icon: Icons.verified_user_outlined,
      color: AppColors.success,
      title: '可以再次评价',
      message: '历史评价会保留，但商家总分中每位同学最多贡献一个有效样本，避免重复刷分。',
    );
  }

  Widget _buildNoticeSurface(
    bool isDark, {
    required IconData icon,
    required Color color,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStarRatingCard(bool isDark, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark), width: 0.5),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '这次商家体验',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              Text(
                '五项均需填写',
                style: TextStyle(fontSize: 12, color: accent),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '五项都会影响本次综合体验分，提交前请全部填写。',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: CanteenTheme.borderColor(isDark)),
          const SizedBox(height: 14),
          _buildDimensionRow('味道', _dimensions.taste, isDark, (score) {
            _setDimension(_dimensions.copyWith(taste: score));
          }),
          _buildDimensionRow('性价比', _dimensions.value, isDark, (score) {
            _setDimension(_dimensions.copyWith(value: score));
          }),
          _buildDimensionRow('排队效率', _dimensions.queue, isDark, (score) {
            _setDimension(_dimensions.copyWith(queue: score));
          }),
          _buildDimensionRow('卫生环境', _dimensions.hygiene, isDark, (score) {
            _setDimension(_dimensions.copyWith(hygiene: score));
          }),
          _buildDimensionRow('服务态度', _dimensions.service, isDark, (score) {
            _setDimension(_dimensions.copyWith(service: score));
          }),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: CanteenTheme.accentSoftColor(isDark),
              borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  _dimensions.isComplete
                      ? _dimensions.overall.toStringAsFixed(2)
                      : '--',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.accentStrongColor(isDark),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '本次综合体验',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '味道35% · 性价比20%\n排队15% · 卫生20% · 服务10%',
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.35,
                      color: CanteenTheme.textTertiaryColor(isDark),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _setDimension(CanteenReviewDimensions next) {
    setState(() {
      _dimensions = next;
      // 只保留旧草稿的兼容快照，不能再把它作为 V2 评分提交。
      _star = next.taste;
    });
    _onFormChanged();
  }

  Widget _buildDimensionRow(
    String label,
    int selected,
    bool isDark,
    ValueChanged<int> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 评分按钮保留 44dp 触控热区；窄屏时允许按钮自然换行，避免挤压出屏。
          final labelWidth = constraints.maxWidth < 360 ? 64.0 : 88.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 4,
                  children: List.generate(5, (index) {
                    final score = index + 1;
                    final active = score == selected;
                    return SizedBox(
                      width: 44,
                      height: 44,
                      child: InkWell(
                        onTap: _isSubmitting ? null : () => onChanged(score),
                        borderRadius: BorderRadius.circular(6),
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: 28,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: active
                                  ? CanteenTheme.accentSoftColor(isDark)
                                  : CanteenTheme.surfaceMutedBg(isDark),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: active
                                    ? CanteenTheme.accentColor(isDark)
                                    : CanteenTheme.borderColor(isDark),
                              ),
                            ),
                            child: Text(
                              '$score',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight:
                                    active ? FontWeight.w700 : FontWeight.w500,
                                color: active
                                    ? CanteenTheme.accentStrongColor(isDark)
                                    : CanteenTheme.textSecondaryColor(isDark),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 30,
                child: Text(
                  selected > 0 ? '$selected.0' : '--',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected > 0
                        ? CanteenTheme.textSecondaryColor(isDark)
                        : CanteenTheme.textTertiaryColor(isDark),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildExperienceTagsCard(bool isDark, Color accent) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '本次体验标签（可选）',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              Text(
                '${_selectedTags.length}/6',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: kCanteenTagOptions.map((opt) {
              final isSelected = _selectedTags.contains(opt.key);
              return GestureDetector(
                onTap: _isSubmitting
                    ? null
                    : () {
                        if (isSelected) {
                          setState(() => _selectedTags.remove(opt.key));
                          _onFormChanged();
                        } else {
                          if (_selectedTags.length >= 6) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('最多选择 6 个体验标签')),
                            );
                            return;
                          }
                          setState(() => _selectedTags.add(opt.key));
                          _onFormChanged();
                        }
                      },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? CanteenTheme.accentSoftColor(isDark)
                        : CanteenTheme.surfaceMutedBg(isDark),
                    borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                    border: Border.all(
                      color: isSelected
                          ? accent.withValues(alpha: 0.5)
                          : Colors.transparent,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        opt.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w500,
                          color: isSelected
                              ? CanteenTheme.accentStrongColor(isDark)
                              : CanteenTheme.textPrimaryColor(isDark),
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: CanteenTheme.accentStrongColor(isDark),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentInputCard(bool isDark) {
    final textLength = _commentController.text.characters.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '补充评价',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              Text(
                '$textLength / 200',
                style: TextStyle(
                  fontSize: 12,
                  color: textLength >= 200
                      ? Colors.redAccent
                      : CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _commentController,
            maxLength: 200,
            maxLines: 5,
            minLines: 4,
            enabled: !_isSubmitting,
            decoration: InputDecoration(
              counterText: '',
              hintText: '比如：几点去的、排了多久、味道和之前有什么变化……',
              hintStyle: TextStyle(
                fontSize: 13,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
              filled: true,
              fillColor: CanteenTheme.surfaceMutedBg(isDark),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(14),
            ),
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDishSectionCard(bool isDark, Color accent) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '这次吃了什么',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              Text(
                '${_recommendedDishes.length} / 3',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildDishRecommendationSection(isDark, accent),
        ],
      ),
    );
  }

  Widget _buildPhotoSectionCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '实拍图片',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              Text(
                '最多 3 张',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '图片会进入对应菜品的实拍图候选库，最多上传 3 张。',
            style: TextStyle(
              fontSize: 12,
              color: CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
          const SizedBox(height: 12),
          CanteenReviewImagePicker(
            images: _draftImages,
            userId: _userId,
            canteenId: widget.canteenId,
            draftMode: _isEditing ? 'edit' : 'create',
            draftReviewEventId: _isEditing ? _existingReviewId : null,
            draftRepository: _draftRepo,
            enabled: !_isSubmitting,
            onImagesChanged: (nextImages) {
              setState(() => _draftImages = nextImages);
              _onFormChanged();
            },
          ),
        ],
      ),
    );
  }

  void _addRecommendedDish(String rawName, {int? dishId}) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) return;

    final resolvedDishId = dishId ?? _findDish(trimmed)?.id;

    // 自由输入只用于查找候选，不直接制造一个无法落库的菜名。
    // 新菜请从菜品页上传至少一张照片，进入 pending 审核后再回来选择。
    if (resolvedDishId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该菜品尚未收录，请先上传菜品照片并等待审核')),
      );
      _openNewDishSubmission(trimmed);
      return;
    }

    if (_recommendedDishes.length >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多只能推荐 3 道菜品')),
      );
      return;
    }

    if (trimmed.length > 30) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('菜名长度不能超过 30 个字')),
      );
      return;
    }

    final isDuplicate = _recommendedDishes.any(
      (d) => d.toLowerCase() == trimmed.toLowerCase(),
    );
    if (isDuplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加该推荐菜品')),
      );
      return;
    }

    setState(() {
      _recommendedDishes.add(trimmed);
      _selectedDishIds[trimmed.toLowerCase()] = resolvedDishId;
      _dishReviews.putIfAbsent(
        resolvedDishId,
        () => CanteenDishReviewInput(
          dishId: resolvedDishId,
          taste: 0,
          value: 0,
          portion: 0,
        ),
      );
      _dishInputController.clear();
      _dishSuggestions = [];
    });
    _onFormChanged();
  }

  Future<void> _openNewDishSubmission(String dishName) async {
    final submitted = await showDishPhotoUploadSheet(
      context,
      canteenId: widget.canteenId,
      dishName: dishName,
      provider: context.read<CanteenProvider>(),
    );
    if (submitted == true && mounted) {
      await _loadDishesQuietly();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('菜品已提交审核，通过后可在评价中选择推荐')),
      );
    }
  }

  void _removeRecommendedDish(int index) {
    if (index < 0 || index >= _recommendedDishes.length) return;
    setState(() {
      final removed = _recommendedDishes.removeAt(index);
      final removedId = _selectedDishIds.remove(removed.toLowerCase()) ??
          _findDish(removed)?.id;
      if (removedId != null) {
        _dishReviews.remove(removedId);
        _dishReviewNames.remove(removedId);
      }
    });
    _onFormChanged();
  }

  void _onDishInputChanged(String value) {
    _dishSuggestionTimer?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      if (mounted) setState(() => _dishSuggestions = []);
      return;
    }
    _dishSuggestionTimer = Timer(const Duration(milliseconds: 280), () async {
      final suggestions = await context
          .read<CanteenProvider>()
          .suggestDishes(widget.canteenId, query);
      if (mounted && suggestions != null) {
        setState(() => _dishSuggestions = suggestions);
      }
    });
  }

  void _updateDishReview(CanteenDish dish,
      {int? taste, int? value, int? portion}) {
    final current = _dishReviews[dish.id] ??
        CanteenDishReviewInput(dishId: dish.id, taste: 0, value: 0, portion: 0);
    setState(() {
      _dishReviews[dish.id] = CanteenDishReviewInput(
        dishId: dish.id,
        taste: taste ?? current.taste,
        value: value ?? current.value,
        portion: portion ?? current.portion,
        comment: current.comment,
      );
    });
    _onFormChanged();
  }

  CanteenDish? _findDish(String name) {
    for (final dish in _allDishes) {
      if (dish.name.toLowerCase() == name.toLowerCase()) return dish;
    }
    return null;
  }

  Widget _buildDishRecommendationSection(bool isDark, Color accent) {
    final unselectedDishes = _allDishes
        .where((d) => !_recommendedDishes
            .any((r) => r.toLowerCase() == d.name.toLowerCase()))
        .take(6)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 输入框（未达到3个时展示）
        if (_recommendedDishes.length < 3) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: CanteenTheme.surfaceMutedBg(isDark),
              borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
              border: Border.all(
                color: CanteenTheme.borderColor(isDark),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('canteen_dish_input'),
                    controller: _dishInputController,
                    textInputAction: TextInputAction.done,
                    onChanged: _onDishInputChanged,
                    onSubmitted: _addRecommendedDish,
                    style: TextStyle(
                      fontSize: 14,
                      color: CanteenTheme.textPrimaryColor(isDark),
                    ),
                    decoration: InputDecoration(
                      hintText: '搜索这次吃到的菜品',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: CanteenTheme.textTertiaryColor(isDark),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                GestureDetector(
                  key: const Key('canteen_dish_add_btn'),
                  onTap: () => _addRecommendedDish(_dishInputController.text),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius:
                          BorderRadius.circular(CanteenTheme.radiusSm),
                    ),
                    child: Icon(
                      Icons.add_rounded,
                      size: 18,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _isSubmitting
                  ? null
                  : () {
                      final name = _dishInputController.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('先输入菜名，再提交新菜')),
                        );
                        return;
                      }
                      _openNewDishSubmission(name);
                    },
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('没找到，提交新菜'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
          ),
        ],

        if (_dishSuggestions.isNotEmpty && _recommendedDishes.length < 3) ...[
          const SizedBox(height: 10),
          Text(
            _dishSuggestions.any((item) => item.isExact)
                ? '匹配到菜品（点击快速填入）'
                : '可能是这些菜（点击“就是这个”确认）',
            style: TextStyle(
              fontSize: 12,
              color: CanteenTheme.textTertiaryColor(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _dishSuggestions.take(6).map((suggestion) {
              return Semantics(
                button: true,
                label: '${suggestion.name}，点击确认绑定现有菜品',
                child: GestureDetector(
                  onTap: () => _addRecommendedDish(
                    suggestion.name,
                    dishId: suggestion.dishId > 0 ? suggestion.dishId : null,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: suggestion.isExact
                          ? CanteenTheme.accentSoftColor(isDark)
                          : CanteenTheme.surfaceMutedBg(isDark),
                      borderRadius:
                          BorderRadius.circular(CanteenTheme.radiusSm),
                      border: Border.all(
                        color: CanteenTheme.borderColor(isDark),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          suggestion.name,
                          style: TextStyle(
                            fontSize: 12,
                            color: suggestion.isExact
                                ? CanteenTheme.accentStrongColor(isDark)
                                : CanteenTheme.textSecondaryColor(isDark),
                          ),
                        ),
                        if (!suggestion.isExact) ...[
                          const SizedBox(width: 4),
                          Text(
                            '就是这个',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: CanteenTheme.accentStrongColor(isDark),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],

        // 2. 已添加的推荐菜标签（支持点 ❌ 删除）
        if (_recommendedDishes.isNotEmpty) ...[
          if (_recommendedDishes.length < 3) const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _recommendedDishes.length; i++)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: CanteenTheme.accentSoftColor(isDark),
                    borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.4),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _recommendedDishes[i],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: CanteenTheme.accentStrongColor(isDark),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => _removeRecommendedDish(i),
                        child: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: CanteenTheme.accentStrongColor(isDark),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ..._recommendedDishes.map((name) {
            final dish = _findDish(name);
            if (dish == null) return const SizedBox.shrink();
            final current = _dishReviews[dish.id] ??
                CanteenDishReviewInput(
                    dishId: dish.id, taste: 0, value: 0, portion: 0);
            return _buildDishReviewEditor(isDark, dish, current);
          }),
        ],

        // 3. 快捷推荐：本商家已有菜品（点击快速填入）
        if (_recommendedDishes.length < 3 && unselectedDishes.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '已有菜品（点击快速填入）：',
            style: TextStyle(
              fontSize: 12,
              color: CanteenTheme.textTertiaryColor(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final dish in unselectedDishes)
                GestureDetector(
                  onTap: () => _addRecommendedDish(dish.name),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: CanteenTheme.surfaceMutedBg(isDark),
                      borderRadius:
                          BorderRadius.circular(CanteenTheme.radiusSm),
                      border: Border.all(
                        color: CanteenTheme.borderColor(isDark),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          dish.name,
                          style: TextStyle(
                            fontSize: 12,
                            color: CanteenTheme.textSecondaryColor(isDark),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.add_rounded,
                          size: 13,
                          color: CanteenTheme.textSecondaryColor(isDark),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildDishReviewEditor(
    bool isDark,
    CanteenDish dish,
    CanteenDishReviewInput current,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '给「${dish.name}」评分（选填，三项需一起填写）',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
          _buildDishScoreRow('味道', current.taste, isDark, (score) {
            _updateDishReview(dish, taste: score);
          }),
          _buildDishScoreRow('性价比', current.value, isDark, (score) {
            _updateDishReview(dish, value: score);
          }),
          _buildDishScoreRow('分量', current.portion, isDark, (score) {
            _updateDishReview(dish, portion: score);
          }),
        ],
      ),
    );
  }

  Widget _buildDishScoreRow(
    String label,
    int selected,
    bool isDark,
    ValueChanged<int> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
            ),
          ),
          Wrap(
            spacing: 3,
            children: List.generate(5, (index) {
              final score = index + 1;
              final active = selected == score;
              return InkWell(
                onTap: _isSubmitting ? null : () => onChanged(score),
                borderRadius: BorderRadius.circular(5),
                child: Container(
                  width: 23,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active
                        ? CanteenTheme.accentSoftColor(isDark)
                        : CanteenTheme.surfaceBg(isDark),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: CanteenTheme.borderColor(isDark)),
                  ),
                  child: Text(
                    '$score',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active
                          ? CanteenTheme.accentStrongColor(isDark)
                          : CanteenTheme.textTertiaryColor(isDark),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildCreditNotice(bool isDark) {
    final user = context.watch<AuthProvider>().user;
    final creditScore = (user?.creditScore ?? 100).clamp(0, 100);
    final weight = 0.5 + 0.5 * (creditScore / 100.0);
    final weightStr = weight == 1.0 ? '1.0' : weight.toStringAsFixed(2);
    return _buildNoticeSurface(
      isDark,
      icon: Icons.verified_user_rounded,
      color: const Color(0xFF10B981),
      title: '你的诚信度 $creditScore · 权重约 $weightStr',
      message: '评价会公开展示校园昵称和头像。若发现异常评价，可在评价菜单中举报。',
    );
  }

  Widget _buildBottomBar(bool isDark, Color accent) {
    final bottom = MediaQuery.of(context).padding.bottom;
    // 旧版星级草稿仍允许进入提交校验流程（例如先提示丢失图片），但真正的
    // V2 请求仍会在 _submitReview 中要求五个显式维度完整。
    final canSubmit =
        (_dimensions.isComplete || _draftImages.isNotEmpty) && !_isSubmitting;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, bottom + 10),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        border: Border(
          top: BorderSide(
            color: CanteenTheme.borderColor(isDark),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: OutlinedButton(
              onPressed: _isSubmitting ? null : _handleExit,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: CanteenTheme.textPrimaryColor(isDark),
                side: BorderSide(color: CanteenTheme.borderColor(isDark)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                ),
              ),
              child: const Text('取消',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: FilledButton(
              onPressed: canSubmit ? _submitReview : null,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                ),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _isEditing ? '保存修改' : '发布评价',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
