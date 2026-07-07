import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/water_section_icon_review.dart';
import '../providers/water_section_provider.dart';
import '../config/api_constants.dart';

class AdminWaterIconReviewScreen extends StatefulWidget {
  const AdminWaterIconReviewScreen({super.key});

  @override
  State<AdminWaterIconReviewScreen> createState() => _AdminWaterIconReviewScreenState();
}

class _AdminWaterIconReviewScreenState extends State<AdminWaterIconReviewScreen> {
  List<WaterSectionIconReview> _reviews = [];
  bool _isLoading = true;
  String _statusFilter = 'pending';

  @override
  void initState() {
    super.initState();
    _loadReviews();
  }

  Future<void> _loadReviews() async {
    setState(() => _isLoading = true);
    try {
      final provider = context.read<WaterSectionProvider>();
      final service = provider.iconReviewService;
      if (service == null) return;
      final reviews = await service.adminListSectionIconReviews(status: _statusFilter);
      if (mounted) {
        setState(() {
          _reviews = reviews;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleReview(WaterSectionIconReview review, bool isApprove) async {
    final reasonController = TextEditingController();
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isApprove ? '同意更换头像' : '拒绝更换头像'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                labelText: '处理原因（必填）',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (reasonController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('必须填写处理原因')));
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final provider = context.read<WaterSectionProvider>();
      final service = provider.iconReviewService;
      if (service == null) return;
      
      if (isApprove) {
        await service.adminApproveSectionIconReview(review.id, reasonController.text.trim());
      } else {
        await service.adminRejectSectionIconReview(review.id, reasonController.text.trim());
      }
      
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('处理成功')));
      _loadReviews();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('处理失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('版块图标审核'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _statusFilter,
            onSelected: (val) {
              setState(() => _statusFilter = val);
              _loadReviews();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'pending', child: Text('待审核')),
              PopupMenuItem(value: 'approved', child: Text('已通过')),
              PopupMenuItem(value: 'rejected', child: Text('已拒绝')),
              PopupMenuItem(value: 'cancelled', child: Text('已撤回')),
            ],
            icon: const Icon(Icons.filter_list),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _reviews.isEmpty
              ? const Center(child: Text('暂无数据'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _reviews.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final review = _reviews[index];
                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  review.sectionTitle,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                const Spacer(),
                                _buildStatusChip(review.status),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text('申请人: ${review.requesterName ?? "未知"} (ID: ${review.requestedBy})'),
                            const SizedBox(height: 4),
                            Text('申请理由: ${review.reason}', style: const TextStyle(color: Colors.grey)),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                Column(
                                  children: [
                                    const Text('旧头像', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                    const SizedBox(height: 4),
                                    _buildAvatar(review.oldAvatarUrl),
                                  ],
                                ),
                                const Icon(Icons.arrow_forward, color: Colors.grey),
                                Column(
                                  children: [
                                    const Text('新头像', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                    const SizedBox(height: 4),
                                    _buildAvatar(review.newAvatarUrl),
                                  ],
                                ),
                              ],
                            ),
                            if (review.status == 'pending') ...[
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () => _handleReview(review, false),
                                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                                    child: const Text('拒绝'),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton(
                                    onPressed: () => _handleReview(review, true),
                                    child: const Text('通过'),
                                  ),
                                ],
                              ),
                            ],
                            if (review.reviewReason.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('审核回复: ${review.reviewReason}', style: const TextStyle(fontSize: 13)),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildAvatar(String url) {
    if (url.isEmpty) {
      return Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.image_not_supported, color: Colors.grey),
      );
    }
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        image: DecorationImage(
          image: CachedNetworkImageProvider(ApiConstants.fullUrl(url)),
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color color;
    String text;
    switch (status) {
      case 'pending':
        color = Colors.orange;
        text = '待审核';
        break;
      case 'approved':
        color = Colors.green;
        text = '已通过';
        break;
      case 'rejected':
        color = Colors.red;
        text = '已拒绝';
        break;
      case 'cancelled':
        color = Colors.grey;
        text = '已撤销';
        break;
      default:
        color = Colors.grey;
        text = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}
