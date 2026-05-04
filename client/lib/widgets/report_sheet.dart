import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'glass_container.dart';

/// 举报原因选项
class ReportReason {
  final String label;
  final String value;
  final IconData icon;
  const ReportReason(this.label, this.value, this.icon);
}

const _reportReasons = [
  ReportReason('垃圾广告', 'spam', Icons.campaign),
  ReportReason('色情低俗', 'porn', Icons.no_adult_content),
  ReportReason('暴力血腥', 'violence', Icons.dangerous),
  ReportReason('虚假信息', 'fake', Icons.fact_check),
  ReportReason('侵犯隐私', 'privacy', Icons.privacy_tip),
  ReportReason('人身攻击', 'harassment', Icons.sentiment_very_dissatisfied),
  ReportReason('其他', 'other', Icons.more_horiz),
];

/// 弹出举报 BottomSheet
/// [targetType] = "post" 或 "reply"
void showReportSheet(BuildContext context, {required int targetId, String targetType = 'post'}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ReportSheetContent(targetId: targetId, targetType: targetType),
  );
}

class _ReportSheetContent extends StatefulWidget {
  final int targetId;
  final String targetType;
  const _ReportSheetContent({required this.targetId, required this.targetType});

  @override
  State<_ReportSheetContent> createState() => _ReportSheetContentState();
}

class _ReportSheetContentState extends State<_ReportSheetContent> {
  String? _selectedReason;
  final _reasonController = TextEditingController();
  bool _submitting = false;

  Future<void> _submit() async {
    if (_selectedReason == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择举报原因'), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _submitting = true);

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.post('/reports', data: {
        'target_type': widget.targetType,
        'target_id': widget.targetId,
        'reason': _selectedReason,
        'detail': _reasonController.text,
      });
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('举报已提交，管理员会尽快处理'), backgroundColor: Colors.green),
        );
      }
    } on DioException catch (e) {
      String msg = '举报失败';
      if (e.response?.data is Map && (e.response!.data as Map).containsKey('error')) {
        msg = (e.response!.data as Map)['error'].toString();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('举报失败，请稍后重试'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final targetLabel = widget.targetType == 'reply' ? '举报评论' : '举报帖子';

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽条
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Icon(Icons.report_outlined, color: Colors.red[400], size: 24),
                const SizedBox(width: 10),
                Text(targetLabel, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const Divider(),
          // 举报原因
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                ..._reportReasons.map((r) => _buildReasonTile(r, isDark)),
                const SizedBox(height: 12),
                // 详细说明
                GlassContainer(
                  padding: const EdgeInsets.all(12),
                  borderRadius: 14,
                  blur: 0,
                  opacity: 0.06,
                  child: TextField(
                    controller: _reasonController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: '补充说明（选填）',
                      hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.grey[400]),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: TextStyle(fontSize: 14, color: isDark ? Colors.white : Colors.black87),
                  ),
                ),
              ],
            ),
          ),
          // 提交按钮
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[400],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _submitting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('提交举报', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReasonTile(ReportReason reason, bool isDark) {
    final selected = _selectedReason == reason.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _selectedReason = reason.value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: selected
                  ? (Colors.red[400]!.withValues(alpha: isDark ? 0.2 : 0.1))
                  : (isDark ? Colors.white.withValues(alpha: 0.04) : Colors.grey.withValues(alpha: 0.06)),
              border: selected
                  ? Border.all(color: Colors.red[400]!.withValues(alpha: 0.5), width: 1.2)
                  : null,
            ),
            child: Row(
              children: [
                Icon(reason.icon, size: 20, color: selected ? Colors.red[400] : (isDark ? Colors.white54 : Colors.grey[600])),
                const SizedBox(width: 12),
                Text(
                  reason.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? Colors.red[400] : (isDark ? Colors.white : Colors.black87),
                  ),
                ),
                const Spacer(),
                if (selected)
                  Icon(Icons.check_circle, size: 20, color: Colors.red[400]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
