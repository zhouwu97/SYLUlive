import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';
import '../config/privileged_accounts.dart';
import '../screens/image_viewer_screen.dart';

class ImageUploadWidget extends StatefulWidget {
  final int maxImages;
  final ValueChanged<List<String>> onImagesUploaded;
  final bool largeCard;
  final String emptyTitle;
  final String emptySubtitle;

  const ImageUploadWidget({
    super.key,
    this.maxImages = 9,
    this.largeCard = false,
    this.emptyTitle = '添加图片',
    this.emptySubtitle = '建议上传清晰图片',
    required this.onImagesUploaded,
  });

  @override
  State<ImageUploadWidget> createState() => _ImageUploadWidgetState();
}

class _ImageUploadWidgetState extends State<ImageUploadWidget> {
  final ImagePicker _imagePicker = ImagePicker();
  final List<String> _uploadedUrls = [];
  bool _isUploading = false;

  bool get _canUploadUnlimitedImages {
    final studentId = context.read<AuthProvider>().user?.studentId;
    return PrivilegedAccounts.canUploadUnlimitedImages(studentId);
  }

  bool get _canAddMoreImages =>
      _canUploadUnlimitedImages || _uploadedUrls.length < widget.maxImages;

  bool get _canPickImage =>
      _canAddMoreImages ||
      (widget.largeCard && widget.maxImages == 1 && _uploadedUrls.isNotEmpty);

  Future<void> _pickAndUploadImage(ImageSource source) async {
    if (!_canPickImage) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('最多只能上传${widget.maxImages}张图片')));
      return;
    }

    final dio = context.read<AuthProvider>().dio;

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
        requestFullMetadata: false,
      );

      if (image != null) {
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

        if (mounted) {
          setState(() {
            _isUploading = true;
          });
        }

        final bytes = await image.readAsBytes();
        final fileName = image.name.isNotEmpty ? image.name : 'upload.jpg';

        final formData = FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: fileName),
        });

        final response = await dio.post(
          '/upload',
          data: formData,
          options: Options(
            // Increase timeout for file upload if needed, or keep default
            sendTimeout: const Duration(seconds: 60),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );

        if (response.statusCode == 200 &&
            response.data != null &&
            response.data['url'] != null) {
          if (mounted) {
            setState(() {
              if (widget.largeCard && widget.maxImages == 1) {
                _uploadedUrls.clear();
              }
              _uploadedUrls.add(response.data['url']);
            });
          }
          widget.onImagesUploaded(_uploadedUrls);
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
      debugPrint('Dio上传图片出错: ${e.message} ${e.response?.data}');
      if (mounted) {
        String errMsg = '网络异常或超时';
        if (e.response != null && e.response?.data != null) {
          if (e.response?.data is Map && e.response?.data['error'] != null) {
            errMsg = e.response?.data['error'];
          } else {
            errMsg = '服务器错误 ${e.response?.statusCode}';
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败: $errMsg'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      debugPrint('上传图片出错: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('处理图片出错: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  void _showImageSourceDialog() {
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

  @override
  Widget build(BuildContext context) {
    if (widget.largeCard) {
      return _buildLargeCard(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_uploadedUrls.isNotEmpty) ...[
          SizedBox(
            height: 80,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: 8,
                children: _uploadedUrls.asMap().entries.map((entry) {
                  final index = entry.key;
                  final url = entry.value;
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
                          onTap: () {
                            final fullUrls = _uploadedUrls
                                .map((u) => ApiConstants.fullUrl(u))
                                .toList();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ImageViewerScreen(
                                  imageUrls: fullUrls,
                                  initialIndex: index,
                                ),
                              ),
                            );
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              ApiConstants.fullUrl(url),
                              fit: BoxFit.cover,
                            ),
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
                                _uploadedUrls.removeAt(index);
                              });
                            }
                            widget.onImagesUploaded(_uploadedUrls);
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
            onPressed: _isUploading ? null : _showImageSourceDialog,
            icon: _isUploading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_photo_alternate),
            label: Text(_uploadedUrls.isEmpty ? '添加图片' : '继续添加'),
          ),
      ],
    );
  }

  Widget _buildLargeCard(BuildContext context) {
    const borderColor = Color(0xFFE8E4F0);
    const primary = Color(0xFF7367C6);

    if (_uploadedUrls.isNotEmpty) {
      final url = _uploadedUrls.first;
      return Stack(
        children: [
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                    imageUrls: [ApiConstants.fullUrl(url)],
                    initialIndex: 0,
                  ),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.network(
                ApiConstants.fullUrl(url),
                height: 132,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ),
          Positioned.fill(
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
            ),
          ),
          Positioned(
            right: 10,
            top: 10,
            child: GestureDetector(
              onTap: () {
                setState(_uploadedUrls.clear);
                widget.onImagesUploaded(_uploadedUrls);
              },
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 17),
              ),
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
      color: Colors.white,
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
                const Icon(
                  Icons.add_photo_alternate_rounded,
                  color: Color(0xFF7367C6),
                  size: 30,
                ),
              const SizedBox(height: 8),
              Text(
                _isUploading ? '图片上传中...' : widget.emptyTitle,
                style: const TextStyle(
                  color: Color(0xFF7367C6),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.emptySubtitle,
                style: const TextStyle(
                  color: Color(0xFF9A96A8),
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
