import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'probe_controller.dart';

final class MobileProbeScreen extends StatefulWidget {
  const MobileProbeScreen({required this.controller, super.key});
  final ProbeController controller;
  @override
  State<MobileProbeScreen> createState() => _MobileProbeScreenState();
}

final class _MobileProbeScreenState extends State<MobileProbeScreen> {
  late final TextEditingController _studentId;
  late final TextEditingController _password;
  late final TextEditingController _captchaCode;
  late final TextEditingController _year;
  late final TextEditingController _semester;

  ProbeController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _studentId = TextEditingController();
    _password = TextEditingController();
    _captchaCode = TextEditingController();
    _year = TextEditingController(text: '2026');
    _semester = TextEditingController(text: '3');
  }

  @override
  void dispose() {
    _studentId.dispose();
    _password.dispose();
    _captchaCode.dispose();
    _year.dispose();
    _semester.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final canAct = _controller.isAuthenticated && !_controller.isBusy;
        return Scaffold(
          appBar: AppBar(title: const Text('教务移动探针')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  'Batch 4 / Android runtime',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _studentId,
                  enabled: !_controller.isBusy,
                  decoration: const InputDecoration(labelText: '学号'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !_controller.isBusy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '密码'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _year,
                        enabled: !_controller.isBusy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '学年'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _semester,
                        enabled: !_controller.isBusy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '学期'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _controller.isBusy ? null : _login,
                  icon: const Icon(Icons.login),
                  label: const Text('登录'),
                ),
                const SizedBox(height: 12),
                if (_controller.captchaChallenge != null) ...[
                  _CaptchaPanel(
                    challenge: _controller.captchaChallenge!,
                    codeController: _captchaCode,
                    busy: _controller.isBusy,
                    onRefresh: _controller.refreshCaptcha,
                    onContinue: () => _controller.continueLoginWithCaptcha(
                      code: _captchaCode.text,
                    ),
                    onCancel: _controller.cancelPendingLogin,
                  ),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _controller.isBusy
                          ? null
                          : _controller.diagnoseNetwork,
                      icon: const Icon(Icons.network_check),
                      label: const Text('网络诊断'),
                    ),
                    if (kDebugMode)
                      OutlinedButton.icon(
                        onPressed: _controller.isBusy
                            ? null
                            : () => _controller.diagnoseNetwork(
                                insecureTls: true,
                              ),
                        icon: const Icon(Icons.warning_amber_outlined),
                        label: const Text('Debug insecure TLS'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: canAct ? _controller.getProfile : null,
                      icon: const Icon(Icons.person_outline),
                      label: const Text('Profile'),
                    ),
                    OutlinedButton.icon(
                      onPressed: canAct
                          ? () => _controller.getCourses(
                              year: _year.text,
                              semester: _semester.text,
                            )
                          : null,
                      icon: const Icon(Icons.calendar_month),
                      label: const Text('课表'),
                    ),
                    OutlinedButton.icon(
                      onPressed: canAct
                          ? () => _controller.getGrades(
                              year: _year.text,
                              semester: _semester.text,
                            )
                          : null,
                      icon: const Icon(Icons.assessment_outlined),
                      label: const Text('成绩'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _StatusPanel(controller: _controller),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _login() async {
    final password = _password.text;
    _password.clear();
    await _controller.login(studentId: _studentId.text, password: password);
  }
}

final class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});
  final ProbeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = controller.status == ProbeStatus.error;
    final icon = controller.isBusy
        ? Icons.sync
        : isError
        ? Icons.error_outline
        : controller.status == ProbeStatus.success
        ? Icons.check_circle_outline
        : Icons.info_outline;
    final sessionLabel = switch (controller.sessionState) {
      SessionState.authenticated => 'authenticated',
      SessionState.awaitingCaptcha => 'awaitingCaptcha',
      SessionState.expired => 'expired',
      SessionState.authenticating => 'authenticating',
      SessionState.unauthenticated => 'unauthenticated',
    };
    final statusText = controller.errorCode == null
        ? controller.message
        : '${controller.errorCode}: ${controller.message}';
    return Semantics(
      liveRegion: true,
      label: '操作状态和会话状态',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: isError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    controller.operation,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Session: $sessionLabel'),
            const SizedBox(height: 4),
            Text(statusText),
            if (controller.diagnostic != null) ...[
              const SizedBox(height: 12),
              SelectableText(controller.diagnostic!.toDisplayString()),
            ],
          ],
        ),
      ),
    );
  }
}

final class _CaptchaPanel extends StatelessWidget {
  const _CaptchaPanel({
    required this.challenge,
    required this.codeController,
    required this.busy,
    required this.onRefresh,
    required this.onContinue,
    required this.onCancel,
  });

  final CaptchaChallenge challenge;
  final TextEditingController codeController;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('请输入验证码', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Semantics(
              label: '验证码图片',
              image: true,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Image.memory(
                  challenge.imageBytes,
                  height: 96,
                  width: 240,
                  fit: BoxFit.contain,
                  gaplessPlayback: false,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              enabled: !busy,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: '验证码'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : onRefresh,
                  child: const Text('换一张'),
                ),
                FilledButton(
                  onPressed: busy ? null : onContinue,
                  child: const Text('继续登录'),
                ),
                TextButton(
                  onPressed: busy ? null : onCancel,
                  child: const Text('取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
