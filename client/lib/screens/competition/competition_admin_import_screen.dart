// ignore_for_file: prefer_const_constructors

import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../widgets/competition/competition_status_helper.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

const _competitionCategorySlugHint =
    'innovation_startup、computer_ai、electronic_info、smart_manufacturing_vehicle、art_design、business_economics、math_science、materials_chem_env、language_humanities、defense_security_other';
const _competitionAiPrompt = '''
你是校园竞赛信息整理助手。请把我提供的比赛通知整理成校园 App 可导入的 JSON。

只允许输出 JSON，不要输出 Markdown，不要解释，不要使用 ``` 包裹。

重要规则：
1. 不要编造精确日期。
2. 能确定到日，才填写 YYYY-MM-DD。
3. 只能确定月份，就填写 sort_month，并把日期字段留空。
4. 根据往年经验判断，time_status 填 historical。
5. 官方通知已经明确日期，time_status 填 confirmed。
6. 只是预计时间，time_status 填 estimated。
7. 完全不知道时间，time_status 填 pending。
8. time_note 必须说明时间来源。
9. 学校认定不确定时，school_recognition_status 用 pending 或 unknown，禁止编造 recognized。

固定格式如下：
{
  "events": [
    {
      "title": "比赛名称",
      "summary": "一句话摘要，80字以内",
      "description": "比赛说明，可包含报名方式、参赛对象、赛程等",
      "primary_category_slug": "分类slug，必须使用系统已有分类：$_competitionCategorySlugHint",
      "tags": ["数学建模", "创新创业"],
      "competition_level": "国家级/省级/校级/企业赛/平台赛/其他",
      "school_recognition_status": "recognized/not_recognized/pending/unknown",
      "school_recognition_grade": "",
      "recommendation_level": "S/A/B+/B/B-/C/D/E",
      "importance_score": 80,
      "recommendation_reason": "推荐理由，60字以内",
      "organizer": "主办方",
      "host_unit": "承办/指导单位，没有就空字符串",
      "target_audience": "参赛对象",
      "eligible_entry_years": ["2023", "2024"],
      "eligible_colleges": ["信息科学与工程学院"],
      "eligible_majors": ["计算机科学与技术"],
      "participation_type": "个人/团队/个人或团队",
      "team_size_min": 1,
      "team_size_max": 5,
      "registration_start": "YYYY-MM-DD，不确定填空字符串",
      "registration_end": "YYYY-MM-DD，不确定填空字符串",
      "event_start": "YYYY-MM-DD，不确定填空字符串",
      "event_end": "YYYY-MM-DD，不确定填空字符串",
      "registration_time_text": "原文报名时间描述",
      "event_time_text": "原文比赛时间描述",
      "time_precision": "exact/month/month_range/quarter/half_year/season/unknown",
      "time_status": "confirmed/estimated/historical/pending",
      "time_note": "说明时间来源，例如官方通知、往年参考、等待学校通知",
      "sort_month": 0,
      "location": "地点，没有填空字符串",
      "is_online": false,
      "official_url": "官网链接，没有填空字符串",
      "notice_url": "通知链接，没有填空字符串",
      "attachment_urls": [],
      "source_channel": "school_catalog/college_notice/enterprise/industry_association/platform/admin_manual/ai_import",
      "source_note": "来源说明",
      "status": "draft"
    }
  ]
}

规则：
1. 日期字段必须是 YYYY-MM-DD，不能确定就留空字符串。
2. URL 必须是 http 或 https，不确定就留空字符串。
3. recommendation_level 只能是 S/A/B+/B/B-/C/D/E。
4. school_recognition_status 只能是 recognized/not_recognized/pending/unknown。
5. source_channel 优先用 college_notice、school_catalog、enterprise、platform。
6. primary_category_slug 必须使用系统已有分类：$_competitionCategorySlugHint。
7. time_precision 只能用 exact/month/month_range/quarter/half_year/season/unknown。
8. time_status 只能用 confirmed/estimated/historical/pending。
''';

