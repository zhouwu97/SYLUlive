import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/emoji_favorite_service.dart';
import '../utils/text_editing_helper.dart';
import '../widgets/emoji/sticker_catalog.dart';

enum PostReplyBottomPanel {
  none,
  keyboard,
  emoji,
}

/// Emoji → Keyboard 切换时的内容连续性交接状态。
enum PostReplyInputHandoff { none, emojiToKeyboard }

class PostReplyDraft {
  const PostReplyDraft({
    required this.text,
    this.parentReplyId,
    this.replyToUserId,
    this.replyToReplyId,
    this.replyToName,
    this.sticker,
    this.favoriteImage,
    this.localImage,
  });

  final String text;
  final int? parentReplyId;
  final int? replyToUserId;
  final int? replyToReplyId;
  final String? replyToName;
  final AppSticker? sticker;
  final EmojiFavoriteItem? favoriteImage;
  final XFile? localImage;

  bool get isEmpty =>
      text.trim().isEmpty &&
      sticker == null &&
      favoriteImage == null &&
      localImage == null;
}

/// 统一维护帖子评论输入区的编辑状态。
class PostReplyComposerController extends ChangeNotifier {
  final TextEditingController textController = TextEditingController();
  final FocusNode focusNode = FocusNode();

  bool _isOpen = false;
  PostReplyBottomPanel _bottomPanel = PostReplyBottomPanel.none;
  double _stableKeyboardHeight = 300;
  double _keyboardInset = 0;
  double _lastKeyboardInset = 0;
  bool _hasObservedKeyboardHeight = false;
  PostReplyInputHandoff _handoff = PostReplyInputHandoff.none;
  int _handoffGeneration = 0;
  Timer? _handoffTimer;
  bool _disposing = false;
  int? _parentReplyId;
  int? _replyToUserId;
  int? _replyToReplyId;
  String? _replyToName;
  AppSticker? _sticker;
  EmojiFavoriteItem? _favoriteImage;
  XFile? _localImage;

  bool get isOpen => _isOpen;
  PostReplyBottomPanel get bottomPanel => _bottomPanel;
  bool get showEmojiPanel => _bottomPanel == PostReplyBottomPanel.emoji;
  double get stableKeyboardHeight => _stableKeyboardHeight;
  double get keyboardInset => _keyboardInset;
  bool get inputHandoffActive => _handoff != PostReplyInputHandoff.none;
  int? get parentReplyId => _parentReplyId;
  int? get replyToUserId => _replyToUserId;
  int? get replyToReplyId => _replyToReplyId;
  String? get replyToName => _replyToName;
  AppSticker? get sticker => _sticker;
  EmojiFavoriteItem? get favoriteImage => _favoriteImage;
  XFile? get localImage => _localImage;

  late final TextInputFormatter _mentionFormatter =
      TextInputFormatter.withFunction(formatTextEdit);

  List<TextInputFormatter> get inputFormatters => [_mentionFormatter];

  PostReplyDraft get draft => PostReplyDraft(
        text: textController.text.trim(),
        parentReplyId: _parentReplyId,
        replyToUserId: _replyToUserId,
        replyToReplyId: _replyToReplyId,
        replyToName: _replyToName,
        sticker: _sticker,
        favoriteImage: _favoriteImage,
        localImage: _localImage,
      );

  void updateKeyboardMetrics(double inset) {
    final normalizedInset = inset < 0 ? 0.0 : inset;
    final insetChanged = (_keyboardInset - normalizedInset).abs() > 0.1;
    final wasCollapsing = normalizedInset < _lastKeyboardInset;
    _lastKeyboardInset = normalizedInset;
    _keyboardInset = normalizedInset;

    // Emoji → Keyboard 交接期间保持 Emoji 可见，直到 IME 覆盖到稳定高度
    // 再完成交接；不让 Emoji 面板在 IME 升起途中让位造成空白板。
    if (_handoff == PostReplyInputHandoff.emojiToKeyboard) {
      if (normalizedInset > 0) {
        // 交接期间不改写 target：以记录的稳定高度（或 fallback）为基准，
        // 避免首帧小 inset 把目标重设导致 Emoji 提前让位。
        final target = _stableKeyboardHeight;
        if (normalizedInset >= target * 0.90 ||
            (target - normalizedInset).abs() <= 12) {
          _completeEmojiToKeyboardHandoff();
        } else if (insetChanged) {
          notifyListeners();
        }
      } else {
        // 键盘没有起来/异常：取消 handoff，保持 Emoji
        _cancelHandoff();
      }
      return;
    }

    if (normalizedInset > 0) {
      // 仅在非收起阶段且高度有效时更新稳定高度，防止在软键盘收起递减过程中将中间过渡值误写为稳定高度
      if (!wasCollapsing &&
          (normalizedInset > _stableKeyboardHeight ||
              !_hasObservedKeyboardHeight)) {
        if (normalizedInset >= 180 || !_hasObservedKeyboardHeight) {
          _stableKeyboardHeight = normalizedInset;
          _hasObservedKeyboardHeight = true;
        }
      }
      final canShowKeyboardPanel = _isOpen ||
          focusNode.hasFocus ||
          _bottomPanel == PostReplyBottomPanel.keyboard;
      if (_bottomPanel != PostReplyBottomPanel.emoji && canShowKeyboardPanel) {
        _bottomPanel = PostReplyBottomPanel.keyboard;
      }
      if (insetChanged) {
        notifyListeners();
      }
    } else {
      if (_bottomPanel == PostReplyBottomPanel.keyboard) {
        _bottomPanel = PostReplyBottomPanel.none;
        notifyListeners();
      } else if (insetChanged) {
        notifyListeners();
      }
    }
  }

