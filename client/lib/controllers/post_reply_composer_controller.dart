import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/emoji_favorite_service.dart';
import '../widgets/emoji/sticker_catalog.dart';

enum PostReplyBottomPanel {
  none,
  keyboard,
  emoji,
}

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
  bool _keyboardRequestPending = false;
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
  bool get keyboardRequestPending => _keyboardRequestPending;
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
    if (inset > 0) {
      _stableKeyboardHeight = inset;
      _keyboardRequestPending = false;
      if (_bottomPanel != PostReplyBottomPanel.emoji) {
        _bottomPanel = PostReplyBottomPanel.keyboard;
        notifyListeners();
      }
    } else {
      if (_bottomPanel == PostReplyBottomPanel.keyboard &&
          !_keyboardRequestPending) {
        _bottomPanel = PostReplyBottomPanel.none;
        notifyListeners();
      }
    }
  }

  void open() {
    _isOpen = true;
    _keyboardRequestPending = true;
    _bottomPanel = PostReplyBottomPanel.keyboard;
    notifyListeners();
    _focusAfterLayout();
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
    _replyToName = replyToName?.trim();
    open();
  }

  void clearReplyTarget() {
    if (_parentReplyId == null && _replyToName == null) return;
    _parentReplyId = null;
    _replyToUserId = null;
    _replyToReplyId = null;
    _replyToName = null;
    notifyListeners();
  }

  void close({bool clearDraft = false}) {
    focusNode.unfocus();
    _isOpen = false;
    _keyboardRequestPending = false;
    _bottomPanel = PostReplyBottomPanel.none;
    if (clearDraft) clear();
    notifyListeners();
  }

  void clear() {
    textController.clear();
    _parentReplyId = null;
    _replyToUserId = null;
    _replyToReplyId = null;
    _replyToName = null;
    _sticker = null;
    _favoriteImage = null;
    _localImage = null;
    notifyListeners();
  }

  void toggleEmojiPanel() {
    if (_bottomPanel == PostReplyBottomPanel.emoji) {
      _keyboardRequestPending = true;
      _bottomPanel = PostReplyBottomPanel.keyboard;
      notifyListeners();
      _focusAfterLayout();
      return;
    }
    focusNode.unfocus();
    _isOpen = true;
    _keyboardRequestPending = false;
    _bottomPanel = PostReplyBottomPanel.emoji;
    notifyListeners();
  }

  void closeEmojiPanel() {
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
    textController.dispose();
    focusNode.dispose();
    super.dispose();
  }
}