const _competitionAiExampleJson = '''
{
  "events": [
    {
      "title": "蓝桥杯全国软件和信息技术专业人才大赛",
      "summary": "面向程序设计、电子、视觉艺术等方向的综合竞赛。",
      "description": "适合有编程、电子或设计基础的学生参加。",
      "primary_category_slug": "computer_ai",
      "tags": ["算法", "个人赛", "程序设计"],
      "competition_level": "国家级",
      "school_recognition_status": "pending",
      "school_recognition_grade": "",
      "recommendation_level": "A",
      "importance_score": 85,
      "recommendation_reason": "个人能力占比较高，高等级奖项仍需要长期训练。",
      "organizer": "相关主办单位",
      "host_unit": "",
      "target_audience": "在校大学生",
      "eligible_entry_years": [],
      "eligible_colleges": [],
      "eligible_majors": [],
      "participation_type": "个人",
      "team_size_min": 1,
      "team_size_max": 1,
      "registration_start": "",
      "registration_end": "",
      "event_start": "",
      "event_end": "",
      "registration_time_text": "往年一般在每年秋季至次年初报名，具体以当年通知为准",
      "event_time_text": "省赛一般在春季，国赛时间以官方通知为准",
      "time_precision": "month_range",
      "time_status": "historical",
      "time_note": "未找到今年正式通知，时间根据往年公开信息整理",
      "sort_month": 10,
      "location": "",
      "is_online": false,
      "official_url": "",
      "notice_url": "",
      "attachment_urls": [],
      "source_channel": "ai_import",
      "source_note": "AI 根据公开资料整理，需管理员确认",
      "status": "draft"
    }
  ]
}
''';

class CompetitionAdminImportScreen extends StatefulWidget {
  const CompetitionAdminImportScreen({super.key});

  @override
  State<CompetitionAdminImportScreen> createState() =>
      _CompetitionAdminImportScreenState();
}

