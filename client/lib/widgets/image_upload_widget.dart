import 'app_glass_button_style.dart';
import 'package:shenliyuan/widgets/app_bottom_sheet.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';
import '../screens/image_viewer_screen.dart';
import '../services/publish_session_scope.dart';

/// 一次成功上传的图片：以服务端 file_id 为可信标识，url 供回显，previewBytes 供本地预览。
class UploadedImage {
  const UploadedImage({
    required this.fileId,
    required this.url,
    this.previewBytes,
  });

  final int fileId;
  final String url;
  final Uint8List? previewBytes;
}

class ImageUploadWidget extends StatefulWidget {
  final int maxImages;
  final ValueChanged<List<UploadedImage>> onImagesUploaded;
  final bool largeCard;
  final String emptyTitle;
  final String emptySubtitle;
  final ValueChanged<bool>? onBusyChanged;

  const ImageUploadWidget({
    super.key,
    this.maxImages = 9,
    this.largeCard = false,
    this.emptyTitle = '添加图片',
    this.emptySubtitle = '建议上传清晰图片',
    this.onBusyChanged,
    required this.onImagesUploaded,
  });

  @override
  State<ImageUploadWidget> createState() => _ImageUploadWidgetState();
}

class _ImageUploadWidgetState extends State<ImageUploadWidget> {
  final ImagePicker _imagePicker = ImagePicker();
  final List<UploadedImage> _uploadedImages = [];
  bool _isUploading = false;
  AuthProvider? _auth;
  int? _observedEpoch;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthProvider>();
    if (identical(_auth, auth)) return;
    _auth?.removeListener(_handleSessionChanged);
    _auth = auth;
    _observedEpoch = auth.accountSessionEpoch;
    auth.addListener(_handleSessionChanged);
  }

  void _handleSessionChanged() {
    final auth = _auth;
    if (!mounted ||
        auth == null ||
        _observedEpoch == auth.accountSessionEpoch) {
      return;
    }
    _observedEpoch = auth.accountSessionEpoch;
    setState(() {
      _uploadedImages.clear();
      _isUploading = false;
    });
    widget.onImagesUploaded(const []);
  }

  @override
  void dispose() {
    _auth?.removeListener(_handleSessionChanged);
    super.dispose();
  }

  bool get _canAddMoreImages => _uploadedImages.length < widget.maxImages;

  bool get _canPickImage =>
      _canAddMoreImages ||
      (widget.largeCard && widget.maxImages == 1 && _uploadedImages.isNotEmpty);

  Future<void> _pickAndUploadImage(ImageSource source) async {
    if (_isUploading) return;
    if (!_canPickImage) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('最多只能上传${widget.maxImages}张图片')));
      return;
    }

    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    if (accountId == null) return;
    final scope = PublishSessionScope(
      accountId: accountId,
      accountSessionEpoch: auth.accountSessionEpoch,
    );
    bool ownsScope() =>
        mounted &&
        scope.owns(
          userId: auth.user?.id,
          sessionEpoch: auth.accountSessionEpoch,
        );
    final dio = auth.dio;

    setState(() => _isUploading = true);
    widget.onBusyChanged?.call(true);
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
        requestFullMetadata: false,
      );

      if (image != null) {
        if (!ownsScope()) return;
        final length = await image.length();
        if (!ownsScope()) return;
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

        final bytes = await image.readAsBytes();
        if (!ownsScope()) return;
        final fileName = image.name.isNotEmpty ? image.name : 'upload.jpg';

        final formData = FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: fileName),
        });

        final response = await dio.post(
          '/upload',
          data: formData,
          options: Options(
            extra: scope.requestExtra,
            // Increase timeout for file upload if needed, or keep default
            sendTimeout: const Duration(seconds: 60),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
        if (!ownsScope()) return;

        if (response.statusCode == 200 &&
            response.data != null &&
            response.data['url'] != null) {
          final rawFileId = response.data['file_id'];
          final fileId = rawFileId is num ? rawFileId.toInt() : 0;
          if (fileId <= 0) {
            // 服务端已私有化并按归属校验，file_id 缺失/0 一律视为上传失败。
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('图片上传失败'),
                  backgroundColor: Colors.red,
                ),
              );
            }
            return;
          }
          final url = response.data['url'] as String;
          if (mounted) {
            setState(() {
              if (widget.largeCard && widget.maxImages == 1) {
                _uploadedImages.clear();
              }
              _uploadedImages.add(
                UploadedImage(
                  fileId: fileId,
                  url: url,
                  previewBytes: bytes,
                ),
              );
            });
          }
          if (ownsScope()) widget.onImagesUploaded(_uploadedImages);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('图片上传失败'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } on DioException catch (e) {
      debugPrint('Dio上传图片出错: ${e.type} status=${e.response?.statusCode}');
      if (mounted && ownsScope()) {
        String errMsg = '网络异常或超时';
        final data = e.response?.data;
        if (data is Map) {
          // 服务端统一错误格式为 {code, message, request_id}，error 仅旧接口兜底。
          final message = data['message'] ?? data['error'];
          errMsg = message?.toString() ?? '服务器错误 ${e.response?.statusCode}';
        } else if (e.response != null && e.response?.data != null) {
          errMsg = '服务器错误 ${e.response?.statusCode}';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败: $errMsg'), backgroundColor: Colors.red),
        );
      }
    } on PlatformException catch (e) {
      if (mounted && ownsScope()) {
        final denied = e.code.contains('access_denied') ||
            e.code.contains('access_restricted');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(denied ? '无法访问相册或相机，请在系统设置中允许权限后重试' : '无法打开图片，请重试或更换图片'),
        ));
      }
    } catch (e) {
      debugPrint('上传图片异常: ${e.runtimeType}');
      if (mounted && ownsScope()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('处理图片失败，请重试或更换图片')),
        );
      }
    } finally {
      if (mounted && ownsScope()) {
        setState(() {
          _isUploading = false;
        });
        widget.onBusyChanged?.call(false);
      }
    }
  }

  void _showImageSourceDialog() {
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
                _pickAndUploadImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openViewer(int initialIndex) {
    final imageUrls =
        _uploadedImages.map((e) => ApiConstants.fullUrl(e.url)).toList();
    final imageBytes =
        _uploadedImages.map((e) => e.previewBytes).toList(growable: false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          imageUrls: imageUrls,
          imageBytes: imageBytes,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  Widget _imageOrPlaceholder(UploadedImage image) {
    final bytes = image.previewBytes;
    if (bytes != null) {
      return Image.memory(bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _previewFailure());
    }
    return _previewFailure();
  }

  Widget _previewFailure() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainer,
      alignment: Alignment.center,
      child: Text('图片预览失败，请更换图片',
          style: TextStyle(color: scheme.onSurfaceVariant)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.largeCard) {
      return _buildLargeCard(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_uploadedImages.isNotEmpty) ...[
          SizedBox(
            height: 80,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: 8,
                children: _uploadedImages.asMap().entries.map((entry) {
                  final index = entry.key;
                  final image = entry.value;
                  return Stack(
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: GestureDetector(
                          onTap: () => _openViewer(index),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _imageOrPlaceholder(image),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () {
                            if (mounted) {
                              setState(() {
                                _uploadedImages.removeAt(index);
                              });
                            }
                            widget.onImagesUploaded(_uploadedImages);
                          },
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_canAddMoreImages)
          OutlinedButton.icon(
            style: appGlassButtonStyle(context, const ButtonStyle()),
            onPressed: _isUploading ? null : _showImageSourceDialog,
            icon: _isUploading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_photo_alternate),
            label: Text(_uploadedImages.isEmpty ? '添加图片' : '继续添加'),
          ),
      ],
    );
  }

  Widget _buildLargeCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = scheme.outlineVariant;
    final primary = scheme.primary;

    if (_uploadedImages.isNotEmpty) {
      final image = _uploadedImages.first;
      return Stack(
        children: [
          GestureDetector(
            onTap: () => _openViewer(0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 132,
                width: double.infinity,
                child: _imageOrPlaceholder(image),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
                child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: borderColor),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.28),
                  ],
                ),
              ),
            )),
          ),
          Positioned(
            right: 10,
            top: 10,
            child: IconButton(
              tooltip: '移除商家图片',
              onPressed: _isUploading
                  ? null
                  : () {
                      setState(_uploadedImages.clear);
                      widget.onImagesUploaded(_uploadedImages);
                    },
              style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  minimumSize: const Size(44, 44),
                  foregroundColor: Colors.white),
              icon: const Icon(Icons.close, size: 18),
            ),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: FilledButton.icon(
              onPressed: _isUploading ? null : _showImageSourceDialog,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: primary,
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              icon: _isUploading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_photo_alternate_rounded, size: 16),
              label: const Text('更换图片'),
            ),
          ),
        ],
      );
    }

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: _isUploading ? null : _showImageSourceDialog,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: double.infinity,
          height: 112,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isUploading)
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              else
                Icon(
                  Icons.add_photo_alternate_rounded,
                  color: primary,
                  size: 30,
                ),
              const SizedBox(height: 8),
              Text(
                _isUploading ? '图片上传中...' : widget.emptyTitle,
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.emptySubtitle,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
