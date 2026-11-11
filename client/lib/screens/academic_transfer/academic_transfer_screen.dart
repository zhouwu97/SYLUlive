import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../features/academic/application/academic_session_controller.dart';
import '../../features/academic/domain/academic_provider.dart';
import '../../features/academic_transfer/academic_transfer_payload.dart';
import '../../features/academic_transfer/academic_transfer_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_schedule_provider.dart';
import '../../providers/edu_provider.dart';
import '../../services/exam_schedule_repository.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_page_background.dart';
import '../../widgets/campus/campus_theme.dart';

enum _Phase { scanning, claiming, confirm, uploading, done, failed }

/// 课表「扫码同步到网页」：扫描网页上的二维码，核对后把本机资料加密发给网页。
///
/// 资料只从本机加密缓存读取，不访问学校系统；服务器只中转密文。
/// 离开页面而没有完成同步时会作废这张二维码，网页随即提示重新生成。
class AcademicTransferScreen extends StatefulWidget {
  const AcademicTransferScreen({
    super.key,
    required this.dio,
    this.initialLink,
    this.loader,
  });

  final Dio dio;

  /// 从系统相机或网页落地页打开时已带有二维码内容，直接进入核对。
  final AcademicTransferLink? initialLink;
  final AcademicTransferLoader? loader;

  @override
  State<AcademicTransferScreen> createState() => _AcademicTransferScreenState();
}

class _AcademicTransferScreenState extends State<AcademicTransferScreen> {
  MobileScannerController? _scanner;
  _Phase _phase = _Phase.scanning;
  AcademicTransferLink? _link;
  AcademicTransferApi? _api;
  AcademicTransferBundle? _bundle;
  Set<AcademicTransferPart> _selected = <AcademicTransferPart>{};
  String _error = '';
  bool _canRescan = true;
  bool _claimed = false;
  bool _uploaded = false;
  String _appUserId = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final link = widget.initialLink;
    if (link != null) {
      // 带着二维码内容进入时不打开相机，首帧就显示核对进度。
      _phase = _Phase.claiming;
      WidgetsBinding.instance.addPostFrameCallback((_) => _start(link));
    } else {
      _scanner = MobileScannerController(
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    }
  }

  @override
  void dispose() {
    _generation++;
    final link = _link, api = _api;
    if (_claimed && !_uploaded && link != null && api != null) {
      unawaited(api.cancel(link.sessionId));
    }
    _scanner?.dispose();
    super.dispose();
  }

  String _sourceAccountId() {
    final auth = context.read<AuthProvider>();
    final academic = context.read<AcademicSessionController?>();
    final edu = context.read<EduProvider?>();
    return <String?>[
          academic?.identity?.studentId,
          academic?.studentId,
          edu?.studentId,
          auth.user?.studentId,
        ]
            .whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .firstOrNull ??
        '';
  }

  AcademicTransferContext _context(String appUserId) {
    final schedule = context.read<CourseScheduleProvider>();
    final edu = context.read<EduProvider?>();
    final provider = switch (schedule.academicIdentity?.providerId) {
      AcademicProviderId.syluGraduate => 'graduate',
      AcademicProviderId.syluUndergraduate => 'undergraduate',
      null => '',
    };
    return AcademicTransferContext(
      appUserId: appUserId,
      sourceAccountId: _sourceAccountId(),
      identityNamespace: edu?.academicIdentityNamespace,
      provider: provider,
      currentYear: schedule.selectedYear,
      currentSemester: schedule.selectedSemester,
      currentTermStart: schedule.semesterStart,
      currentFetchedAt: schedule.lastFetchedAt,
      currentCourses:
          schedule.courses.map((course) => course.toJson()).toList(),
    );
  }