  void open() {
    _cancelHandoff();
    _isOpen = true;
    _bottomPanel = PostReplyBottomPanel.keyboard;
    notifyListeners();
    _focusAfterLayout();
  }

  void openRoot() {
    clearReplyTarget();
    open();
  }

  void setReplyTarget({
    required int parentReplyId,
    int? replyToUserId,
    int? replyToReplyId,
    String? replyToName,
  }) {
    _parentReplyId = parentReplyId;
    _replyToUserId = replyToUserId;
    _replyToReplyId = replyToReplyId;
    _replyToName = replyToName?.trim();
    notifyListeners();
  }

  void openReply({
    required int parentReplyId,
    int? replyToUserId,
    int? replyToReplyId,
    String? replyToName,
  }) {
    _parentReplyId = parentReplyId;
    _replyToUserId = replyToUserId;
    _replyToReplyId = replyToReplyId;
    final trimmedName = replyToName?.trim();
    _replyToName = trimmedName;

    open();
  }

  /// 将删除命中到的 `@名称` 扩展成完整 token，避免残留半个提及。
  ///
  /// 回复对象由 replyToUserId 等元数据维护，因此文本删除不能改变它。
  TextEditingValue formatTextEdit(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    if (newValue.text.length >= oldValue.text.length) return newValue;

    final change = _TextEditChange.between(oldValue.text, newValue.text);
    if (change.removedStart == change.removedEnd) return newValue;

    final insertedText = newValue.text.substring(
      change.insertedStart,
      change.insertedEnd,
    );
    final deletionRange = _mentionDeletionRange(
      oldValue.text,
      removedStart: change.removedStart,
      removedEnd: change.removedEnd,
      includeTrailingSpace: insertedText.isEmpty,
    );
    if (deletionRange == null) return newValue;
    final text = oldValue.text.replaceRange(
      deletionRange.start,
      deletionRange.end,
      insertedText,
    );
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: deletionRange.start + insertedText.length,
      ),
    );
  }

  /// 自定义 Emoji 面板不经过 TextField formatter，因此复用同一规则。
  void deleteBackward() {
    final oldValue = textController.value;
    deletePreviousCharacter(textController);
    textController.value = formatTextEdit(oldValue, textController.value);
  }

  void clearReplyTarget() {
    if (_parentReplyId == null &&
        _replyToName == null &&
        _replyToUserId == null &&
        _replyToReplyId == null) {
      return;
    }
    _parentReplyId = null;
    _replyToUserId = null;
    _replyToReplyId = null;
    _replyToName = null;
    notifyListeners();
  }

  void clearContent() {
    _cancelHandoff();
    textController.clear();
    _sticker = null;
    _favoriteImage = null;
    _localImage = null;
    notifyListeners();
  }

  void close({bool clearDraft = false, bool preserveReplyTarget = false}) {
    _cancelHandoff();
    focusNode.unfocus();
    _isOpen = false;
    _bottomPanel = PostReplyBottomPanel.none;
    if (clearDraft) {
      if (preserveReplyTarget) {
        clearContent();
      } else {
        clear();
      }
    }
    notifyListeners();
  }

  void clear() {
    clearContent();
    clearReplyTarget();
  }

  void toggleEmojiPanel({double keyboardInset = 0}) {
    if (_bottomPanel == PostReplyBottomPanel.emoji) {
      // Emoji → Keyboard：保持 Emoji 原位直到 IME 覆盖，避免空白板。
      _beginEmojiToKeyboardHandoff();
      return;
    }
    _cancelHandoff();
    if (keyboardInset >= 180 ||
        (keyboardInset > 0 && !_hasObservedKeyboardHeight)) {
      _stableKeyboardHeight = keyboardInset;
      _hasObservedKeyboardHeight = true;
    }
    focusNode.unfocus();
    _isOpen = true;
    _bottomPanel = PostReplyBottomPanel.emoji;
    notifyListeners();
  }

  /// 发起 Emoji → Keyboard 交接：Emoji 保持显示直到 IME 稳定高度出现。
  void _beginEmojiToKeyboardHandoff() {
    _cancelHandoff();
    final generation = ++_handoffGeneration;
    _handoff = PostReplyInputHandoff.emojiToKeyboard;
    notifyListeners();
    _focusAfterLayout();
    // 保险超时：仅防状态永远卡住，不作为动画时长。
    _handoffTimer = Timer(
      const Duration(milliseconds: 750),
      () {
        if (_disposing || generation != _handoffGeneration) return;
        if (_handoff == PostReplyInputHandoff.emojiToKeyboard) {
          _handoff = PostReplyInputHandoff.none;
          _bottomPanel = PostReplyBottomPanel.keyboard;
          notifyListeners();
        }
      },
    );
  }

  /// handoff 完成后调用：Emoji 让位给已稳定的 IME。
  void _completeEmojiToKeyboardHandoff() {
    _handoffTimer?.cancel();
    if (_handoff != PostReplyInputHandoff.emojiToKeyboard) return;
    _handoffGeneration++;
    _handoff = PostReplyInputHandoff.none;
    _bottomPanel = PostReplyBottomPanel.keyboard;
    notifyListeners();
  }

  void _cancelHandoff() {
    _handoffTimer?.cancel();
    if (_handoff != PostReplyInputHandoff.none) {
      _handoffGeneration++;
      if (_disposing) {
        _handoff = PostReplyInputHandoff.none;
        return;
      }
      _handoff = PostReplyInputHandoff.none;
      notifyListeners();
    }
  }

  void closeEmojiPanel() {
    _cancelHandoff();
    if (_bottomPanel != PostReplyBottomPanel.emoji) return;
    _bottomPanel = PostReplyBottomPanel.none;
    notifyListeners();
  }

  void selectSticker(AppSticker value) {
    _sticker = value;
    _favoriteImage = null;
    _localImage = null;
    notifyListeners();
  }

  void removeSticker() {
    if (_sticker == null) return;
    _sticker = null;
    notifyListeners();
  }

  void selectFavoriteImage(EmojiFavoriteItem value) {
    if (value.type != EmojiFavoriteType.image) return;
    _favoriteImage = value;
    _sticker = null;
    _localImage = null;
    notifyListeners();
  }

  void removeFavoriteImage() {
    if (_favoriteImage == null) return;
    _favoriteImage = null;
    notifyListeners();
  }

  void selectLocalImage(XFile value) {
    _localImage = value;
    _sticker = null;
    _favoriteImage = null;
    notifyListeners();
  }

  void removeLocalImage() {
    if (_localImage == null) return;
    _localImage = null;
    notifyListeners();
  }

  void _focusAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!focusNode.canRequestFocus) return;
      focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _handoffTimer?.cancel();
    _handoffTimer = null;
    textController.dispose();
    focusNode.dispose();
    super.dispose();
  }
}

