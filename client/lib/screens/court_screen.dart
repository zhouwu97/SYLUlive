import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../widgets/app_page_app_bar.dart';

class CourtScreen extends StatefulWidget {
  final int appealId;
  final bool adminReviewMode;
  const CourtScreen(
      {super.key, required this.appealId, this.adminReviewMode = false});

  @override
  State<CourtScreen> createState() => _CourtScreenState();
}

class _CourtScreenState extends State<CourtScreen> {
  Map<String, dynamic>? _appeal;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await getSharedDio().get('/appeals/${widget.appealId}');
      final data = response.data;
      final raw = data is Map && data['appeal'] is Map ? data['appeal'] : data;
      if (mounted) {
        setState(
            () => _appeal = raw is Map ? Map<String, dynamic>.from(raw) : null);
      }
    } on DioException catch (error) {
      if (mounted) {
        setState(() => _error = error.response?.data is Map
            ? (error.response?.data['error']?.toString() ?? '申诉详情加载失败')
            : '申诉详情加载失败');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '申诉详情加载失败');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _vote(String vote) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await getSharedDio()
          .post('/appeals/${widget.appealId}/vote', data: {'vote': vote});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(vote == 'support' ? '已投支持票' : '已投反对票')));
      }
      await _load();
    } on DioException catch (error) {
      if (mounted) {
        final message = error.response?.data is Map
            ? error.response?.data['error']?.toString()
            : null;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message ?? '投票失败')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _recuse() async {
    final reason = await _showReasonDialog(
      title: '申请回避',
      description: '如果你与案件当事人存在现实关系或其他利益冲突，请说明原因。',
      label: '回避原因（必填）',
      hint: '例如：我与该内容存在直接关系',
      confirmLabel: '提交回避',
      icon: Icons.block_outlined,
      maxLength: 200,
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await getSharedDio().post('/appeals/${widget.appealId}/recuse',
          data: {'reason': reason.trim()});
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已申请回避')));
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      final message = error.response?.data is Map
          ? error.response?.data['error']?.toString()
          : null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message ?? '申请回避失败')));
    }
  }

  Future<void> _manualResolve(String decision) async {
    final isPass = decision == 'pass';
    final reason = await _showReasonDialog(
      title: isPass ? '确认支持申诉' : '确认维持原处理',
      description: '请结合原内容快照、申诉理由、治理理由和社区评议记录，填写可追溯的裁决依据。',
      label: '人工复核意见（必填）',
      hint: isPass ? '说明为什么应恢复原内容' : '说明为什么应维持原治理决定',
      confirmLabel: '提交裁决',
      icon: Icons.gavel_outlined,
      maxLength: 500,
    );
    if (reason == null || reason.trim().isEmpty) return;
    setState(() => _submitting = true);
    try {
      await getSharedDio()
          .post('/admin/appeals/${widget.appealId}/review', data: {
        'decision': decision,
        'reason': reason.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('人工复核已完成')));
      Navigator.pop(context, true);
    } on DioException catch (error) {
      if (!mounted) return;
      final message = error.response?.data is Map
          ? error.response?.data['error']?.toString()
          : null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message ?? '人工复核失败')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<String?> _showReasonDialog({
    required String title,
    required String description,
    required String label,
    required String hint,
    required String confirmLabel,
    required IconData icon,
    required int maxLength,
  }) async {
    final controller = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final canSubmit = controller.text.trim().isNotEmpty;
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.xxl),
            titlePadding: const EdgeInsets.fromLTRB(
                AppSpacing.xxl, AppSpacing.xl, AppSpacing.xxl, AppSpacing.sm),
            contentPadding: const EdgeInsets.fromLTRB(
                AppSpacing.xxl, 0, AppSpacing.xxl, AppSpacing.sm),
            actionsPadding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            title: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                  child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(title),
              )),
            ]),
            content: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(description,
                        style: Theme.of(dialogContext).textTheme.bodySmall),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      minLines: 3,
                      maxLines: 5,
                      maxLength: maxLength,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: label,
                        hintText: hint,
                        alignLabelWithHint: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.42),
                        contentPadding: const EdgeInsets.all(AppSpacing.md),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          borderSide:
                              BorderSide(color: scheme.primary, width: 2),
                        ),
                      ),
                    ),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: canSubmit
                      ? () => Navigator.pop(dialogContext, controller.text)
                      : null,
                  child: Text(confirmLabel)),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final appeal = _appeal;
    return Scaffold(
      appBar: const AppPageAppBar(title: Text('公众法庭')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(_error!)))
              : appeal == null
                  ? const Center(child: Text('申诉不存在'))
                  : _content(appeal),
    );
  }

  Widget _content(Map<String, dynamic> appeal) {
    final status = appeal['status']?.toString() ?? 'pending';
    final myVote = appeal['my_vote']?.toString();
    final canVote = appeal['can_vote'] == true && status == 'pending';
    final post = appeal['post'] is Map
        ? Map<String, dynamic>.from(appeal['post'])
        : const <String, dynamic>{};
    final snapshot = _snapshot(appeal['evidence_snapshot']);
    final snapshotTitle = snapshot['title'] ?? post['title'] ?? '未提供标题';
    final snapshotContent = snapshot['content'] ?? post['content'] ?? '未提供内容';
    final deadline = _formatDate(appeal['voting_deadline']);
    final isAppellant = appeal['is_appellant'] == true;
    final isAdmin = appeal['is_admin'] == true;
    final canRecuse = appeal['can_recuse'] == true;
    final imageFileIds = snapshot['image_file_ids'] is List
        ? (snapshot['image_file_ids'] as List)
            .whereType<num>()
            .map((id) => id.toInt())
            .where((id) => id > 0)
            .toList()
        : const <int>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(children: [
          Expanded(
              child: Text('案件 #${appeal['id'] ?? widget.appealId}',
                  style: Theme.of(context).textTheme.titleLarge)),
          Chip(label: Text(_status(status))),
        ]),
        const SizedBox(height: 6),
        Text('社区帖子治理复核', style: Theme.of(context).textTheme.bodyMedium),
        if (deadline != null) ...[
          const SizedBox(height: 4),
          Text('评议截止：$deadline', style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 20),
        _EvidenceSection(
            title: '原内容快照', content: '$snapshotTitle\n\n$snapshotContent'),
        if (imageFileIds.isNotEmpty)
          _EvidenceImages(appealId: widget.appealId, fileIds: imageFileIds),
        _EvidenceSection(
            title: '申诉理由',
            content: (appeal['appellant_reason'] ?? '未填写').toString()),
        _EvidenceSection(
            title: '原治理理由',
            content: (appeal['admin_reason'] ?? '暂无处理理由').toString()),
        if (status == 'review_required')
          _EvidenceSection(
              title: '转人工原因',
              content: _escalationReason(
                  (appeal['escalation_reason'] ?? '').toString())),
        if (status != 'pending')
          _EvidenceSection(
              title: '社区复核结果',
              content: (appeal['result'] ?? _status(status)).toString()),
        if ((appeal['support_count'] ?? 0) != 0 ||
            (appeal['oppose_count'] ?? 0) != 0)
          Text(
              '支持申诉 ${appeal['support_count'] ?? 0} · 维持处理 ${appeal['oppose_count'] ?? 0}'),
        if (myVote != null && myVote.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('你的陪审意见：${myVote == 'support' ? '支持申诉' : '维持原处理'}')),
        if (isAppellant && status == 'pending')
          const _RoleHint(text: '这是你的申诉，案件正在由随机陪审员评议。'),
        if (isAdmin && status == 'pending')
          const _RoleHint(text: '你是原治理管理员，请等待公众法庭或人工复核结果。'),
        if (appeal['is_recused'] == true)
          const _RoleHint(text: '你已回避本案，不再参与本案评议。'),
        if (status == 'review_required' && !widget.adminReviewMode)
          const _RoleHint(text: '社区评议未形成有效裁决，案件正在等待独立管理员人工复核。'),
        if (widget.adminReviewMode && status == 'review_required') ...[
          const SizedBox(height: 16),
          _ManualReviewPanel(
            submitting: _submitting,
            onPass: () => _manualResolve('pass'),
            onReject: () => _manualResolve('reject'),
          ),
        ],
        if (canRecuse)
          Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                  onPressed: _recuse,
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('申请回避'))),
        const SizedBox(height: 24),
        if (canVote)
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: _submitting ? null : () => _vote('support'),
                    icon: const Icon(Icons.check),
                    label: const Text('支持申诉'))),
            const SizedBox(width: 12),
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: _submitting ? null : () => _vote('oppose'),
                    icon: const Icon(Icons.close),
                    label: const Text('维持处理'))),
          ])
        else if (status == 'pending' && appeal['is_recused'] == true)
          const Text('你已回避本案，不再参与投票。')
        else if (status == 'pending')
          const Text('你不是本案陪审员，或已经提交过意见。'),
      ],
    );
  }

  String _status(String status) => switch (status) {
        'pending' => '评议中',
        'pass' => '申诉通过',
        'reject' => '维持原处理',
        'review_required' => '待人工复核',
        _ => status,
      };

  String _escalationReason(String reason) => switch (reason) {
        'insufficient_jury' => '符合条件的陪审员不足 5 人，无法组成法定评议人数。',
        'insufficient_votes' => '截止时有效意见不足 5 票，转交独立管理员复核。',
        'tie' => '社区陪审形成平票，转交独立管理员复核。',
        _ => '社区评议未形成可直接执行的裁决。',
      };

  Map<String, dynamic> _snapshot(dynamic value) {
    if (value is! String || value.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  String? _formatDate(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return null;
    return '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class _RoleHint extends StatelessWidget {
  final String text;
  const _RoleHint({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text),
      );
}

class _ManualReviewPanel extends StatelessWidget {
  final bool submitting;
  final VoidCallback onPass;
  final VoidCallback onReject;

  const _ManualReviewPanel(
      {required this.submitting, required this.onPass, required this.onReject});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('人工复核意见', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text('请先核对原内容快照、申诉理由、治理理由和社区评议记录，再提交最终裁决。'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton(
                    onPressed: submitting ? null : onPass,
                    child: const Text('支持申诉'))),
            const SizedBox(width: 10),
            Expanded(
                child: OutlinedButton(
                    onPressed: submitting ? null : onReject,
                    child: const Text('维持处理'))),
          ]),
        ]),
      ),
    );
  }
}

class _EvidenceImages extends StatelessWidget {
  final int appealId;
  final List<int> fileIds;

  const _EvidenceImages({required this.appealId, required this.fileIds});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('图片证据', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: fileIds.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, index) => _EvidenceImage(
              appealId: appealId,
              fileId: fileIds[index],
            ),
          ),
        ),
      ]),
    );
  }
}

class _EvidenceImage extends StatefulWidget {
  final int appealId;
  final int fileId;

  const _EvidenceImage({required this.appealId, required this.fileId});

  @override
  State<_EvidenceImage> createState() => _EvidenceImageState();
}

class _EvidenceImageState extends State<_EvidenceImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await getSharedDio().get<List<int>>(
        '/appeals/${widget.appealId}/evidence/files/${widget.fileId}',
        options: Options(responseType: ResponseType.bytes),
      );
      if (mounted && response.data != null) {
        setState(() => _bytes = Uint8List.fromList(response.data!));
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 104,
        height: 104,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover)
            : _failed
                ? Container(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined),
                  )
                : Container(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
      ),
    );
  }
}

class _EvidenceSection extends StatelessWidget {
  final String title;
  final String content;
  const _EvidenceSection({required this.title, required this.content});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(content),
        ]),
      );
}
