import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/lottery.dart';
import '../providers/auth_provider.dart';
import '../services/publish_session_scope.dart';
import '../theme/app_theme_tokens.dart';
import '../utils/app_feedback.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/app_page_background.dart';
import '../widgets/lottery/lottery_widgets.dart';

/// 发布或编辑抽奖活动的全屏页。保存成功后 pop(true)。
///
/// 开奖时间在界面上按北京时间的「墙上时间」编辑，提交时带 +08:00 偏移。
class LotteryPublishScreen extends StatefulWidget {
  const LotteryPublishScreen({super.key, this.editingEvent, this.ongoingTitle});

  /// 编辑时传入超管接口返回的活动。
  final Map<String, dynamic>? editingEvent;

  /// 新建时若已有进行中活动，传入其标题，用于提示发布后会被取消。
  final String? ongoingTitle;

  @override
  State<LotteryPublishScreen> createState() => _LotteryPublishScreenState();
}

class _LotteryPublishScreenState extends State<LotteryPublishScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _prizeCtrl;
  late final TextEditingController _descCtrl;
  late final PublishSessionScope? _session;
  late DateTime _drawTime;
  late String _prizeImage;
  Uint8List? _localImageBytes;
  bool _uploading = false;
  bool _submitting = false;

  bool get _isEdit => widget.editingEvent != null;

  bool _ownsSession(AuthProvider auth) =>
      _session?.owns(
        userId: auth.user?.id,
        sessionEpoch: auth.accountSessionEpoch,
      ) ??
      false;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id;
    _session = userId == null
        ? null
        : PublishSessionScope(
            accountId: userId, accountSessionEpoch: auth.accountSessionEpoch);
    final ev = widget.editingEvent;
    _titleCtrl = TextEditingController(text: '${ev?['title'] ?? ''}');
    _prizeCtrl = TextEditingController(text: '${ev?['prize_name'] ?? ''}');
    _descCtrl = TextEditingController(text: '${ev?['description'] ?? ''}');
    _prizeImage = '${ev?['prize_image'] ?? ''}';
    final parsed = DateTime.tryParse('${ev?['draw_time'] ?? ''}');
    if (parsed == null) {
      _drawTime = _quickOptions().first.$2;
    } else {
      final wall = lotteryBeijingWallTime(parsed);
      _drawTime =
          DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _prizeCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  static DateTime _nowWall() => lotteryBeijingWallTime(DateTime.now());

  static DateTime _wallToUtc(DateTime v) =>
      v.subtract(lotteryBeijingOffset);

  static List<(String, DateTime)> _quickOptions() =>
      lotteryQuickDrawTimes(DateTime.now());

  String _wallLabel(DateTime v) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    String two(int n) => n.toString().padLeft(2, '0');
    final year = v.year == _nowWall().year ? '' : '${v.year}-';
    return '$year${two(v.month)}-${two(v.day)} 周${weekdays[v.weekday - 1]} '
        '${two(v.hour)}:${two(v.minute)}';
  }

  String _relativeLabel(DateTime v) {
    final diff = v.difference(_nowWall());
    if (diff <= Duration.zero) return '已过当前时间';
    if (diff.inDays >= 1) return '约 ${diff.inDays} 天后';
    if (diff.inHours >= 1) return '约 ${diff.inHours} 小时后';
    return '约 ${diff.inMinutes.clamp(1, 59)} 分钟后';
  }

  Future<void> _pickCustomTime() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final now = _nowWall();
    final date = await showDatePicker(
      context: context,
      currentDate: now,
      initialDate: _drawTime.isBefore(now) ? now : _drawTime,
      firstDate: DateTime.utc(now.year, now.month, now.day),
      lastDate: DateTime.utc(now.year, now.month, now.day + 365),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_drawTime),
    );
    if (time == null || !mounted) return;
    setState(() => _drawTime =
        DateTime.utc(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _pickImage() async {
    final session = _session;
    final auth = context.read<AuthProvider>();
    if (session == null || !_ownsSession(auth) || _uploading || _submitting) {
      return;
    }
    final dio = auth.dio;
    final tokens = AppThemeTokens.of(context);
    setState(() => _uploading = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted || !_ownsSession(auth)) return;
      final cropped = await ImageCropper().cropImage(
        sourcePath: picked.path,
        maxWidth: 1800,
        maxHeight: 1200,
        compressQuality: 85,
        aspectRatio: const CropAspectRatio(ratioX: 3, ratioY: 2),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '裁剪奖品图 (3:2)',
            toolbarColor: tokens.primary,
            toolbarWidgetColor: tokens.onPrimary,
            activeControlsWidgetColor: tokens.primary,
            backgroundColor: tokens.background,
            lockAspectRatio: true,
          ),
          IOSUiSettings(
            title: '裁剪奖品图 (3:2)',
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
          ),
        ],
      );
      if (cropped == null || !mounted || !_ownsSession(auth)) return;
      final bytes = await cropped.readAsBytes();
      if (!mounted || !_ownsSession(auth)) return;
      final res = await dio.post('/upload',
          options: Options(extra: session.requestExtra),
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(
              bytes,
              filename:
                  'lottery_prize_${DateTime.now().millisecondsSinceEpoch}.jpg',
              contentType: DioMediaType('image', 'jpeg'),
            ),
          }));
      if (!mounted || !_ownsSession(auth)) return;
      final url = res.data is Map ? res.data['url'] : null;
      if (url is! String || url.isEmpty) {
        AppFeedback.showSnackBar(context, '图片处理失败，请重试', isError: true);
        return;
      }
      setState(() {
        _prizeImage = url;
        _localImageBytes = bytes;
      });
    } catch (_) {
      if (mounted && _ownsSession(auth)) {
        AppFeedback.showSnackBar(context, '图片处理失败，请重试', isError: true);
      }
    } finally {
      if (mounted && _ownsSession(auth)) setState(() => _uploading = false);
    }
  }

  LotteryEvent _draftEvent() => LotteryEvent(
        id: 0,
        title: _titleCtrl.text.trim().isEmpty ? '抽奖标题' : _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        prizeName:
            _prizeCtrl.text.trim().isEmpty ? '奖品名称' : _prizeCtrl.text.trim(),
        prizeImage: _prizeImage,
        drawTime: _wallToUtc(_drawTime),
        status: LotteryEvent.statusOngoing,
      );

  void _preview() {
    FocusManager.instance.primaryFocus?.unfocus();
    final ev = _draftEvent();
    final localImageBytes = _localImageBytes;
    showAppModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('用户端预览',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color: AppThemeTokens.of(ctx).textSecondary)),
            ),
            LotteryHeroCard(
              event: ev,
              participantCount: 0,
              remaining: ev.drawTime.difference(DateTime.now()),
              localImageBytes: localImageBytes,
            ),
            if (ev.description.isNotEmpty) ...[
              const SizedBox(height: 16),
              LotteryDescriptionCard(description: ev.description),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final session = _session;
    final auth = context.read<AuthProvider>();
    if (session == null || !_ownsSession(auth) || _uploading || _submitting) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final title = _titleCtrl.text.trim();
    final prize = _prizeCtrl.text.trim();
    if (title.isEmpty || prize.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写标题和奖品', isError: true);
      return;
    }
    if (!_wallToUtc(_drawTime).isAfter(DateTime.now().toUtc())) {
      AppFeedback.showSnackBar(context, '开奖时间必须晚于当前时间', isError: true);
      return;
    }
    final dio = auth.dio;
    final navigator = Navigator.of(context);
    setState(() => _submitting = true);
    final payload = {
      'title': title,
      'prize_name': prize,
      'prize_image': _prizeImage,
      'description': _descCtrl.text.trim(),
      'draw_time': formatLotteryBeijingRfc3339(_drawTime),
    };
    final options = Options(extra: session.requestExtra);
    try {
      if (_isEdit) {
        await dio.put('/super/lottery/${widget.editingEvent!['id']}',
            data: payload, options: options);
      } else {
        await dio.post('/super/lottery', data: payload, options: options);
      }
      if (mounted && _ownsSession(auth)) navigator.pop(true);
    } on DioException catch (e) {
      if (!mounted || !_ownsSession(auth)) return;
      AppFeedback.showSnackBar(context,
          AppFeedback.dioErrorMessage(e, fallback: _isEdit ? '更新失败' : '发布失败'),
          isError: true);
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final busy = _submitting || _uploading;
    final ongoingTitle = widget.ongoingTitle;
    return Scaffold(
      backgroundColor: AppPageBackground.color(context, tokens.background),
      appBar: AppBar(
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded),
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(_isEdit ? '编辑抽奖' : '发布抽奖',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppPageBackground.color(context, Colors.transparent),
        elevation: 0,
      ),
      bottomNavigationBar: _buildBottomBar(busy),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (!_isEdit && ongoingTitle != null) ...[
            _buildWarning('发布后会自动取消进行中的「$ongoingTitle」'),
            const SizedBox(height: 20),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const LotterySectionTitle('奖品图片', size: 15),
              const SizedBox(width: 8),
              Text('选填 · 展示在用户页顶部',
                  style: TextStyle(fontSize: 12, color: tokens.textTertiary)),
            ],
          ),
          const SizedBox(height: 10),
          _buildImageSlot(),
          const SizedBox(height: 16),
          LotteryCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LotterySectionTitle('基本信息', size: 15),
                const SizedBox(height: 12),
                _buildField('抽奖标题', _titleCtrl, maxLength: 100),
                const SizedBox(height: 12),
                _buildField('奖品名称', _prizeCtrl, maxLength: 100),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildTimeCard(),
          const SizedBox(height: 16),
          LotteryCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LotterySectionTitle('活动说明', size: 15),
                const SizedBox(height: 4),
                Text('以「1. 2. 3.」编号书写，用户页会自动分条显示',
                    style: TextStyle(fontSize: 12, color: tokens.textTertiary)),
                const SizedBox(height: 10),
                _buildField(null, _descCtrl, maxLength: 2000, maxLines: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarning(String text) {
    final (fg, bg) = lotteryToneColors(context, LotteryTone.warning);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500, color: fg)),
          ),
        ],
      ),
    );
  }

  Widget _buildImageSlot() {
    final tokens = AppThemeTokens.of(context);
    const radius = 18.0;
    final Widget content;
    if (_uploading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_prizeImage.isNotEmpty) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          LotteryPrizeArt(
              imagePath: _prizeImage,
              localImageBytes: _localImageBytes,
              radius: radius,
              iconSize: 96),
          Positioned(
            right: 10,
            bottom: 10,
            child: Row(
              children: [
                _overlayButton(Icons.swap_horiz_rounded, '更换', _pickImage),
                const SizedBox(width: 8),
                _overlayButton(Icons.delete_outline_rounded, '移除',
                    () => setState(() {
                          _prizeImage = '';
                          _localImageBytes = null;
                        })),
              ],
            ),
          ),
        ],
      );
    } else {
      content = InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: _submitting ? null : _pickImage,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: tokens.primaryContainer,
              child: Icon(Icons.add_photo_alternate_outlined,
                  size: 28, color: tokens.onPrimaryContainer),
            ),
            const SizedBox(height: 12),
            Text('添加奖品图片',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: tokens.textPrimary)),
            const SizedBox(height: 4),
            Text('建议横图 3:2；不传则显示主题礼盒插画',
                style: TextStyle(fontSize: 12, color: tokens.textSecondary)),
          ],
        ),
      );
    }
    return AspectRatio(
      aspectRatio: 358 / 190,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.card,
          borderRadius: BorderRadius.circular(radius),
          border: _prizeImage.isEmpty
              ? Border.all(
                  color: tokens.primary.withValues(alpha: 0.45), width: 1.2)
              : null,
        ),
        child: content,
      ),
    );
  }

  Widget _overlayButton(IconData icon, String label, VoidCallback onTap) {
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.textPrimary.withValues(alpha: 0.85),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _submitting ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: tokens.background),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tokens.background)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(String? label, TextEditingController ctrl,
      {required int maxLength, int maxLines = 1}) {
    final tokens = AppThemeTokens.of(context);
    return TextField(
      controller: ctrl,
      enabled: !_submitting,
      maxLength: maxLength,
      maxLines: maxLines,
      minLines: maxLines > 1 ? 4 : 1,
      decoration: InputDecoration(
        labelText: label,
        hintText: label == null ? '例如：1. 兑换方式… 2. 使用范围…' : null,
        filled: true,
        fillColor: tokens.inputFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildTimeCard() {
    final tokens = AppThemeTokens.of(context);
    final options = _quickOptions();
    final isCustom = !options.any((o) => o.$2 == _drawTime);
    Widget chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelPadding: const EdgeInsets.symmetric(horizontal: 2),
          onSelected: _submitting ? null : (_) => onTap(),
          selectedColor: tokens.primaryContainer,
          backgroundColor: tokens.surfaceMuted,
          side:
              BorderSide(color: selected ? tokens.primary : Colors.transparent),
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? tokens.onPrimaryContainer : tokens.textSecondary,
          ),
          shape: const StadiumBorder(),
        );
    return LotteryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: LotterySectionTitle('开奖时间', size: 15)),
              Text('北京时间',
                  style: TextStyle(fontSize: 12, color: tokens.textTertiary)),
            ],
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: _submitting ? null : _pickCustomTime,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.event_outlined, size: 20, color: tokens.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_wallLabel(_drawTime),
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: tokens.textPrimary)),
                  ),
                  Text(_relativeLabel(_drawTime),
                      style: TextStyle(
                          fontSize: 12.5, color: tokens.textSecondary)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in options)
                chip(o.$1, o.$2 == _drawTime,
                    () => setState(() => _drawTime = o.$2)),
              chip('自定义', isCustom, _pickCustomTime),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(bool busy) {
    final tokens = AppThemeTokens.of(context);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: busy ? null : _preview,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('预览'),
                style: OutlinedButton.styleFrom(
                  shape: shape,
                  backgroundColor: tokens.card,
                  side: BorderSide(color: tokens.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: busy ? null : _submit,
                  style: FilledButton.styleFrom(shape: shape),
                  child: _submitting
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: tokens.onPrimary),
                        )
                      : Text(_isEdit ? '保存修改' : '发布抽奖',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