  Future<void> _start(AcademicTransferLink link) async {
    final auth = context.read<AuthProvider>();
    final appUserId = auth.user?.id.toString() ?? '';
    if (!auth.isLoggedIn || appUserId.isEmpty) {
      _fail('请先登录沈理校园 App，并与网页使用同一个账号。', canRescan: false);
      return;
    }
    final generation = ++_generation;
    _appUserId = appUserId;
    _link = link;
    _api = AcademicTransferApi(widget.dio, appUserId: appUserId);
    await _scanner?.stop();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.claiming;
      _error = '';
    });
    final transferContext = _context(appUserId);
    final loader = widget.loader ??
        AcademicTransferLoader(loadExams: ExamScheduleRepository().load);
    try {
      // 先告诉网页「已扫到」，同时读取本机资料，两者互不依赖。
      final results = await Future.wait<Object?>(<Future<Object?>>[
        _api!.claim(link.sessionId).then((_) => null),
        loader.load(transferContext),
      ]);
      _claimed = true;
      if (!mounted || generation != _generation) return;
      final bundle = results[1]! as AcademicTransferBundle;
      setState(() {
        _bundle = bundle;
        _selected = AcademicTransferPart.values
            .where((part) => bundle.count(part) > 0)
            .toSet();
        _phase = _Phase.confirm;
      });
    } on AcademicTransferException catch (error) {
      if (!mounted || generation != _generation) return;
      _fail(error.message,
          canRescan: error.failure != AcademicTransferFailure.accountMismatch);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _fail('读取本机资料失败，请稍后重试。');
    }
  }

  Future<void> _upload() async {
    final link = _link, api = _api, bundle = _bundle;
    if (link == null || api == null || bundle == null || _selected.isEmpty) {
      return;
    }
    // 核对期间切换了账号时停止，避免把另一个账号的资料发给网页。
    if (context.read<AuthProvider>().user?.id.toString() != _appUserId) {
      _fail('App 登录账号已改变，本次没有同步任何资料。', canRescan: false);
      return;
    }
    final generation = _generation;
    setState(() => _phase = _Phase.uploading);
    try {
      await api.upload(link, bundle.encode(_selected));
      _uploaded = true;
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.done);
    } on AcademicTransferException catch (error) {
      if (!mounted || generation != _generation) return;
      if (error.failure == AcademicTransferFailure.tooLarge) {
        setState(() => _phase = _Phase.confirm);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
        return;
      }
      _fail(error.message,
          canRescan: error.failure != AcademicTransferFailure.accountMismatch);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _fail('加密或上传失败，请重新扫码。');
    }
  }

  void _fail(String message, {bool canRescan = true}) {
    setState(() {
      _phase = _Phase.failed;
      _error = message;
      _canRescan = canRescan;
    });
  }

  Future<void> _rescan() async {
    final link = _link, api = _api;
    if (_claimed && !_uploaded && link != null && api != null) {
      unawaited(api.cancel(link.sessionId));
    }
    _generation++;
    _claimed = false;
    _uploaded = false;
    _link = null;
    _bundle = null;
    _scanner ??= MobileScannerController(
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    setState(() => _phase = _Phase.scanning);
    try {
      await _scanner!.start();
    } catch (_) {}
  }

  void _onDetect(BarcodeCapture capture) {
    if (_phase != _Phase.scanning) return;
    for (final barcode in capture.barcodes) {
      final link = AcademicTransferLink.tryParse(barcode.rawValue);
      if (link != null) {
        unawaited(_start(link));
        return;
      }
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('这不是网页课表的同步二维码，请扫描网页「手机 App 扫码同步」里的码。'),
      ));
  }

  Future<void> _pickImage() async {
    final scanner = _scanner;
    if (scanner == null) return;
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !mounted) return;
    try {
      final capture = await scanner.analyzeImage(image.path);
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片里没有识别到二维码')),
        );
        return;
      }
      _onDetect(capture);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这台设备暂不支持从图片识别二维码')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final baseTheme = Theme.of(context);
    final pageBackground = CampusTheme.pageBackground(context);
    final scanning = _phase == _Phase.scanning;
    return Theme(
      data: CampusTheme.withBrandAccent(baseTheme),
      child: Scaffold(
        backgroundColor: scanning
            ? Colors.black
            : AppPageBackground.color(context, pageBackground),
        appBar: AppBar(
          title: const Text('扫码同步到网页'),
          backgroundColor: scanning
              ? Colors.black
              : AppPageBackground.color(context, pageBackground),
          foregroundColor:
              scanning ? Colors.white : baseTheme.colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            if (scanning && _scanner != null)
              IconButton(
                tooltip: '从相册识别',
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_library_outlined),
              ),
            if (scanning && _scanner != null)
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: _scanner!,
                builder: (context, state, _) => IconButton(
                  tooltip:
                      state.torchState == TorchState.on ? '关闭手电筒' : '打开手电筒',
                  onPressed: state.torchState == TorchState.unavailable
                      ? null
                      : _scanner!.toggleTorch,
                  icon: Icon(state.torchState == TorchState.on
                      ? Icons.flashlight_on
                      : Icons.flashlight_off_outlined),
                ),
              ),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: KeyedSubtree(
            key: ValueKey<_Phase>(_phase),
            child: switch (_phase) {
              _Phase.scanning => _buildScanner(),
              _Phase.claiming => const _Progress(text: '正在核对二维码并读取本机资料…'),
              _Phase.confirm => _buildConfirm(),
              _Phase.uploading => const _Progress(text: '正在加密并发送到网页…'),
              _Phase.done => _buildDone(),
              _Phase.failed => _buildFailed(),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildScanner() {
    final scanner = _scanner!;
    return LayoutBuilder(builder: (context, constraints) {
      final side = (constraints.maxWidth * 0.68).clamp(200.0, 300.0);
      final window = Rect.fromCenter(
        center: Offset(constraints.maxWidth / 2, constraints.maxHeight * 0.42),
        width: side,
        height: side,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: scanner,
            scanWindow: window,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScannerUnavailable(
              permissionDenied:
                  error.errorCode == MobileScannerErrorCode.permissionDenied,
              onPickImage: _pickImage,
            ),
          ),
          IgnorePointer(
              child: CustomPaint(painter: _ScanWindowPainter(window))),
          Positioned(
            left: 24,
            right: 24,
            top: window.bottom + 24,
            child: const Column(
              children: [
                Text(
                  '对准电脑网页上的二维码',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text(
                  '在网页课表页点「手机 App 扫码同步」即可看到二维码。\n扫码后会先让你核对要同步的内容。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _buildConfirm() {
    final bundle = _bundle!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final schedules =
        bundle.schedules.where((item) => item.courses.isNotEmpty).toList();
    final others = schedules.where((item) => item.kind != 'current').length;
    final current =
        schedules.where((item) => item.kind == 'current').firstOrNull;
    final activities = (bundle.erke?['activities'] as List?)?.length ?? 0;
    String scheduleSubtitle() {
      if (schedules.isEmpty) return '手机上还没有课表';
      final parts = <String>[
        if (current != null) '当前课表 ${current.courses.length} 门',
        if (others > 0) '其他学期和存档 $others 份',
      ];
      return parts.join(' · ');
    }

    final items = <(AcademicTransferPart, IconData, String, String)>[
      (
        AcademicTransferPart.schedules,
        Icons.calendar_month_outlined,
        '课表',
        scheduleSubtitle()
      ),
      (
        AcademicTransferPart.grades,
        Icons.bar_chart_outlined,
        '成绩',
        bundle.grades.isEmpty
            ? '手机上还没有成绩，可先在成绩页读取'
            : '${bundle.grades.length} 门课程'
      ),
      (
        AcademicTransferPart.exams,
        Icons.event_note_outlined,
        '考试安排',
        bundle.exams.isEmpty ? '没有考试安排' : '${bundle.exams.length} 场'
      ),
      (
        AcademicTransferPart.erke,
        Icons.workspace_premium_outlined,
        '二课',
        bundle.erke == null ? '手机上还没有二课资料，可先在二课页读取' : '学分汇总与 $activities 条活动'
      ),
      (
        AcademicTransferPart.physical,
        Icons.directions_run_outlined,
        '体测',
        bundle.count(AcademicTransferPart.physical) == 0
            ? '手机上还没有体测成绩，可先在体测页读取'
            : '${bundle.count(AcademicTransferPart.physical)} 个学年'
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        AppCardSurface(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: CampusTheme.primary.withValues(alpha: isDark ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: CampusTheme.primary.withValues(alpha: 0.18)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.computer_outlined, color: CampusTheme.primary),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已连接到网页',
                        style: TextStyle(
                            color: CampusTheme.primary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800)),
                    SizedBox(height: 6),
                    Text('选择要发送到这台电脑网页的资料。只同步一次，关闭网页后资料不会保留在电脑上。',
                        style: TextStyle(height: 1.55)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        AppCardSurface(
          decoration: BoxDecoration(
            color: isDark ? CampusTheme.darkCard : CampusTheme.card,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: isDark ? Colors.white10 : CampusTheme.border),
          ),
          child: Column(
            children: [
              for (final (part, icon, title, subtitle) in items)
                CheckboxListTile(
                  value: _selected.contains(part),
                  onChanged: bundle.count(part) == 0
                      ? null
                      : (checked) => setState(() {
                            checked == true
                                ? _selected.add(part)
                                : _selected.remove(part);
                          }),
                  secondary: Icon(icon),
                  title: Text(title),
                  subtitle: Text(subtitle),
                  controlAffinity: ListTileControlAffinity.trailing,
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline,
                size: 16, color: Theme.of(context).hintColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '资料在手机上加密后发送，只有扫码的那个网页能解开；服务器只做短暂中转，不保存内容。学校账号、密码和登录状态不会发送。',
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: Theme.of(context).hintColor),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: _selected.isEmpty ? null : _upload,
          icon: const Icon(Icons.send_outlined),
          label: Text(_selected.isEmpty ? '请至少选择一项' : '同步到网页'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          child: const Text('取消，不同步'),
        ),
      ],
    );
  }

  Widget _buildDone() {
    return _ResultView(
      icon: Icons.check_circle_rounded,
      color: CampusTheme.green,
      title: '已同步到网页',
      message: '请回到电脑查看课表。资料只在那个网页里显示，刷新或关闭网页后需要重新同步。',
      primaryLabel: '完成',
      onPrimary: () => Navigator.of(context).maybePop(),
    );
  }

  Widget _buildFailed() {
    return _ResultView(
      icon: Icons.error_outline_rounded,
      color: CampusTheme.orange,
      title: '同步没有完成',
      message: _error,
      primaryLabel: _canRescan ? '重新扫码' : '返回',
      onPrimary: _canRescan ? _rescan : () => Navigator.of(context).maybePop(),
      secondaryLabel: _canRescan ? '返回' : null,
      onSecondary: () => Navigator.of(context).maybePop(),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      );
}

class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: color),
              const SizedBox(height: 16),
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      height: 1.6, color: Theme.of(context).hintColor)),
              const SizedBox(height: 26),
              FilledButton(
                onPressed: onPrimary,
                style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
                child: Text(primaryLabel),
              ),
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onSecondary,
                  style: TextButton.styleFrom(minimumSize: const Size(200, 44)),
                  child: Text(secondaryLabel!),
                ),
              ],
            ],
          ),
        ),
      );
}

class _ScannerUnavailable extends StatelessWidget {
  const _ScannerUnavailable({
    required this.permissionDenied,
    required this.onPickImage,
  });

  final bool permissionDenied;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_photography_outlined,
                    color: Colors.white70, size: 52),
                const SizedBox(height: 14),
                Text(
                  permissionDenied ? '没有相机权限' : '相机暂时无法使用',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  permissionDenied
                      ? '请在系统设置中允许沈理校园使用相机，或截图网页二维码后从相册识别。'
                      : '可以截图网页上的二维码，再从相册识别；也可以用系统相机扫码，按提示在 App 中打开。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.6),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: onPickImage,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('从相册识别'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                    minimumSize: const Size(180, 46),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _ScanWindowPainter extends CustomPainter {
  const _ScanWindowPainter(this.window);
  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(window, const Radius.circular(18));
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(frame),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_ScanWindowPainter oldDelegate) =>
      oldDelegate.window != window;
}
