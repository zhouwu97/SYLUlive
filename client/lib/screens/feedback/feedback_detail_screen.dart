import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/feedback_ticket.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../utils/app_feedback.dart';
import '../../services/idempotency_key.dart';
import '../../services/request_id.dart';
import '../../services/publish_session_scope.dart';
import '../image_viewer_screen.dart';

class FeedbackDetailScreen extends StatefulWidget {
  final int ticketId;
  final bool isAdmin;

  const FeedbackDetailScreen({
    super.key,
    required this.ticketId,
    this.isAdmin = false,
  });

  @override
  State<FeedbackDetailScreen> createState() => _FeedbackDetailScreenState();
}

class _FeedbackDetailScreenState extends State<FeedbackDetailScreen>
    with WidgetsBindingObserver {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _msgFocusNode = FocusNode();

  FeedbackTicket? _ticket;
  FeedbackInitialSubmission? _initialSubmission;
  List<FeedbackMessage> _messages = [];
  List<FeedbackStatusHistory> _history = [];
  bool _loading = true;
  String? _error;
  bool _sending = false;
  int _sendGeneration = 0;
  int _detailRequestGeneration = 0;
  AuthProvider? _authProvider;
  int? _observedAccountId;
  int _observedAccountEpoch = -1;

  PublishSessionScope? _captureWriteScope(AuthProvider auth) {
    final accountId = auth.user?.id;
    if (accountId == null) return null;
    return PublishSessionScope(
      accountId: accountId,
      accountSessionEpoch: auth.accountSessionEpoch,
    );
  }

  bool _ownsWriteScope(AuthProvider auth, PublishSessionScope scope) =>
      mounted &&
      scope.owns(
        userId: auth.user?.id,
        sessionEpoch: auth.accountSessionEpoch,
      );

  Options _writeOptions(PublishSessionScope scope, {String? idempotencyKey}) =>
      Options(
        headers:
            idempotencyKey == null ? null : {'Idempotency-Key': idempotencyKey},
        extra: scope.requestExtra,
      );

  /// 账号身份只由「账号 ID + accountSessionEpoch」定义。
  ///
  /// `sessionGeneration` 在同账号的资料刷新、头像更新、consent 变化时也会计数，
  /// 拿它判断「是不是同一个账号」会让一次资料刷新丢掉未确认送达的幂等键，
  /// 用户再发一次就可能发出重复消息。它只用于把旧响应挡在 UI 之外。
  bool _sameAccountSession(AuthProvider auth, int? accountId, int accountEpoch) =>
      accountId != null &&
      auth.user?.id == accountId &&
      auth.accountSessionEpoch == accountEpoch;

  // 管理员专属状态
  bool _adminInternalNote = false;

  /// 上一次未确认送达的消息。
  ///
  /// 幂等键只对**同一份请求**有效。失败后用户改措辞、补图片、把"用户可见"
  /// 切成内部备注，都属于新的一条消息，继续用旧键只会换来
  /// idempotency_key_reused，用户会卡在"改了也提交不了"。
  /// 上一次未确认送达的消息（幂等键 + 请求指纹）。
  ({
    String idempotencyKey,
    String fingerprint,
    int accountId,
    int accountSessionEpoch,
  })? _pendingMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDetail();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthProvider>();
    if (!identical(_authProvider, auth)) {
      _authProvider?.removeListener(_handleAuthSessionChanged);
      _authProvider = auth;
      _observedAccountId = auth.user?.id;
      _observedAccountEpoch = auth.accountSessionEpoch;
      auth.addListener(_handleAuthSessionChanged);
    }
  }

  void _handleAuthSessionChanged() {
    final auth = _authProvider;
    if (!mounted || auth == null) return;
    final accountId = auth.user?.id;
    final accountEpoch = auth.accountSessionEpoch;
    // 只有真正换了账号会话才整页重来：同账号的资料刷新不该清掉待确认的消息。
    if (accountId == _observedAccountId &&
        accountEpoch == _observedAccountEpoch) {
      return;
    }
    _observedAccountId = accountId;
    _observedAccountEpoch = accountEpoch;
    _detailRequestGeneration++;
    _sendGeneration++;
    _pendingMessage = null;
    setState(() {
      _sending = false;
      _loading = true;
      _error = null;
      _ticket = null;
      _initialSubmission = null;
      _messages = [];
      _history = [];
    });
    _loadDetail();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _loadDetail(showLoading: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authProvider?.removeListener(_handleAuthSessionChanged);
    _msgController.dispose();
    _scrollController.dispose();
    _msgFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadDetail({bool showLoading = true}) async {
    final requestGeneration = ++_detailRequestGeneration;
    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    final accountEpoch = auth.accountSessionEpoch;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final path = widget.isAdmin
          ? '/admin/feedback/tickets/${widget.ticketId}'
          : '/feedback/tickets/${widget.ticketId}';

      final response = await auth.dio.get(path);

      if (response.statusCode == 200 && response.data != null) {
        final ticketData = response.data['ticket'] as Map<String, dynamic>;
        final msgList = (response.data['messages'] as List<dynamic>?) ?? [];
        final histList = (response.data['history'] as List<dynamic>?) ?? [];
        final initialData = response.data['initial_submission'];
        final incomingMessages = msgList
            .map((e) => FeedbackMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        final previousLastMessageId = _messages.fold<int>(
          0,
          (maxId, message) => message.id > maxId ? message.id : maxId,
        );
        final hasIncomingMessage = !showLoading &&
            incomingMessages.any(
              (message) =>
                  message.id > previousLastMessageId &&
                  (widget.isAdmin ? message.isUser : message.isAdmin),
            );

        if (mounted &&
            requestGeneration == _detailRequestGeneration &&
            _sameAccountSession(auth, accountId, accountEpoch)) {
          setState(() {
            _ticket = FeedbackTicket.fromJson(ticketData);
            _initialSubmission = initialData is Map<String, dynamic>
                ? FeedbackInitialSubmission.fromJson(initialData)
                : null;
            _messages = incomingMessages;
            _history = histList
                .map((e) =>
                    FeedbackStatusHistory.fromJson(e as Map<String, dynamic>))
                .toList();
            _loading = false;
            _error = null;
          });
          if (hasIncomingMessage) {
            AppFeedback.showSnackBar(
              context,
              widget.isAdmin ? '收到用户新消息' : '收到官方新回复',
            );
          }
        }
      } else {
        if (mounted && requestGeneration == _detailRequestGeneration) {
          setState(() {
            _loading = false;
            _error = '工单加载失败';
          });
        }
      }
    } catch (e) {
      if (mounted && requestGeneration == _detailRequestGeneration) {
        setState(() {
          _loading = false;
          _error = '网络异常，请重试';
        });
      }
    }
  }

  String _formatDateTime(DateTime value) {
    final dt = value.toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _sendMessage({
    List<int>? imageIds,
    String? content,
    bool? visibleToUser,
    PublishSessionScope? session,
  }) async {
    final text = (content ?? _msgController.text).trim();
    if (text.isEmpty && (imageIds == null || imageIds.isEmpty)) {
      return;
    }

    final auth = context.read<AuthProvider>();
    final scope = session ?? _captureWriteScope(auth);
    if (scope == null || !_ownsWriteScope(auth, scope)) return;
    final sendGeneration = ++_sendGeneration;
    setState(() => _sending = true);

    try {
      final visible = visibleToUser ?? !_adminInternalNote;
      // 内容、附件、可见范围任一变化都算新的一条消息，换新键；
      // 完全没改才是"原样重试"，必须复用同一把键让服务端重放上次结果。
      final fingerprint = feedbackMessageFingerprint(
        content: text,
        imageIds: imageIds,
        visibleToUser: visible,
      );
      final pending = _pendingMessage;
      // 只有同一次账号会话里的「同一份请求」才允许复用幂等键。
      // scope 已经确认过仍属于当前账号会话，因此和 scope 同身份就是「同一次账号会话」。
      final samePendingSession = pending != null &&
          pending.accountId == scope.accountId &&
          pending.accountSessionEpoch == scope.accountSessionEpoch;
      final idempotencyKey = resolveIdempotencyKey(
        fingerprint: fingerprint,
        pendingFingerprint: samePendingSession ? pending?.fingerprint : null,
        pendingKey: samePendingSession ? pending?.idempotencyKey : null,
      );
      _pendingMessage = (
        idempotencyKey: idempotencyKey,
        fingerprint: fingerprint,
        accountId: scope.accountId,
        accountSessionEpoch: scope.accountSessionEpoch,
      );
      Response response;

      if (widget.isAdmin) {
        response = await auth.dio.post(
          '/admin/feedback/tickets/${widget.ticketId}/messages',
          data: {
            'content': text.isNotEmpty ? text : '[图片]',
            'visible_to_user': visible,
            'image_ids': imageIds,
          },
          options: _writeOptions(scope, idempotencyKey: idempotencyKey),
        );
      } else {
        response = await auth.dio.post(
          '/feedback/tickets/${widget.ticketId}/messages',
          data: {
            'content': text.isNotEmpty ? text : '[图片]',
            'image_ids': imageIds,
          },
          options: _writeOptions(scope, idempotencyKey: idempotencyKey),
        );
      }

      if (!_ownsWriteScope(auth, scope)) return;
      // sessionGeneration 只用来挡旧响应，不用来定义账号身份。
      if (!mounted || sendGeneration != _sendGeneration) return;

      if (response.statusCode == 200) {
        _pendingMessage = null;
        _msgController.clear();
        await _loadDetail();
        // 滚到底部
        Future.delayed(const Duration(milliseconds: 200), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      } else {
        if (mounted) {
          AppFeedback.showSnackBar(context, '发送失败，请重试', isError: true);
        }
      }
    } on DioException catch (e) {
      if (!_ownsWriteScope(auth, scope)) return;
      if (!mounted || sendGeneration != _sendGeneration) return;
      final code = _idempotencyCode(e);
      // 键已不能代表同一条消息时丢弃它：下一次发送算新的一条，
      // 否则用户改了内容也永远提交不上去。其余失败保留键，网络恢复后可原样重试。
      if (idempotencyOutcomeFor(code) == IdempotencyOutcome.exhausted) {
        _pendingMessage = null;
      }
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          '发送失败: ${idempotencyUserMessage(code, AppFeedback.dioErrorMessage(e, fallback: '请稍后重试'))}',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted &&
          _ownsWriteScope(auth, scope) &&
          sendGeneration == _sendGeneration) {
        AppFeedback.showSnackBar(context, '发送失败: $e', isError: true);
      }
    } finally {
      if (mounted && sendGeneration == _sendGeneration) {
        setState(() => _sending = false);
      }
    }
  }

  /// 从响应体读取稳定的业务错误码，用于判断幂等键的去留。
  String? _idempotencyCode(DioException error) {
    final data = error.response?.data;
    if (data is Map) {
      final code = data['code']?.toString().trim();
      if (code != null && code.isNotEmpty) return code;
    }
    return null;
  }

  Future<void> _pickAndUploadImage() async {
    if (_sending) return;
    final auth = context.read<AuthProvider>();
    final scope = _captureWriteScope(auth);
    if (scope == null) return;
    final sendGeneration = ++_sendGeneration;
    final capturedVisibleToUser = !_adminInternalNote;
    final capturedContent = _msgController.text.trim();
    setState(() => _sending = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      if (!_ownsWriteScope(auth, scope)) return;

      final bytes = await picked.readAsBytes();
      if (!_ownsWriteScope(auth, scope)) return;
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: picked.name),
      });

      final uploadResp = await auth.dio
          .post('/upload', data: formData, options: _writeOptions(scope));
      if (!_ownsWriteScope(auth, scope)) return;
      if (uploadResp.statusCode == 200 && uploadResp.data != null) {
        final fileId = uploadResp.data['file_id'] as int? ?? 0;
        if (fileId > 0) {
          await _sendMessage(
            imageIds: [fileId],
            content: capturedContent,
            visibleToUser: capturedVisibleToUser,
            session: scope,
          );
        }
      }
    } catch (e) {
      if (_ownsWriteScope(auth, scope)) {
        AppFeedback.showGlobalToast('图片上传失败: $e',
            isError: true, context: context);
      }
    } finally {
      if (mounted && sendGeneration == _sendGeneration) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _reopenTicket() async {
    final auth = context.read<AuthProvider>();
    final scope = _captureWriteScope(auth);
    if (scope == null) return;
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新打开工单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请描述目前仍然存在的问题或异常现象：',
                style: TextStyle(fontSize: 13, color: Colors.black87)),
            const SizedBox(height: 8),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '输入具体情况……',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.white,
            ),
            child: const Text('提交重开'),
          ),
        ],
      ),
    );

    if (confirmed == true && reasonController.text.trim().isNotEmpty) {
      if (!_ownsWriteScope(auth, scope)) return;
      try {
        final res = await auth.dio.post(
          '/feedback/tickets/${widget.ticketId}/reopen',
          data: {'reason': reasonController.text.trim()},
          options: _writeOptions(scope, idempotencyKey: RequestId.newId()),
        );
        if (!_ownsWriteScope(auth, scope)) return;
        if (res.statusCode == 200) {
          if (mounted) {
            AppFeedback.showSnackBar(context, '工单已重新打开，我们会尽快进一步排查！');
          }
          await _loadDetail();
        }
      } catch (e) {
        if (_ownsWriteScope(auth, scope)) {
          AppFeedback.showGlobalToast('操作失败: $e', isError: true);
        }
      }
    }
  }

  Future<void> _confirmResolved() async {
    final auth = context.read<AuthProvider>();
    final scope = _captureWriteScope(auth);
    if (scope == null) return;
    try {
      final res = await auth.dio.post(
        '/feedback/tickets/${widget.ticketId}/confirm-resolved',
        options: _writeOptions(scope, idempotencyKey: RequestId.newId()),
      );
      if (!_ownsWriteScope(auth, scope)) return;
      if (res.statusCode == 200) {
        if (mounted) {
          AppFeedback.showSnackBar(context, '已确认问题解决，感谢你的反馈！');
        }
        await _loadDetail();
      }
    } catch (e) {
      if (_ownsWriteScope(auth, scope)) {
        AppFeedback.showGlobalToast('操作失败: $e', isError: true);
      }
    }
  }

  // 管理员操作面板：更新状态、请求补充信息、修改负责人与优先级
  void _showAdminActionSheet() {
    if (_ticket == null) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1E2226) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '管理员操作',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.sync_alt, color: Colors.teal),
                title: const Text('更新处理进度与状态'),
                subtitle: Text('当前状态：${_ticket!.adminStatusDisplayName}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _showUpdateStatusDialog();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.contact_support_outlined,
                    color: Colors.orange),
                title: const Text('请求用户补充信息'),
                subtitle: const Text('结构化勾选截图、复现步骤等'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRequestInfoDialog();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.indigo),
                title: const Text('设置优先级与负责人'),
                subtitle: Text('当前优先级：${_ticket!.priority}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _showUpdatePriorityDialog();
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showUpdateStatusDialog() {
    final auth = context.read<AuthProvider>();
    final scope = _captureWriteScope(auth);
    if (scope == null) return;
    String selectedStatus = _ticket!.status;
    final noteController = TextEditingController(text: _ticket!.statusNote);

    final statusOptions = [
      {'value': 'accepted', 'label': '已受理'},
      {'value': 'waiting_user', 'label': '需要用户补充'},
      {'value': 'investigating', 'label': '定位中'},
      {'value': 'fixing', 'label': '修复中'},
      {'value': 'testing', 'label': '测试中'},
      {'value': 'resolved', 'label': '已解决'},
      {'value': 'closed', 'label': '已关闭'},
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('更新处理进度'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...statusOptions.map((opt) {
                  return RadioListTile<String>(
                    dense: true,
                    value: opt['value']!,
                    groupValue: selectedStatus,
                    title: Text(opt['label']!),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedStatus = val);
                      }
                    },
                  );
                }),
                const SizedBox(height: 12),
                const Text('进度说明（如版本号或修复说明）：',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(
                    hintText: '例如：内测版 v2.8.3 或 已定位问题',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (!_ownsWriteScope(auth, scope)) return;
                try {
                  final res = await auth.dio.patch(
                    '/admin/feedback/tickets/${widget.ticketId}/status',
                    data: {
                      'status': selectedStatus,
                      'status_note': noteController.text.trim(),
                      'expected_status': _ticket!.status,
                    },
                    options:
                        _writeOptions(scope, idempotencyKey: RequestId.newId()),
                  );
                  if (!_ownsWriteScope(auth, scope)) return;
                  if (res.statusCode == 200) {
                    if (context.mounted) {
                      AppFeedback.showSnackBar(context, '状态已更新');
                    }
                    await _loadDetail();
                  }
                } catch (e) {
                  if (_ownsWriteScope(auth, scope)) {
                    AppFeedback.showSnackBar(context, '更新失败: $e',
                        isError: true);
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandPrimary,
                foregroundColor: Colors.white,
              ),
              child: const Text('确定更新'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRequestInfoDialog() {
    final auth = context.read<AuthProvider>();
    final scope = _captureWriteScope(auth);
    if (scope == null) return;
    final selectedItems = <String>{'screenshot', 'steps'};
    final commentController = TextEditingController();

    final itemOptions = [
      {'key': 'screenshot', 'label': '相关截图'},
      {'key': 'steps', 'label': '复现步骤'},
      {'key': 'time', 'label': '发生时间'},
      {'key': 'network', 'label': '网络环境 (WiFi/蜂窝)'},
      {'key': 'version', 'label': 'App版本'},
      {'key': 'other', 'label': '其他信息'},
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('请求用户补充信息'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('请勾选需要用户提供的内容：',
                    style: TextStyle(fontSize: 13, color: Colors.black54)),
                const SizedBox(height: 8),
                ...itemOptions.map((opt) {
                  final key = opt['key']!;
                  final isChecked = selectedItems.contains(key);
                  return CheckboxListTile(
                    dense: true,
                    title: Text(opt['label']!),
                    value: isChecked,
                    onChanged: (val) {
                      setDialogState(() {
                        if (val == true) {
                          selectedItems.add(key);
                        } else {
                          selectedItems.remove(key);
                        }
                      });
                    },
                  );
                }),
                const SizedBox(height: 12),
                const Text('附加说明：',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: commentController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    hintText: '请输入具体指导说明……',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (selectedItems.isEmpty) {
                  AppFeedback.showSnackBar(ctx, '请至少勾选一项', isError: true);
                  return;
                }
                Navigator.pop(ctx);
                if (!_ownsWriteScope(auth, scope)) return;
                try {
                  final res = await auth.dio.post(
                    '/admin/feedback/tickets/${widget.ticketId}/request-info',
                    data: {
                      'requested_items': selectedItems.toList(),
                      'comment': commentController.text.trim(),
                      'expected_status': _ticket!.status,
                    },
                    options:
                        _writeOptions(scope, idempotencyKey: RequestId.newId()),
                  );
                  if (!_ownsWriteScope(auth, scope)) return;
                  if (res.statusCode == 200) {
                    if (context.mounted) {
                      AppFeedback.showSnackBar(context, '已向用户发送补充信息请求');
                    }
                    await _loadDetail();
                  }
                } catch (e) {
                  if (_ownsWriteScope(auth, scope)) {
                    AppFeedback.showSnackBar(context, '操作失败: $e',
                        isError: true);
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandPrimary,
                foregroundColor: Colors.white,
              ),
              child: const Text('发起请求'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showUpdatePriorityDialog() async {
    final auth = context.read<AuthProvider>();
    final scope = _captureWriteScope(auth);
    if (scope == null) return;
    String priority = _ticket!.priority;
    int selectedAssignee = _ticket!.assigneeAdminId ?? 0;
    List<Map<String, dynamic>> assignees = [];
    try {
      final response = await auth.dio.get('/admin/feedback/assignees');
      final raw = (response.data['assignees'] as List<dynamic>?) ?? [];
      assignees = raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '读取管理员列表失败: $e', isError: true);
      }
      return;
    }
    if (!_ownsWriteScope(auth, scope)) return;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置工单优先级'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...['P0', 'P1', 'P2', 'P3'].map((p) {
                  return RadioListTile<String>(
                    dense: true,
                    value: p,
                    groupValue: priority,
                    title: Text('$p 级别'),
                    onChanged: (val) {
                      if (val != null) setDialogState(() => priority = val);
                    },
                  );
                }),
                const Divider(),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('负责人',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                RadioListTile<int>(
                  dense: true,
                  value: 0,
                  groupValue: selectedAssignee,
                  title: const Text('未分配'),
                  onChanged: (value) =>
                      setDialogState(() => selectedAssignee = value ?? 0),
                ),
                ...assignees.map((assignee) {
                  final id = (assignee['id'] as num?)?.toInt() ?? 0;
                  final name = assignee['nickname']?.toString().trim();
                  return RadioListTile<int>(
                    dense: true,
                    value: id,
                    groupValue: selectedAssignee,
                    title: Text(name?.isNotEmpty == true ? name! : '管理员 $id'),
                    onChanged: (value) =>
                        setDialogState(() => selectedAssignee = value ?? 0),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (!_ownsWriteScope(auth, scope)) return;
                try {
                  final res = await auth.dio.patch(
                    '/admin/feedback/tickets/${widget.ticketId}/assignee',
                    data: {
                      'priority': priority,
                      'assignee_admin_id': selectedAssignee,
                    },
                    options:
                        _writeOptions(scope, idempotencyKey: RequestId.newId()),
                  );
                  if (!_ownsWriteScope(auth, scope)) return;
                  if (res.statusCode == 200) {
                    await _loadDetail();
                  }
                } catch (e) {
                  if (_ownsWriteScope(auth, scope)) {
                    AppFeedback.showSnackBar(context, '保存失败: $e',
                        isError: true);
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandPrimary,
                foregroundColor: Colors.white,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // 状态与顶部进展卡片
  Widget _buildTopStatusCard(bool isDark) {
    if (_ticket == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE8EEE9),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '当前进度',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.brandPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  _ticket!.statusLabel(isAdmin: widget.isAdmin),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.brandPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_ticket!.statusNote != null && _ticket!.statusNote!.isNotEmpty)
            Text(
              _ticket!.statusNote!,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : const Color(0xFF2D3748),
                height: 1.4,
              ),
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '#${_ticket!.ticketNo}',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Colors.grey,
                ),
              ),
              Text(
                '最后更新 ${_formatDateTime(_ticket!.updatedAt)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 10),
            Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  '状态变迁记录 (${_history.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.brandPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                children: _history.map((h) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.commit, size: 14, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          _formatDateTime(h.createdAt),
                          style:
                              const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            h.note.isNotEmpty
                                ? '${h.newStatus} · ${h.note}'
                                : h.newStatus,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 原始提交内容卡片（首次描述、复现信息、附件）
  Widget _buildInitialSubmissionCard(bool isDark) {
    if (_ticket == null) return const SizedBox.shrink();
    final initial = _initialSubmission;
    final initialContent = initial?.content.isNotEmpty == true
        ? initial!.content
        : _ticket!.description;
    final initialCreatedAt = initial?.createdAt ?? _ticket!.createdAt;
    final initialAttachments = initial?.attachments.isNotEmpty == true
        ? initial!.attachments
        : _ticket!.attachments;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE8EEE9),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.brandPrimary.withValues(alpha: 0.15),
                child: Text(widget.isAdmin ? '用户' : '我',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppColors.brandPrimary,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.isAdmin ? '用户初始反馈' : '初始反馈',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  Text(
                    _formatDateTime(initialCreatedAt),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            initialContent,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
          if (_ticket!.stepsToReproduce != null &&
              _ticket!.stepsToReproduce!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : const Color(0xFFF9FBFA),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('复现步骤与现象：',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_ticket!.stepsToReproduce!,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                  if (_ticket!.actualResult != null &&
                      _ticket!.actualResult!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('实际结果：${_ticket!.actualResult}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                  if (_ticket!.expectedResult != null &&
                      _ticket!.expectedResult!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('期望结果：${_ticket!.expectedResult}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ],
              ),
            ),
          ],
          if (initialAttachments.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildAttachmentImages(initialAttachments),
          ],
        ],
      ),
    );
  }

  Widget _buildAttachmentImages(List<FeedbackAttachment> attachments) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: attachments.map((att) {
        final auth = context.read<AuthProvider>();
        final baseUrl = auth.dio.options.baseUrl.replaceAll(RegExp(r'/+$'), '');
        final imgUrl = '$baseUrl/feedback/attachments/${att.fileId}';

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImageViewerScreen(
                  httpHeaders: {
                    'Authorization': 'Bearer ${auth.token}',
                  },
                  initialIndex: 0,
                  items: [
                    ImageViewerItem(
                      url: imgUrl,
                      originalUrl: imgUrl,
                    ),
                  ],
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.network(
              imgUrl,
              headers: {
                'Authorization': 'Bearer ${auth.token}',
              },
              width: 80,
              height: 80,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 80,
                height: 80,
                color: Colors.grey[200],
                child: const Icon(Icons.broken_image,
                    size: 24, color: Colors.grey),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // 对话流气泡与专用卡片
  Widget _buildMessageItem(FeedbackMessage msg, bool isDark) {
    if (msg.isStatusChange) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        child: Text(
          '—— ${msg.content} ——',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white38 : Colors.grey[500],
          ),
        ),
      );
    }

    if (msg.isInternalNote) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB), // Amber 柔和警告底
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: const Color(0xFFFDE68A), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.lock_outline, size: 15, color: Color(0xFFB45309)),
                SizedBox(width: 6),
                Text(
                  '内部备注（仅管理员可见）',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFB45309),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              msg.content,
              style: const TextStyle(fontSize: 13, color: Color(0xFF92400E)),
            ),
            if (msg.attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildAttachmentImages(msg.attachments),
            ],
          ],
        ),
      );
    }

    if (msg.isRequestInfo) {
      List<String> items = [];
      try {
        if (msg.metadataJson != null) {
          final data = json.decode(msg.metadataJson!);
          if (data['requested_items'] is List) {
            items = List<String>.from(data['requested_items']);
          }
        }
      } catch (_) {}

      final labelMap = {
        'screenshot': '截图',
        'steps': '复现步骤',
        'time': '发生时间',
        'network': '网络环境',
        'version': 'App版本',
        'other': '其他排查信息',
      };

      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7ED), // 橙黄色轻警告底
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: const Color(0xFFFFEDD5), width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: Color(0xFFEA580C)),
                SizedBox(width: 6),
                Text(
                  '需要补充信息',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFC2410C),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              msg.content,
              style: const TextStyle(fontSize: 13, color: Color(0xFF9A3412)),
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('请尽量提供以下信息：',
                  style: TextStyle(fontSize: 12, color: Color(0xFFC2410C))),
              const SizedBox(height: 4),
              ...items.map((it) => Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Text('· ${labelMap[it] ?? it}',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFC2410C))),
                  )),
            ],
            if (!widget.isAdmin) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    FocusScope.of(context).requestFocus(_msgFocusNode);
                    if (_msgController.text.trim().isEmpty) {
                      _msgController.text = '【补充信息】：';
                    }
                    _msgController.selection = TextSelection.fromPosition(
                      TextPosition(offset: _msgController.text.length),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEA580C),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                  ),
                  child: const Text('立即补充信息'),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final isOutgoing = widget.isAdmin ? msg.isAdmin : msg.isUser;
    final senderLabel = msg.isUser ? (widget.isAdmin ? '用户' : '我') : '官方运营与研发';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment:
            isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isOutgoing) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: msg.isUser
                  ? AppColors.brandPrimary.withValues(alpha: 0.15)
                  : AppColors.brandPrimary,
              child: Text(msg.isUser ? '用户' : '官',
                  style: TextStyle(
                      fontSize: 11,
                      color: msg.isUser ? AppColors.brandPrimary : Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isOutgoing
                    ? AppColors.brandPrimary
                    : (isDark ? const Color(0xFF1E2226) : Colors.white),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: !isOutgoing
                    ? Border.all(
                        color:
                            isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                      )
                    : null,
              ),
              child: Column(
                crossAxisAlignment: isOutgoing
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isOutgoing) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          senderLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: msg.isUser
                                ? (isDark ? Colors.white70 : Colors.black54)
                                : AppColors.brandPrimary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}',
                          style:
                              TextStyle(fontSize: 10, color: Colors.grey[400]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    msg.content,
                    style: TextStyle(
                      fontSize: 14,
                      color: isOutgoing
                          ? Colors.white
                          : (isDark ? Colors.white : const Color(0xFF1F2328)),
                      height: 1.4,
                    ),
                  ),
                  if (msg.attachments.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildAttachmentImages(msg.attachments),
                  ],
                  if (isOutgoing) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isOutgoing) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: msg.isUser
                  ? AppColors.brandPrimary.withValues(alpha: 0.15)
                  : AppColors.brandPrimary,
              child: Text(msg.isUser ? '我' : '官',
                  style: TextStyle(
                      fontSize: 12,
                      color: msg.isUser ? AppColors.brandPrimary : Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }

  // 问题已解决确认卡片（仅普通用户且状态为 resolved 时展示）
  Widget _buildResolvedConfirmationCard(bool isDark) {
    if (widget.isAdmin || _ticket?.status != 'resolved') {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(0xFFBBF7D0), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.check_circle_outline,
                  color: Color(0xFF16A34A), size: 20),
              SizedBox(width: 8),
              Text(
                '问题已解决',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF15803D),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _ticket?.statusNote ?? '已完成修复并发布验证版本。请问你的问题是否已经解决？',
            style: const TextStyle(fontSize: 13, color: Color(0xFF166534)),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _reopenTicket,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                    side: const BorderSide(color: Color(0xFFFCA5A5)),
                  ),
                  child: const Text('仍有问题'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _confirmResolved,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    elevation: 0,
                  ),
                  child: const Text('确认解决'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 底部回复栏
  Widget _buildBottomComposer(bool isDark) {
    final isClosed = _ticket?.status == 'closed';
    if (isClosed && !widget.isAdmin) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '工单已解决归档',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            TextButton(
              onPressed: _reopenTicket,
              child: const Text('仍有问题？重新打开'),
            ),
          ],
        ),
      );
    }
    if (isClosed && widget.isAdmin && !_adminInternalNote) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '工单已关闭，公开回复已禁用；仍可添加内部备注',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _adminInternalNote = true),
              child: const Text('添加备注'),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white12 : const Color(0xFFE8EEE9),
            width: 0.8,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isAdmin)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('回复用户'),
                    selected: !_adminInternalNote,
                    onSelected: _sending
                        ? null
                        : (val) => setState(() => _adminInternalNote = !val),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline, size: 14),
                        SizedBox(width: 4),
                        Text('内部备注 (用户不可见)'),
                      ],
                    ),
                    selected: _adminInternalNote,
                    selectedColor: const Color(0xFFFDE68A),
                    onSelected: _sending
                        ? null
                        : (val) => setState(() => _adminInternalNote = val),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                color: AppColors.brandPrimary,
                onPressed: _sending ? null : _pickAndUploadImage,
              ),
              Expanded(
                child: TextField(
                  controller: _msgController,
                  focusNode: _msgFocusNode,
                  readOnly: _sending,
                  maxLines: 4,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: _adminInternalNote
                        ? '添加仅管理员可见的排查备注……'
                        : (widget.isAdmin ? '回复用户……' : '继续回复或补充信息……'),
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white38 : Colors.grey[400],
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : const Color(0xFFF8FAF9),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(
                        color:
                            isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(
                        color:
                            isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.white,
                ),
                onPressed: _sending ? null : () => _sendMessage(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateSeparator(DateTime value) {
    final dt = value.toLocal();
    final label =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Expanded(child: Divider(indent: 40, endIndent: 10)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const Expanded(child: Divider(indent: 10, endIndent: 40)),
        ],
      ),
    );
  }

  List<Widget> _buildMessageTimeline(bool isDark) {
    final children = <Widget>[];
    String? lastDay;
    for (final message in _messages) {
      final dt = message.createdAt.toLocal();
      final day = '${dt.year}-${dt.month}-${dt.day}';
      if (day != lastDay) {
        children.add(_buildDateSeparator(message.createdAt));
        lastDay = day;
      }
      children.add(_buildMessageItem(message, isDark));
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = themeProvider.isCleanBackgroundMode && !isDark
        ? const Color(0xFFFFFAF4)
        : Theme.of(context).colorScheme.surface;

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        title: Text(
          widget.isAdmin ? '工单处理详情' : '工单详情',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: pageBg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (widget.isAdmin)
            TextButton.icon(
              onPressed: _showAdminActionSheet,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('管理操作'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.brandPrimary,
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _loadDetail,
                        child: const Text('重新加载'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () => _loadDetail(showLoading: false),
                        child: ListView(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                          padding: const EdgeInsets.only(bottom: 16),
                          children: [
                            _buildTopStatusCard(isDark),
                            _buildInitialSubmissionCard(isDark),
                            ..._buildMessageTimeline(isDark),
                            _buildResolvedConfirmationCard(isDark),
                          ],
                        ),
                      ),
                    ),
                    _buildBottomComposer(isDark),
                  ],
                ),
    );
  }
}
