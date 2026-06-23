import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/image_upload_widget.dart';
import '../config/api_constants.dart';

class CanteenDetailScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  const CanteenDetailScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
  });

  @override
  State<CanteenDetailScreen> createState() => _CanteenDetailScreenState();
}

class _CanteenDetailScreenState extends State<CanteenDetailScreen> {
  final _commentCtrl = TextEditingController();
  int _star = 0;
  bool _editing = false;
  List<String> _ratingImages = [];
  Map<String, dynamic>? _canteenData;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (mounted) setState(() => _isLoading = true);
    final data = await context.read<CanteenProvider>().loadCanteenDetail(
      widget.canteenId,
    );
    if (mounted) {
      setState(() {
        _canteenData = data;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF131720)
          : const Color(0xFFF4F6FB),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        ),
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black87),
        title: Text(widget.canteenName),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _canteenData == null || _canteenData!['canteen'] == null
          ? const Center(child: Text('加载失败'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                CachedNetworkImage(
                  imageUrl: ApiConstants.fullUrl(
                    _canteenData!['canteen']['image'],
                  ),
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                  placeholder: (context, url) => Container(
                    width: double.infinity,
                    height: 240,
                    color: Colors.grey[200],
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (context, url, error) => Container(
                    width: double.infinity,
                    height: 240,
                    color: Colors.grey[300],
                    child: const Icon(
                      Icons.broken_image,
                      size: 50,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        margin: EdgeInsets.zero,
                        color: isDark ? Colors.grey[850] : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Text(
                                _canteenData!['canteen']['name'],
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _stars(
                                    (_canteenData!['average_star'] as num)
                                        .toDouble(),
                                    28,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${(_canteenData!['average_star'] as num).toStringAsFixed(1)} (${_canteenData!['rating_count']}人)',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildMyRating(isDark),
                      const SizedBox(height: 20),
                      if (_canteenData!['ratings'] != null &&
                          (_canteenData!['ratings'] as List).isNotEmpty) ...[
                        Text(
                          '${_canteenData!['rating_count']}人评价',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...(_canteenData!['ratings'] as List).map(
                          (r) => _buildRatingCard(r, isDark),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildRatingCard(Map<String, dynamic> r, bool isDark) {
    List<String> images = [];
    if (r['images'] != null && r['images'].toString().isNotEmpty) {
      // already parsed string json if the model does it, but here it's Map
      // if from server, images is a string representing json array
      try {
        final decoded = r['images'] is String ? r['images'] : '';
        // Wait, the API returns raw JSON which might just be a string for images
        // It's better to just parse it if it's string.
      } catch (e) {}
    }
    // Since API returns it as raw struct, CanteenRating has Images string.
    if (r['images'] != null) {
      if (r['images'] is String && r['images'].toString().startsWith('[')) {
        try {
          final List<dynamic> decoded = r['images'] != null
              ? List<dynamic>.from(
                  r['images']
                      .toString()
                      .replaceAll('[', '')
                      .replaceAll(']', '')
                      .replaceAll('"', '')
                      .split(',')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty),
                )
              : [];
          // A safer way since it's just json array:
        } catch (e) {}
      }
    }

    // Safely extract images (assuming it's a JSON array string like '["url1", "url2"]')
    List<String> imgList = [];
    try {
      if (r['images'] != null && r['images'].toString().startsWith('[')) {
        final decoded = r['images'].toString();
        imgList = decoded
            .substring(1, decoded.length - 1)
            .split(',')
            .map((e) => e.replaceAll('"', '').trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (e) {}

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isDark ? Colors.grey[800] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: const Color(0xFF6366F1),
                  backgroundImage:
                      r['user_avatar'] != null &&
                          r['user_avatar'].toString().isNotEmpty
                      ? CachedNetworkImageProvider(
                          ApiConstants.fullUrl(r['user_avatar']),
                        )
                      : null,
                  child:
                      r['user_avatar'] == null ||
                          r['user_avatar'].toString().isEmpty
                      ? Text(
                          r['user_name'] != null &&
                                  r['user_name'].toString().isNotEmpty
                              ? r['user_name'][0]
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r['user_name'] ?? '匿名',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                _stars((r['star'] as num).toDouble(), 14),
              ],
            ),
            if (r['comment'] != null && r['comment'].toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  r['comment'],
                  style: TextStyle(
                    color: isDark ? Colors.grey[300] : Colors.grey[700],
                    fontSize: 14,
                  ),
                ),
              ),
            if (imgList.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: imgList
                      .map(
                        (url) => ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                            imageUrl: ApiConstants.fullUrl(url),
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            placeholder: (context, url) =>
                                Container(color: Colors.grey[200]),
                            errorWidget: (context, url, error) => const Icon(
                              Icons.broken_image,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMyRating(bool isDark) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isLoggedIn)
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: Text('请先登录后评价')),
        ),
      );

    final myRating = _canteenData!['my_rating'];
    if (myRating != null) {
      if (myRating['user_name'] == null ||
          myRating['user_name'].toString().isEmpty) {
        myRating['user_name'] = auth.user?.nickname ?? '我';
      }
      if (myRating['user_avatar'] == null ||
          myRating['user_avatar'].toString().isEmpty) {
        myRating['user_avatar'] = auth.user?.avatar ?? '';
      }
    }

    return Card(
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '我的评价',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const Spacer(),
                if (!_editing)
                  TextButton(
                    onPressed: () => setState(() {
                      _editing = true;
                      if (myRating != null) {
                        _star = myRating['star'];
                        _commentCtrl.text = myRating['comment'] ?? '';
                        _ratingImages = [];
                        try {
                          if (myRating['images'] != null &&
                              myRating['images'].toString().startsWith('[')) {
                            final decoded = myRating['images'].toString();
                            _ratingImages = decoded
                                .substring(1, decoded.length - 1)
                                .split(',')
                                .map((e) => e.replaceAll('"', '').trim())
                                .where((e) => e.isNotEmpty)
                                .toList();
                          }
                        } catch (e) {}
                      } else {
                        _ratingImages = [];
                      }
                    }),
                    child: Text(myRating == null ? '打分' : '修改'),
                  ),
              ],
            ),
            if (!_editing && myRating != null) ...[
              _buildRatingCard(myRating, isDark),
            ] else if (!_editing) ...[
              const Text('点击打分按钮进行评价', style: TextStyle(color: Colors.grey)),
            ] else ...[
              Row(
                children: List.generate(
                  5,
                  (i) => GestureDetector(
                    onTap: () => setState(() => _star = i + 1),
                    child: Icon(
                      i < _star ? Icons.star : Icons.star_border,
                      size: 36,
                      color: i < _star ? Colors.amber : Colors.grey[400],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _commentCtrl,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: '说说感受...',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              ImageUploadWidget(
                maxImages: 9,
                onImagesUploaded: (urls) {
                  _ratingImages = urls;
                },
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _editing = false),
                    child: const Text('取消'),
                  ),
                  ElevatedButton(
                    onPressed: _star == 0
                        ? null
                        : () async {
                            final success = await context
                                .read<CanteenProvider>()
                                .rateCanteen(
                                  widget.canteenId,
                                  _star,
                                  _commentCtrl.text,
                                  _ratingImages,
                                );
                            if (mounted) {
                              setState(() => _editing = false);
                              _loadData();
                            }
                          },
                    child: Text(myRating == null ? '提交' : '更新'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stars(double avg, double size) => Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(
      5,
      (i) => Icon(
        i < avg.round() ? Icons.star : Icons.star_border,
        size: size,
        color: i < avg.round() ? Colors.amber : Colors.grey[400],
      ),
    ),
  );
}