class _TextEditChange {
  const _TextEditChange({
    required this.removedStart,
    required this.removedEnd,
    required this.insertedStart,
    required this.insertedEnd,
  });

  final int removedStart;
  final int removedEnd;
  final int insertedStart;
  final int insertedEnd;

  factory _TextEditChange.between(String oldText, String newText) {
    var start = 0;
    final sharedLength =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (start < sharedLength && oldText[start] == newText[start]) {
      start++;
    }

    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > start &&
        newEnd > start &&
        oldText[oldEnd - 1] == newText[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    return _TextEditChange(
      removedStart: start,
      removedEnd: oldEnd,
      insertedStart: start,
      insertedEnd: newEnd,
    );
  }
}

TextRange? _mentionDeletionRange(
  String text, {
  required int removedStart,
  required int removedEnd,
  required bool includeTrailingSpace,
}) {
  var start = removedStart;
  var end = removedEnd;
  var foundMention = false;
  for (final match in RegExp(
    r'''(^|[\s,，。！？；：、.!?;:()（）\[\]【】{}《》〈〉"'“”‘’/\\|…—-])@[^\s@,，。！？；：、.!?;:()（）\[\]【】{}《》〈〉"'“”‘’/\\|…—-]+''',
  ).allMatches(text)) {
    final prefixLength = match.group(1)?.length ?? 0;
    final tokenStart = match.start + prefixLength;
    var tokenEnd = match.end;
    // 纯删除时顺带移除一个分隔空格，避免残留双空格或孤立空格；替换时保留分隔。
    if (includeTrailingSpace &&
        tokenEnd < text.length &&
        text[tokenEnd] == ' ') {
      tokenEnd++;
    }

    if (removedStart < tokenEnd && removedEnd > tokenStart) {
      foundMention = true;
      if (tokenStart < start) start = tokenStart;
      if (tokenEnd > end) end = tokenEnd;
    }
  }
  return foundMention ? TextRange(start: start, end: end) : null;
}
