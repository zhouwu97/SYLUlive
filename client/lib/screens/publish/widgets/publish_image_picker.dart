import 'package:shenliyuan/widgets/app_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../services/publish_session_scope.dart';
import '../../../utils/app_feedback.dart';
import '../../../utils/public_image_upload_policy.dart';

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
  int get remainingImageSlots;
  void onImageAdded(XFile image);
  bool _pickingImages = false;

  // ---------------------------------------------------------------------------
  // Pick a single image from the given source
  // ---------------------------------------------------------------------------

  Future<void> pickImage(ImageSource source) async {
    if (_pickingImages || !canAddMoreImages) return;
    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    if (accountId == null || accountId <= 0) {
      AppFeedback.info('请先登录后再选择图片', context: context);
      return;
    }
    final scope = PublishSessionScope(
      accountId: accountId,
      accountSessionEpoch: auth.accountSessionEpoch,
    );
    _pickingImages = true;
    try {
      final List<XFile> images;
      if (source == ImageSource.gallery) {
        // 插件的 limit 至少为 2；剩一格时仍由下面的数量门禁收口。
        images = await _picker.pickMultiImage(
          limit: remainingImageSlots.clamp(2, 9),
        );
      } else {
        final image = await _picker.pickImage(source: source);
        images = image == null ? [] : [image];
      }
      for (final image in images) {
        if (!mounted) return;
        scope.ensure(
            userId: auth.user?.id, sessionEpoch: auth.accountSessionEpoch);
        if (!canAddMoreImages) {
          AppFeedback.info('最多只能添加 9 张图片', context: context);
          break;
        }
        final length = await image.length();
        if (!mounted) return;
        scope.ensure(
            userId: auth.user?.id, sessionEpoch: auth.accountSessionEpoch);
        if (length > PublicImageUploadPolicy.maxInputSizeBytes) {
          AppFeedback.error('单张图片超过 100MB，请先裁剪或导出后选择', context: context);
          continue;
        }
        if (canAddMoreImages) onImageAdded(image);
      }
    } on PublishSessionChanged {
      if (mounted) AppFeedback.error('登录状态已变化，请重新选择图片', context: context);
    } catch (e) {
      debugPrint('选择图片失败: $e');
      if (mounted) AppFeedback.error('无法读取图片，请检查相册权限后重试', context: context);
    } finally {
      _pickingImages = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Bottom sheet to choose between gallery and camera
  // ---------------------------------------------------------------------------

  void showImageSourceDialog() {
    showAppModalBottomSheet(
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