class _CompetitionAdminImportScreenState
    extends State<CompetitionAdminImportScreen> {
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _competitionBg => CompetitionUiTokens.pageBg(_isDark);
  Color get _competitionPrimary => CompetitionUiTokens.accent(_isDark);
  Color get _competitionPrimaryDark => CompetitionUiTokens.accent(_isDark);
  Color get _competitionLight => CompetitionUiTokens.accentSoft(_isDark);
  Color get _competitionBorder => CompetitionUiTokens.borderColor(_isDark);
  Color get _competitionMuted => CompetitionUiTokens.subColor(_isDark);
  Color get _competitionOrange => CompetitionUiTokens.warningColor(_isDark);
  Color get _competitionDanger => CompetitionUiTokens.dangerColor(_isDark);
  Color get _titleColor => CompetitionUiTokens.titleColor(_isDark);
  Color get _cardBg => CompetitionUiTokens.cardBg(_isDark);

  final _jsonController = TextEditingController();
  String? _batchId;
  Map<String, dynamic>? _preview;
  String? _previewedJsonText;
  String? _jsonFileName;
  Map<String, dynamic>? _fileJsonPayload;
  bool _readingJsonFile = false;
  bool _showAllPreviewEvents = false;
  String _previewFilter = 'all';

  @override
  void initState() {
    super.initState();
    _jsonController.addListener(_handleJsonChanged);
  }

  @override
  void dispose() {
    _jsonController.removeListener(_handleJsonChanged);
    _jsonController.dispose();
    super.dispose();
  }

  void _handleJsonChanged() {
    if (_preview == null && _batchId == null && _previewedJsonText == null) {
      return;
    }
    if (_jsonController.text == _previewedJsonText) {
      return;
    }
    setState(() {
      _preview = null;
      _batchId = null;
      _previewedJsonText = null;
      _showAllPreviewEvents = false;
      _previewFilter = 'all';
    });
  }

  Future<void> _pickJsonFile() async {
    try {
      setState(() => _readingJsonFile = true);

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
        withReadStream: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;

      String? text;
      if (file.bytes != null) {
        text = utf8.decode(file.bytes!).trim();
      } else if (file.readStream != null) {
        text = await file.readStream!.transform(utf8.decoder).join();
        text = text.trim();
      }

      if (text == null || text.isEmpty) {
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          '读取文件失败，请重新选择 JSON 文件',
          isError: true,
        );
        return;
      }

      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic> || decoded['events'] is! List) {
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }

      if (!mounted) return;
      final resp = await context
          .read<AuthProvider>()
          .dio
          .post('/admin/competitions/import-json/preview', data: decoded);

      if (!mounted) return;

      setState(() {
        _jsonFileName = file.name;
        _fileJsonPayload = decoded;
        _jsonController.clear();
        _batchId = resp.data['batch_id'];
        _preview = Map<String, dynamic>.from(resp.data['preview']);
        _previewedJsonText = null;
        _showAllPreviewEvents = false;
        _previewFilter = 'all';
      });

      AppFeedback.showSnackBar(context, '已读取并预览 ${file.name}');
    } on FormatException {
      AppFeedback.showSnackBar(
        context,
        'JSON 格式不正确，请检查逗号、引号和括号',
        isError: true,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '文件预览失败'),
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        '读取 JSON 文件失败：$e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _readingJsonFile = false);
      }
    }
  }

  List<Map<String, dynamic>> get _draftEvents {
    final normalizedItems = _preview?['items'];
    if (normalizedItems is List) {
      return normalizedItems
          .asMap()
          .entries
          .where((entry) => entry.value is Map)
          .map(
        (entry) {
          return Map<String, dynamic>.from(entry.value as Map)
            ..['__preview_index'] = entry.key;
        },
      ).toList();
    }
    if (_fileJsonPayload != null) {
      final events = _fileJsonPayload!['events'];
      if (events is! List) return [];
      return events.asMap().entries.where((entry) => entry.value is Map).map(
        (entry) {
          return Map<String, dynamic>.from(entry.value as Map)
            ..['__preview_index'] = entry.key;
        },
      ).toList();
    }
    try {
      final data = jsonDecode(_jsonController.text);
      if (data is! Map<String, dynamic>) return [];
      final events = data['events'];
      if (events is! List) return [];
      return events.asMap().entries.where((entry) => entry.value is Map).map(
        (entry) {
          return Map<String, dynamic>.from(entry.value as Map)
            ..['__preview_index'] = entry.key;
        },
      ).toList();
    } catch (_) {
      return [];
    }
  }

  List<Map<String, dynamic>> get _sortedDraftEvents {
    final indexed = _draftEvents.asMap().entries.toList();
    indexed.sort((left, right) {
      final leftDate = _draftSortDate(left.value);
      final rightDate = _draftSortDate(right.value);
      if (leftDate != null && rightDate != null) {
        final compared = leftDate.compareTo(rightDate);
        if (compared != 0) return compared;
      } else if (leftDate != null) {
        return -1;
      } else if (rightDate != null) {
        return 1;
      }
      return left.key.compareTo(right.key);
    });
    return indexed.map((entry) => entry.value).toList();
  }

  List<Map<String, dynamic>> get _filteredDraftEvents {
    return _sortedDraftEvents.where((event) {
      switch (_previewFilter) {
        case 'missing_date':
          return !_draftHasExactDate(event);
        case 'pending':
          return _draftValue(event, 'time_status').isEmpty ||
              _draftValue(event, 'time_status') == 'pending';
        case 'confirmed':
          return _draftValue(event, 'time_status') == 'confirmed';
        case 'warning':
          return _draftEventHasWarning(event);
        case 'missing_url':
          return _draftMissingOfficialUrl(event);
        case 'category_invalid':
          return _draftCategoryInvalid(event);
        case 'recommendation_invalid':
          return _draftRecommendationInvalid(event);
        default:
          return true;
      }
    }).toList();
  }

  List<Map<String, dynamic>> get _visibleDraftEvents {
    final filtered = _filteredDraftEvents;
    if (_showAllPreviewEvents) return filtered;
    return filtered.take(10).toList();
  }

  bool get _canCommitPreview {
    final errors = (_preview?['errors'] as List?) ?? [];
    return _batchId != null && _preview != null && errors.isEmpty;
  }

  Future<void> _previewJson() async {
    try {
      final decoded = jsonDecode(_jsonController.text);
      if (decoded is! Map<String, dynamic>) {
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }
      if (!mounted) return;
      final resp = await context
          .read<AuthProvider>()
          .dio
          .post('/admin/competitions/import-json/preview', data: decoded);
      if (!mounted) return;
      setState(() {
        _batchId = resp.data['batch_id'];
        _preview = Map<String, dynamic>.from(resp.data['preview']);
        _previewedJsonText = _jsonController.text;
        _showAllPreviewEvents = false;
        _previewFilter = 'all';
      });
    } on FormatException {
      AppFeedback.showSnackBar(
        context,
        'JSON 格式不正确，请检查逗号、引号和括号',
        isError: true,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '提交预览失败'),
        isError: true,
      );
    } catch (_) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        '提交预览失败，请检查 JSON 格式',
        isError: true,
      );
    }
  }

  Future<void> _commit() async {
    final count = (_preview?['item_count'] as num?)?.toInt() ?? 0;
    try {
      await context.read<AuthProvider>().dio.post(
        '/admin/competitions/import-json/commit',
        data: {
          'batch_id': _batchId,
          'selected_actions': [
            for (var i = 0; i < count; i++) {'index': i, 'action': 'create'}
          ],
        },
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已导入到官方比赛库草稿，确认无误后可发布给所有用户');
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '确认入库失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text('AI辅助导入比赛'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          _buildPromptCard(),
          SizedBox(height: 12),
          _buildJsonFileImportCard(),
          SizedBox(height: 12),
          if (_jsonFileName == null) ...[
            TextField(
              controller: _jsonController,
              minLines: 8,
              maxLines: 16,
              decoration: InputDecoration(
                labelText: '或粘贴 AI 结果',
                hintText: '可以粘贴，也可以从上方选择 .json 文件',
                filled: true,
                fillColor: _cardBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: _competitionBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: _competitionBorder),
                ),
                alignLabelWithHint: true,
              ),
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      _jsonController.text = _competitionAiExampleJson;
                      AppFeedback.showSnackBar(context, '已填入示例 JSON');
                    },
                    icon: Icon(Icons.data_object_rounded, size: 18),
                    label: Text('填入示例'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _competitionPrimary,
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _previewJson,
                    icon: Icon(Icons.fact_check_outlined, size: 18),
                    label: Text('检查预览'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _competitionPrimary,
                      foregroundColor: _cardBg,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _jsonFileName = null;
                    _fileJsonPayload = null;
                    _preview = null;
                    _batchId = null;
                    _showAllPreviewEvents = false;
                    _previewFilter = 'all';
                  });
                },
                icon: Icon(Icons.close_rounded, size: 18),
                label: Text('清除文件，改为手动粘贴'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _competitionPrimary,
                ),
              ),
            ),
          ],
          if (_preview != null) ...[
            SizedBox(height: 16),
            _buildPreviewCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildJsonFileImportCard() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '第 2 步：导入数据',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: _titleColor,
            ),
          ),
          SizedBox(height: 6),
          Text(
            _jsonFileName == null
                ? '选择 JSON 文件，或在下方直接粘贴 AI 结果。'
                : '当前文件：$_jsonFileName',
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _readingJsonFile ? null : _pickJsonFile,
            icon: Icon(Icons.upload_file_rounded, size: 18),
            label: Text(_readingJsonFile ? '读取中...' : '选择 JSON 文件'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _competitionPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptCard() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _competitionLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: _competitionPrimary,
                  size: 19,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '第 1 步 让 AI 帮你整理比赛',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: _titleColor,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            '生成标准 JSON 后先检查预览，不会直接写入正式比赛库。',
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '',
            style: TextStyle(
              color: _competitionPrimaryDark,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '',
            style: TextStyle(
              color: _competitionOrange,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '',
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _competitionAiPrompt),
                    );
                    if (!mounted) return;
                    AppFeedback.showSnackBar(context, '已复制 AI 导入提示词');
                  },
                  icon: Icon(Icons.copy_rounded, size: 17),
                  label: Text('复制提示词'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _competitionPrimary,
                    foregroundColor: _cardBg,
                  ),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _competitionAiExampleJson),
                    );
                    if (!mounted) return;
                    AppFeedback.showSnackBar(context, '已复制示例 JSON');
                  },
                  icon: Icon(Icons.content_paste_rounded, size: 17),
                  label: Text('复制示例'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _competitionPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    final errors = (_preview?['errors'] as List?) ?? [];
    final warnings = (_preview?['warnings'] as List?) ?? [];
    final draftEvents = _sortedDraftEvents;
    final filteredEvents = _filteredDraftEvents;
    final visibleEvents = _visibleDraftEvents;
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '第 3 步：预览校验',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: _titleColor,
            ),
          ),
          SizedBox(height: 10),
          _buildValidationMetrics(draftEvents, errors, warnings),
          SizedBox(height: 12),
          _buildImportConclusionCard(draftEvents, errors, warnings),
          if (draftEvents.isNotEmpty) ...[
            SizedBox(height: 12),
            _buildIssueOverview(draftEvents),
          ],
          if (errors.isNotEmpty) ...[
            SizedBox(height: 12),
            ...errors.map(
              (error) => Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  _previewErrorText(error),
                  style: TextStyle(
                    color: _competitionDanger,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (warnings.isNotEmpty) ...[
            SizedBox(height: 12),
            ...warnings.map(
              (warning) => Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  _previewErrorText(warning),
                  style: TextStyle(
                    color: _competitionOrange,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (draftEvents.isNotEmpty) ...[
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '计划预览',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: _titleColor,
                    ),
                  ),
                ),
                Text(
                  '显示 ${visibleEvents.length} / ${filteredEvents.length}',
                  style: TextStyle(
                    color: _competitionMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            _buildPreviewFilters(draftEvents),
            SizedBox(height: 10),
            ...visibleEvents.map(_buildDraftEventCompactCard),
            if (!_showAllPreviewEvents && filteredEvents.length > 10) ...[
              SizedBox(height: 2),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _showAllPreviewEvents = true;
                  }),
                  icon: Icon(Icons.unfold_more_rounded, size: 18),
                  label: Text('展开全部 ${filteredEvents.length} 条'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _competitionPrimary,
                  ),
                ),
              ),
            ],
          ],
          SizedBox(height: 14),
          FilledButton(
            onPressed: _canCommitPreview ? _commit : null,
            style: FilledButton.styleFrom(
              minimumSize: Size.fromHeight(46),
              backgroundColor: _competitionPrimary,
              foregroundColor: _cardBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: Text('导入为官方草稿'),
          ),
        ],
      ),
    );
  }

  Widget _buildImportConclusionCard(
    List<Map<String, dynamic>> events,
    List<dynamic> errors,
    List<dynamic> warnings,
  ) {
    final missingRegistration = _countWhere(
      events,
      (event) => _draftValue(event, 'registration_end').isEmpty,
    );
    final missingEvent = _countWhere(
      events,
      (event) => _draftValue(event, 'event_start').isEmpty,
    );
    final title = errors.isNotEmpty
        ? '存在错误，修正后再导入'
        : warnings.isNotEmpty
            ? '可导入，但需要关注警告'
            : missingRegistration > 0 || missingEvent > 0
                ? '可导入，但需要后续补日期'
                : '可导入为草稿';
    final icon = errors.isNotEmpty
        ? Icons.error_outline_rounded
        : warnings.isNotEmpty
            ? Icons.warning_amber_rounded
            : Icons.check_circle_outline_rounded;
    final color = errors.isNotEmpty
        ? _competitionDanger
        : warnings.isNotEmpty
            ? _competitionOrange
            : _competitionPrimary;
    final validCount = (_preview?['valid_count'] as num?)?.toInt() ?? 0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  '$validCount 条有效，${errors.length} 条错误，${warnings.length} 条警告。'
                  '这些比赛会先进入草稿库，不会直接发布给普通用户。',
                  style: TextStyle(
                    color: _titleColor,
                    fontSize: 12,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _commitSingle(int index) async {
    try {
      await context.read<AuthProvider>().dio.post(
        '/admin/competitions/import-json/commit',
        data: {
          'batch_id': _batchId,
          'selected_actions': [
            {'index': index, 'action': 'create'}
          ],
        },
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已保存为官方草稿');
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '保存草稿失败'),
        isError: true,
      );
    }
  }

  Widget _buildValidationMetrics(
    List<Map<String, dynamic>> events,
    List<dynamic> errors,
    List<dynamic> warnings,
  ) {
    final missingTime =
        _countWhere(events, (event) => !_draftHasAnyTime(event));
    final missingUrl = _countWhere(events, _draftMissingOfficialUrl);
    final categoryInvalid = _countWhere(events, _draftCategoryInvalid);
    final recommendationInvalid =
        _countWhere(events, _draftRecommendationInvalid);
    final validCount = (_preview?['valid_count'] as num?)?.toInt() ?? 0;
    final total = (_preview?['item_count'] as num?)?.toInt() ?? events.length;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _metricPill('总数', '$total', _competitionPrimary),
        _metricPill('可保存', '$validCount', _competitionPrimary),
        _metricPill('缺时间', '$missingTime', _competitionOrange),
        _metricPill('缺官网', '$missingUrl', _competitionOrange),
        _metricPill('分类异常', '$categoryInvalid', _competitionDanger),
        _metricPill('推荐等级异常', '$recommendationInvalid', _competitionDanger),
        if (errors.isNotEmpty)
          _metricPill('错误', '${errors.length}', _competitionDanger),
        if (warnings.isNotEmpty)
          _metricPill('警告', '${warnings.length}', _competitionOrange),
      ],
    );
  }

  Widget _metricPill(String label, String value, Color color) {
    return Container(
      width: 96,
      padding: EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIssueOverview(List<Map<String, dynamic>> events) {
    final missingTime =
        _countWhere(events, (event) => !_draftHasAnyTime(event));
    final missingUrl = _countWhere(events, _draftMissingOfficialUrl);
    final categoryInvalid = _countWhere(events, _draftCategoryInvalid);
    final recommendationInvalid =
        _countWhere(events, _draftRecommendationInvalid);
    final pending = _countWhere(
      events,
      (event) =>
          _draftValue(event, 'time_status').isEmpty ||
          _draftValue(event, 'time_status') == 'pending',
    );
    final confirmed = _countWhere(
      events,
      (event) => _draftValue(event, 'time_status') == 'confirmed',
    );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _issuePill('缺时间', missingTime),
        _issuePill('缺官网', missingUrl),
        _issuePill('分类异常', categoryInvalid),
        _issuePill('推荐异常', recommendationInvalid),
        _issuePill('时间待公布', pending),
        _issuePill('已确认', confirmed),
      ],
    );
  }

  Widget _issuePill(String label, int count) {
    final active = count > 0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? _competitionOrange.withValues(alpha: 0.1)
            : _competitionLight.withValues(alpha: 0.54),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active
              ? _competitionOrange.withValues(alpha: 0.2)
              : _competitionBorder,
        ),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          color: active ? _competitionOrange : _competitionPrimaryDark,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildPreviewFilters(List<Map<String, dynamic>> events) {
    final filters = [
      ('all', '全部', events.length),
      ('missing_date', '缺时间', _countWhere(events, (e) => !_draftHasAnyTime(e))),
      ('missing_url', '缺官网', _countWhere(events, _draftMissingOfficialUrl)),
      ('category_invalid', '分类异常', _countWhere(events, _draftCategoryInvalid)),
      (
        'recommendation_invalid',
        '推荐异常',
        _countWhere(events, _draftRecommendationInvalid)
      ),
      (
        'pending',
        '时间待公布',
        _countWhere(
          events,
          (e) =>
              _draftValue(e, 'time_status').isEmpty ||
              _draftValue(e, 'time_status') == 'pending',
        ),
      ),
      (
        'confirmed',
        '已确认',
        _countWhere(
            events, (e) => _draftValue(e, 'time_status') == 'confirmed'),
      ),
      ('warning', '有警告', _countWhere(events, _draftEventHasWarning)),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final filter in filters) ...[
            ChoiceChip(
              label: Text('${filter.$2} ${filter.$3}'),
              selected: _previewFilter == filter.$1,
              onSelected: (_) => setState(() {
                _previewFilter = filter.$1;
                _showAllPreviewEvents = false;
              }),
              labelStyle: TextStyle(
                color: _previewFilter == filter.$1
                    ? _cardBg
                    : _competitionPrimaryDark,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
              selectedColor: _competitionPrimary,
              backgroundColor: _competitionLight.withValues(alpha: 0.52),
              side: BorderSide(
                color: _previewFilter == filter.$1
                    ? _competitionPrimary
                    : _competitionBorder,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildDraftEventCompactCard(Map<String, dynamic> event) {
    final title = _draftValue(event, 'title');
    final category = _draftValue(event, 'primary_category_slug');
    final recommendation = _draftValue(event, 'recommendation_level');
    final recognition = competitionRecognitionLabel(
      _draftValue(event, 'school_recognition_status'),
    );
    final organizer = _draftValue(event, 'organizer');
    final source = _sourceLabel(_draftValue(event, 'source_channel'));
    final timeStatus = _timeStatusLabel(_draftValue(event, 'time_status'));
    final timeNote = _draftValue(event, 'time_note');
    final sortMonth = _draftValue(event, 'sort_month');
    final entryYears = _draftStringList(event, 'eligible_entry_years');
    final colleges = _draftStringList(event, 'eligible_colleges');
    final majors = _draftStringList(event, 'eligible_majors');
    final hasExactDate = _draftHasExactDate(event);
    final timeSummary = _draftTimeSummary(event);
    final problems = _draftProblems(event);
    final previewIndex =
        int.tryParse(_draftValue(event, '__preview_index')) ?? 0;
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _competitionBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _competitionBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.fromLTRB(14, 4, 10, 4),
          childrenPadding: EdgeInsets.fromLTRB(14, 0, 14, 14),
          iconColor: _competitionPrimaryDark,
          collapsedIconColor: _competitionMuted,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.isEmpty ? '未命名比赛' : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: _titleColor,
                  height: 1.25,
                ),
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: _competitionMuted,
                  ),
                  SizedBox(width: 5),
                  Text(
                    '时间：',
                    style: TextStyle(
                      color: _competitionMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      timeSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _titleColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 9),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (category.isNotEmpty) _draftChip('分类 $category'),
                  if (recommendation.isNotEmpty)
                    _draftChip('$recommendation 推荐'),
                  _draftChip(recognition),
                  _draftChip(source),
                  if (entryYears.isNotEmpty)
                    _draftChip('入学年份 ${entryYears.join('/')}'),
                  if (majors.isNotEmpty) _draftChip('专业 ${majors.join('/')}'),
                  if (majors.isEmpty && colleges.isNotEmpty)
                    _draftChip('学院 ${colleges.join('/')}'),
                  if (entryYears.isEmpty && colleges.isEmpty && majors.isEmpty)
                    _draftChip('通用适配'),
                ],
              ),
            ],
          ),
          children: [
            if (problems.isNotEmpty) ...[
              Container(
                width: double.infinity,
                margin: EdgeInsets.only(bottom: 8),
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _competitionOrange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _competitionOrange.withValues(alpha: 0.18),
                  ),
                ),
                child: Text(
                  '问题：${problems.join('、')}',
                  style: TextStyle(
                    color: _competitionOrange,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
            _draftLine(
              Icons.alarm_rounded,
              '报名截止',
              _draftTimeText(
                event,
                'registration_end',
                'registration_time_text',
              ),
            ),
            _draftLine(
              Icons.calendar_month_rounded,
              '比赛时间',
              _draftTimeText(event, 'event_start', 'event_time_text'),
            ),
            _draftLine(Icons.verified_outlined, '时间状态', timeStatus),
            _draftLine(
              Icons.event_note_rounded,
              '预计月份',
              sortMonth.isEmpty || sortMonth == '0' ? '未填写' : '$sortMonth 月',
            ),
            _draftLine(
              Icons.rule_rounded,
              '日期精度',
              hasExactDate ? '包含精确日期' : '未填写精确日期',
            ),
            if (timeNote.isNotEmpty)
              _draftLine(Icons.notes_rounded, '时间说明', timeNote),
            if (organizer.isNotEmpty)
              _draftLine(Icons.account_balance_outlined, '主办方', organizer),
            SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => AppFeedback.showSnackBar(
                      context,
                      '请在上方 JSON 中修改该条目后重新检查预览',
                    ),
                    icon: Icon(Icons.edit_outlined, size: 17),
                    label: Text('编辑'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: _competitionPrimary,
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _canCommitPreview
                        ? () => _commitSingle(previewIndex)
                        : null,
                    icon: Icon(Icons.save_outlined, size: 17),
                    label: Text('保存为草稿'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: _competitionPrimary,
                      foregroundColor: _cardBg,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _draftLine(IconData icon, String label, String value) {
    final text = value.trim().isEmpty ? '未填写' : value.trim();
    return Padding(
      padding: EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: _competitionMuted),
          SizedBox(width: 5),
          Text(
            '$label：',
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _titleColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _draftChip(String label) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _competitionLight.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _competitionPrimaryDark,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  int _countWhere(
    List<Map<String, dynamic>> events,
    bool Function(Map<String, dynamic>) test,
  ) {
    return events.where(test).length;
  }

  bool _draftHasExactDate(Map<String, dynamic> event) {
    return _draftValue(event, 'registration_end').isNotEmpty ||
        _draftValue(event, 'event_start').isNotEmpty;
  }

  bool _draftHasAnyTime(Map<String, dynamic> event) {
    return _draftValue(event, 'registration_start').isNotEmpty ||
        _draftValue(event, 'registration_end').isNotEmpty ||
        _draftValue(event, 'event_start').isNotEmpty ||
        _draftValue(event, 'event_end').isNotEmpty ||
        _draftValue(event, 'registration_time_text').isNotEmpty ||
        _draftValue(event, 'event_time_text').isNotEmpty ||
        _draftValue(event, 'sort_month').isNotEmpty;
  }

  bool _draftMissingOfficialUrl(Map<String, dynamic> event) {
    return _draftValue(event, 'official_url').isEmpty &&
        _draftValue(event, 'notice_url').isEmpty;
  }

  bool _draftCategoryInvalid(Map<String, dynamic> event) {
    final slug = _draftValue(event, 'primary_category_slug');
    if (slug.isEmpty) return true;
    return !_competitionCategorySlugHint.split('、').contains(slug);
  }

  bool _draftRecommendationInvalid(Map<String, dynamic> event) {
    const levels = {'S', 'A', 'B+', 'B', 'B-', 'C'};
    return !levels.contains(_draftValue(event, 'recommendation_level'));
  }

  List<String> _draftProblems(Map<String, dynamic> event) {
    final problems = <String>[];
    if (!_draftHasAnyTime(event)) problems.add('缺时间');
    if (_draftMissingOfficialUrl(event)) problems.add('缺通知链接');
    if (_draftCategoryInvalid(event)) problems.add('分类异常');
    if (_draftRecommendationInvalid(event)) problems.add('推荐等级异常');
    return problems;
  }

  bool _draftEventHasWarning(Map<String, dynamic> event) {
    final hasAnyTime = _draftHasAnyTime(event);
    if (!hasAnyTime && _draftValue(event, 'time_note').isEmpty) {
      return true;
    }
    return _draftValue(event, 'school_recognition_status') == 'recognized' &&
        _draftValue(event, 'source_note').isEmpty;
  }

  String _draftTimeSummary(Map<String, dynamic> event) {
    final status = _timeStatusLabel(_draftValue(event, 'time_status'));
    final registrationEnd = _draftValue(event, 'registration_end');
    if (registrationEnd.isNotEmpty) return '报名截止 $registrationEnd';

    final eventStart = _draftValue(event, 'event_start');
    if (eventStart.isNotEmpty) return '比赛开始 $eventStart';

    final registrationText = _draftValue(event, 'registration_time_text');
    if (registrationText.isNotEmpty) return '$status · $registrationText';

    final eventText = _draftValue(event, 'event_time_text');
    if (eventText.isNotEmpty) return '$status · $eventText';

    final sortMonth = int.tryParse(_draftValue(event, 'sort_month'));
    if (sortMonth != null && sortMonth >= 1 && sortMonth <= 12) {
      return '$status · 预计 $sortMonth 月';
    }
    return status;
  }

  DateTime? _draftSortDate(Map<String, dynamic> event) {
    return _parseDraftDate(_draftValue(event, 'registration_end')) ??
        _parseDraftDate(_draftValue(event, 'event_start'));
  }

  DateTime? _parseDraftDate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  String _draftTimeText(
    Map<String, dynamic> event,
    String dateKey,
    String textKey,
  ) {
    final date = _draftValue(event, dateKey);
    if (date.isNotEmpty) return date;
    return _draftValue(event, textKey);
  }

  String _draftValue(Map<String, dynamic> event, String key) {
    return '${event[key] ?? ''}'.trim();
  }

  List<String> _draftStringList(Map<String, dynamic> event, String key) {
    final value = event[key];
    if (value is! List) return [];
    return value
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  String _previewErrorText(dynamic error) {
    if (error is Map) {
      final index = error['index'];
      final field = error['field'];
      final message = error['message'];
      final prefix = index == null || '$index' == '-1' ? '全局' : '第 $index 条';
      return '$prefix：$field - $message';
    }
    return '$error';
  }
}

String _timeStatusLabel(String value) {
  switch (value) {
    case 'confirmed':
      return '已确认';
    case 'estimated':
      return '预计时间';
    case 'historical':
      return '往年参考';
    case 'pending':
      return '时间待公布';
    default:
      return value.isEmpty ? '时间待公布' : value;
  }
}

String _sourceLabel(String value) {
  switch (value) {
    case 'school_catalog':
      return '学校目录';
    case 'college_notice':
      return '学院通知';
    case 'enterprise':
      return '企业赛';
    case 'industry_association':
      return '行业协会';
    case 'platform':
      return '竞赛平台';
    case 'admin_manual':
      return '管理员录入';
    case 'ai_import':
      return 'AI 导入';
    default:
      return value.isEmpty ? '未知来源' : value;
  }
}
