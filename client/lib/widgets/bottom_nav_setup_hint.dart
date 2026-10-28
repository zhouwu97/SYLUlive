import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../screens/settings/bottom_navigation_settings_screen.dart';

/// Dismissible first-use guidance, with a direct route to the real settings.
class BottomNavSetupHint extends StatefulWidget {
  const BottomNavSetupHint({super.key, this.eligible = true});
  final bool eligible;
  @override
  State<BottomNavSetupHint> createState() => _BottomNavSetupHintState();
}

class _BottomNavSetupHintState extends State<BottomNavSetupHint> with WidgetsBindingObserver {
  Timer? _delay;
  bool _visible = false;
  bool _dismissed = false;
  bool get _canShow => widget.eligible && (ModalRoute.of(context)?.isCurrent ?? true)
      && (WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (mounted) setState(() {}); }
  @override
  void dispose() { _delay?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  void _dismiss(ThemeProvider theme) {
    setState(() { _visible = false; _dismissed = true; });
    unawaited(theme.dismissBottomNavSetupHint());
  }
  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    if (!_canShow) { _delay?.cancel(); _delay = null; return const SizedBox.shrink(); }
    if (!_visible && !_dismissed && theme.showBottomNavSetupHint && _delay == null) {
      // Wait until startup navigation/dialogs have settled on a visible home.
      _delay = Timer(const Duration(milliseconds: 800), () {
        _delay = null;
        if (!mounted || !_canShow || !theme.showBottomNavSetupHint) return;
        setState(() => _visible = true);
        // Record display, not only dismissal: a killed process must not repeat it.
        unawaited(theme.markBottomNavSetupHintSeen());
      });
    }
    if (!_visible) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                          const Text('首次使用建议',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const Text('请进入底部导航栏设置调低动画强度；无需液态效果时可选择「关」。'),
                          Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                    onPressed: () => _dismiss(theme),
                                    child: const Text('知道了')),
                                TextButton(
                                    onPressed: () {
                                      _dismiss(theme);
                                      Navigator.of(context).push(MaterialPageRoute<
                                              void>(
                                          builder: (_) =>
                                              const BottomNavigationSettingsScreen()));
                                    },
                                    child: const Text('去设置')),
                              ]),
                        ])),
              ),
            )));
  }
}
