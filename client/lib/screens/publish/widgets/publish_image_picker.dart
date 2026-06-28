import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Mixin that provides image picking logic for publish forms.
///
/// The host [State] must implement the abstract getters/setters so the mixin
/// can read the current image lists and trigger rebuilds.
mixin PublishImagePickerMixin<T extends StatefulWidget> on State<T> {
  static final ImagePicker _picker = ImagePicker();

  // ---------------------------------------------------------------------------
  // Abstract – the host State supplies these
  // ---------------------------------------------------------------------------

  List<XFile> get selectedImages;
  List<dynamic> get existingImages; // List<PostImage> in practice
  bool get canAddMoreImages;
  void onImageAdded(XFile image);
  void onNewImageRemoved(int index);
  void onExistingImageRemoved(int index);

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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('图片大小不能超过 10MB'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      if (canAddMoreImages) {
        if (mounted) {
          onImageAdded(image);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('最多只能添加9张图片')));
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
