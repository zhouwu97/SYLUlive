import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/theme_pack/theme_store_screen.dart';
import '../providers/theme_provider.dart';

/// 首次使用时的主题商城试用引导，复用底栏首次提示的延迟展示与防重复逻辑。
class ThemeStoreSetupHint extends StatefulWidget {
  const ThemeStoreSetupHint({super.key, this.eligible = true});

  final bool eligible;

  @override
  State<ThemeStoreSetupHint> createState() => _ThemeStoreSetupHintState();
}

class _ThemeStoreSetupHintState extends State<ThemeStoreSetupHint>
    with WidgetsBindingObserver {
  Timer? _delay;
  bool _visible = false;
  bool _dismissed = false;

  bool get _canShow =>
      widget.eligible &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _delay?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _dismiss(ThemeProvider theme) {
    setState(() {
      _visible = false;
      _dismissed = true;
    });
    unawaited(theme.dismissThemeStoreSetupHint());
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    if (!_canShow) {
      _delay?.cancel();
      _delay = null;
      return const SizedBox.shrink();
    }
    if (!_visible &&
        !_dismissed &&
        theme.showThemeStoreSetupHint &&
        _delay == null) {
      // 等待启动路由与弹窗稳定后再展示，避免遮挡或误消费。
      _delay = Timer(const Duration(milliseconds: 800), () {
        _delay = null;
        if (!mounted || !_canShow || !theme.showThemeStoreSetupHint) return;
        setState(() => _visible = true);
        // 展示即落盘，进程被杀重启后不再重复弹出。
        unawaited(theme.markThemeStoreSetupHintSeen());
      });
    }
    if (!_visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            borderRadius: BorderRadius.circular(16),
            elevation: 2,
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '发现主题商城',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text('去主题商城免费试用各种主题，随时一键切换或恢复默认外观。'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => _dismiss(theme),
                        child: const Text('知道了'),
                      ),
                      TextButton(
                        onPressed: () {
                          _dismiss(theme);
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ThemeStoreScreen(),
                            ),
                          );
                        },
                        child: const Text('去试用'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
