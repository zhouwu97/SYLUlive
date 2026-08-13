import 'package:flutter/material.dart';

import '../services/emoji_favorite_service.dart';
import '../widgets/emoji/sticker_catalog.dart';

class PostReplyDraft {
  const PostReplyDraft({
    required this.text,
    this.parentReplyId,
    this.replyToUserId,
    this.replyToReplyId,
    this.replyToName,
    this.sticker,
    this.favoriteImage,
  });

  final String text;
  final int? parentReplyId;
  final int? replyToUserId;
  final int? replyToReplyId;
  final String? replyToName;
  final AppSticker? sticker;
  final EmojiFavoriteItem? favoriteImage;

  bool get isEmpty =>
      text.trim().isEmpty && sticker == null && favoriteImage == null;
}

/// 统一维护帖子评论输入区的编辑状态。
class PostReplyComposerController extends ChangeNotifier {
  final TextEditingController textController = TextEditingController();
  final FocusNode focusNode = FocusNode();

  bool _isOpen = false;
  bool _showEmojiPanel = false;
  int? _parentReplyId;
  int? _replyToUserId;
  int? _replyToReplyId;
  String? _replyToName;
  AppSticker? _sticker;
  EmojiFavoriteItem? _favoriteImage;

  bool get isOpen => _isOpen;
  bool get showEmojiPanel => _showEmojiPanel;
  int? get parentReplyId => _parentReplyId;
  int? get replyToUserId => _replyToUserId;
  int? get replyToReplyId => _replyToReplyId;
  String? get replyToName => _replyToName;
  AppSticker? get sticker => _sticker;
  EmojiFavoriteItem? get favoriteImage => _favoriteImage;

  PostReplyDraft get draft => PostReplyDraft(
        text: textController.text.trim(),
        parentReplyId: _parentReplyId,
        replyToUserId: _replyToUserId,
        replyToReplyId: _replyToReplyId,
        replyToName: _replyToName,
        sticker: _sticker,
        favoriteImage: _favoriteImage,
      );

  void open() {
    _isOpen = true;
    _showEmojiPanel = false;
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
    final name = _replyToName;
    if (name != null && name.isNotEmpty) {
      textController.value = TextEditingValue(
        text: '@$name ',
        selection: TextSelection.collapsed(offset: name.length + 2),
      );
    }
    open();
  }

  void close({bool clearDraft = false}) {
    focusNode.unfocus();
    _isOpen = false;
    _showEmojiPanel = false;
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
    notifyListeners();
  }

  void toggleEmojiPanel() {
    if (_showEmojiPanel) {
      _showEmojiPanel = false;
      notifyListeners();
      _focusAfterLayout();
      return;
    }
    focusNode.unfocus();
    _showEmojiPanel = true;
    notifyListeners();
  }

  void closeEmojiPanel() {
    if (!_showEmojiPanel) return;
    _showEmojiPanel = false;
    notifyListeners();
  }

  void selectSticker(AppSticker value) {
    _sticker = value;
    _favoriteImage = null;
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
    notifyListeners();
  }

  void removeFavoriteImage() {
    if (_favoriteImage == null) return;
    _favoriteImage = null;
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
