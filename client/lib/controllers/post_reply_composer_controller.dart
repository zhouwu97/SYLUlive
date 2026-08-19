import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/emoji_favorite_service.dart';
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
  bool get inputHandoffActive => _handoff != PostReplyInputHandoff.none;
  int? get parentReplyId => _parentReplyId;
  int? get replyToUserId => _replyToUserId;
  int? get replyToReplyId => _replyToReplyId;
  String? get replyToName => _replyToName;
  AppSticker? get sticker => _sticker;
  EmojiFavoriteItem? get favoriteImage => _favoriteImage;
  XFile? get localImage => _localImage;

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
    final wasCollapsing = inset < _lastKeyboardInset;
    _lastKeyboardInset = inset;

    // Emoji → Keyboard 交接期间保持 Emoji 可见，直到 IME 覆盖到稳定高度
    // 再完成交接；不让 Emoji 面板在 IME 升起途中让位造成空白板。
    if (_handoff == PostReplyInputHandoff.emojiToKeyboard) {
      if (inset > 0) {
        // 交接期间不改写 target：以记录的稳定高度（或 fallback）为基准，
        // 避免首帧小 inset 把目标重设导致 Emoji 提前让位。
        final target = _stableKeyboardHeight;
        if (inset >= target * 0.90 || (target - inset).abs() <= 12) {
          _completeEmojiToKeyboardHandoff();
        }
      } else {
        // 键盘没有起来/异常：取消 handoff，保持 Emoji
        _cancelHandoff();
      }
      return;
    }

    if (inset > 0) {
      // 仅在非收起阶段且高度有效时更新稳定高度，防止在软键盘收起递减过程中将中间过渡值误写为稳定高度
      if (!wasCollapsing &&
          (inset > _stableKeyboardHeight || !_hasObservedKeyboardHeight)) {
        if (inset >= 180 || !_hasObservedKeyboardHeight) {
          _stableKeyboardHeight = inset;
          _hasObservedKeyboardHeight = true;
        }
      }
      if (_bottomPanel != PostReplyBottomPanel.emoji) {
        _bottomPanel = PostReplyBottomPanel.keyboard;
        notifyListeners();
      }
    } else {
      if (_bottomPanel == PostReplyBottomPanel.keyboard) {
        _bottomPanel = PostReplyBottomPanel.none;
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

    if (trimmedName != null && trimmedName.isNotEmpty) {
      _insertMention('@$trimmedName ');
    }

    open();
  }

  void _insertMention(String mention) {
    final text = textController.text;
    final selection = textController.selection;

    int start = selection.start;
    int end = selection.end;

    if (start < 0 || end < 0) {
      start = text.length;
      end = text.length;
    }

    if (start > end) {
      final temp = start;
      start = end;
      end = temp;
    }

    String prefix = '';
    if (start > 0 && !text[start - 1].contains(RegExp(r'\s'))) {
      prefix = ' ';
    }

    final insertText = '$prefix$mention';
    final newText = text.replaceRange(start, end, insertText);
    final newCursorPos = start + insertText.length;

    textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
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
