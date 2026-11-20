import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../services/publish_session_scope.dart';
import '../widgets/app_dialog.dart';
import '../widgets/canteen/canteen_merchant_form.dart';
import '../widgets/image_upload_widget.dart';

/// 独立投稿页：选择、上传和最终提交始终属于打开页面时的账号会话。
class CanteenSubmitScreen extends StatefulWidget {
  const CanteenSubmitScreen({super.key, this.initialName = ''});
  final String initialName;

  @override
  State<CanteenSubmitScreen> createState() => _CanteenSubmitScreenState();
}

class _CanteenSubmitScreenState extends State<CanteenSubmitScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final AuthProvider _auth;
  late final PublishSessionScope _scope;
  String _area = '', _floor = '';
  List<UploadedImage> _images = const [];
  bool _saving = false,
      _uploading = false,
      _leaving = false,
      _confirmingLeave = false;
  String? _error;

  bool get _sessionValid =>
      _auth.isLoggedIn &&
      _scope.owns(
          userId: _auth.user?.id, sessionEpoch: _auth.accountSessionEpoch);
  bool get _busy => _saving || _uploading;
  bool get _dirty =>
      _name.text.trim() != widget.initialName.trim() ||
      _area.isNotEmpty ||
      _floor.isNotEmpty ||
      _images.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName)
      ..addListener(_changed);
    _auth = context.read<AuthProvider>();
    _scope = PublishSessionScope(
        accountId: _auth.user?.id ?? 0,
        accountSessionEpoch: _auth.accountSessionEpoch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sessionValid) context.read<CanteenProvider>().loadMeta();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _showError(String message) {
    setState(() => _error = message);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    if (_busy || !_sessionValid) return;
    if (!_form.currentState!.validate()) return;
    if (_area.isEmpty) {
      _showError('请选择商家所在区域');
      return;
    }
    if (_area != '其他' && _floor.isEmpty) {
      _showError('请选择商家所在楼层');
      return;
    }
    if (_images.isEmpty) {
      _showError('请上传一张商家门面图片');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    final provider = context.read<CanteenProvider>();
    final ok = await provider.addCanteen(_name.text.trim(), _images.single.url,
        locationArea: _area,
        locationFloor: _area == '其他' ? '' : _floor,
        sessionScope: _scope);
    if (!mounted || !_sessionValid) return;
    setState(() => _saving = false);
    if (ok) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sessionValid) Navigator.pop(context, true);
      });
    } else {
      _showError(provider.errorMessage ?? '提交失败，输入和图片已保留，请重试');
    }
  }

  Future<void> _confirmLeave() async {
    if (_busy || _confirmingLeave) return;
    _confirmingLeave = true;
    final leave = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
              title: const Text('放弃本次提交？'),
              content: const Text('已填写的内容不会保存，下次需要重新填写。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续填写')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('放弃提交')),
              ],
            ));
    _confirmingLeave = false;
    if (leave == true && mounted) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AuthProvider>();
    final provider = context.watch<CanteenProvider>();
    final valid = _sessionValid;
    return PopScope(
      canPop: _leaving || !valid || (!_busy && !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Form(
        key: _form,
        child: CanteenMerchantForm(
          title: '提交商家',
          submitLabel: !valid
              ? '提交审核'
              : _saving
                  ? '提交中…'
                  : _uploading
                      ? '图片上传中…'
                      : '提交审核',
          onSubmit: valid ? _submit : null,
          busy: valid && _busy,
          children: !valid
              ? [const CanteenFormNotice('登录状态已变更，请返回并重新登录后提交', error: true)]
              : [
                  if (_error != null) CanteenFormNotice(_error!, error: true),
                  CanteenMerchantNameField(
                      controller: _name, enabled: !_saving),
                  const SizedBox(height: 20),
                  CanteenLocationFields(
                    areas: provider.locationAreas,
                    floors: provider.locationFloors,
                    area: _area,
                    floor: _floor,
                    enabled: !_saving,
                    onAreaChanged: (value) => setState(() {
                      _area = value;
                      _error = null;
                      if (value == '其他') _floor = '';
                    }),
                    onFloorChanged: (value) => setState(() {
                      _floor = value;
                      _error = null;
                    }),
                  ),
                  const SizedBox(height: 28),
                  Text('商家图片', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  AbsorbPointer(
                    absorbing: _saving,
                    child: ImageUploadWidget(
                      maxImages: 1,
                      onBusyChanged: (busy) {
                        if (mounted && _sessionValid) {
                          setState(() => _uploading = busy);
                        }
                      },
                      onImagesUploaded: (images) {
                        if (mounted && _sessionValid) {
                          setState(() {
                            _images = List.of(images);
                            _error = null;
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('门面或招牌照片，1 张，最大 10MB',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 28),
                  Text('审核通过后公开，可在「我的食堂贡献」查看进度。',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
        ),
      ),
    );
  }
}
