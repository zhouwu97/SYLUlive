import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';

class ImageUploadWidget extends StatefulWidget {
  final int maxImages;
  final ValueChanged<List<String>> onImagesUploaded;

  const ImageUploadWidget({
    super.key,
    this.maxImages = 9,
    required this.onImagesUploaded,
  });

  @override
  State<ImageUploadWidget> createState() => _ImageUploadWidgetState();
}

class _ImageUploadWidgetState extends State<ImageUploadWidget> {
  final ImagePicker _imagePicker = ImagePicker();
  final List<String> _uploadedUrls = [];
  bool _isUploading = false;

  Future<void> _pickAndUploadImage(ImageSource source) async {
    if (_uploadedUrls.length >= widget.maxImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('最多只能上传${widget.maxImages}张图片')),
      );
      return;
    }

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
      );

      if (image != null) {
        final length = await image.length();
        if (length > 10 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('图片大小不能超过 10MB'), backgroundColor: Colors.red),
            );
          }
          return;
        }

        setState(() {
          _isUploading = true;
        });

        final dio = context.read<AuthProvider>().dio;
        
        final bytes = await image.readAsBytes();
        final fileName = image.name.isNotEmpty ? image.name : 'upload.jpg';
        
        final formData = FormData.fromMap({
          'file': MultipartFile.fromBytes(
            bytes,
            filename: fileName,
          ),
        });

        final response = await dio.post(
          '/upload', 
          data: formData,
          options: Options(
            // Increase timeout for file upload if needed, or keep default
            sendTimeout: const Duration(seconds: 60),
            receiveTimeout: const Duration(seconds: 60),
          )
        );

        if (response.statusCode == 200 && response.data != null && response.data['url'] != null) {
          setState(() {
            _uploadedUrls.add(response.data['url']);
          });
          widget.onImagesUploaded(_uploadedUrls);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('图片上传失败'), backgroundColor: Colors.red),
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
      setState(() {
        _isUploading = false;
      });
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
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            ApiConstants.fullUrl(url),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _uploadedUrls.removeAt(index);
                            });
                            widget.onImagesUploaded(_uploadedUrls);
                          },
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 14),
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
        if (_uploadedUrls.length < widget.maxImages)
          OutlinedButton.icon(
            onPressed: _isUploading ? null : _showImageSourceDialog,
            icon: _isUploading 
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_photo_alternate),
            label: Text(_uploadedUrls.isEmpty ? '添加图片' : '继续添加'),
          ),
      ],
    );
  }
}
