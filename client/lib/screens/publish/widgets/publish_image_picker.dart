import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../utils/app_feedback.dart';

/// Mixin that provides image picking logic for publish forms.
///
/// The host [State] must implement [canAddMoreImages] and [onImageAdded];
/// C-2 unified image model means the host decides how to turn the picked
/// [XFile] into a list item.
mixin PublishImagePickerMixin<T extends StatefulWidget> on State<T> {
  static final ImagePicker _picker = ImagePicker();

  // ---------------------------------------------------------------------------
  // Abstract – the host State supplies these
  // ---------------------------------------------------------------------------

  bool get canAddMoreImages;
  void onImageAdded(XFile image);

  // ---------------------------------------------------------------------------
  // Pick a single image from the given source
  // ---------------------------------------------------------------------------

  Future<void> pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;

      final length = await image.length();
      if (length > 10 * 1024 * 1024) {
        if (mounted) {
          AppFeedback.error('图片大小不能超过 10MB', context: context);
        }
        return;
      }

      if (canAddMoreImages) {
        if (mounted) {
          onImageAdded(image);
        }
      } else {
        if (mounted) {
          AppFeedback.info('最多只能添加 9 张图片', context: context);
        }
      }
    } catch (e) {
      debugPrint('选择图片失败: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Bottom sheet to choose between gallery and camera
  // ---------------------------------------------------------------------------

  void showImageSourceDialog() {
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
                pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(context);
                pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }
}
