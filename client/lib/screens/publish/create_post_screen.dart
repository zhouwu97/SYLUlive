import 'package:flutter/material.dart';
import '../../models/post.dart';
import 'market_publish_form.dart';
import 'water_post_composer.dart';

/// Entry coordinator for post creation / editing.
///
/// Keeps the original constructor signature so existing call sites need no
/// changes.  Dispatches to [WaterPostComposer] for boardId == 1 and
/// [MarketPublishForm] for boardId == 2.
class CreatePostScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (boardId == 1) {
      return WaterPostComposer(editingPost: editingPost);
    }
    return MarketPublishForm(
      defaultPostType: defaultPostType,
      editingPost: editingPost,
      allowedPostTypes: allowedPostTypes,
    );
  }
}
