import re
import os

def extract_method(text, method_name):
    pattern = re.compile(r'((?:[a-zA-Z<>_]+\s+)*' + re.escape(method_name) + r'\s*\([^)]*\)\s*(?:async\s*)?\{)')
    match = pattern.search(text)
    if not match:
        return ''
    start_idx = match.start()
    
    open_braces = 0
    in_string = False
    escape = False
    string_char = ''
    
    for i in range(match.end() - 1, len(text)):
        char = text[i]
        
        if escape:
            escape = False
            continue
            
        if char == '\\':
            escape = True
            continue
            
        if in_string:
            if char == string_char:
                in_string = False
            continue
            
        if char in ['\'', '"']:
            in_string = True
            string_char = char
            continue
            
        if char == '{':
            open_braces += 1
        elif char == '}':
            open_braces -= 1
            if open_braces == 0:
                return text[start_idx:i+1]
                
    return ''

with open(r'e:\AI\xynewui\client\lib\screens\admin_panel_screen.dart', 'r', encoding='utf-8') as f:
    text = f.read()

common_imports = """import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';
import 'dart:io' show File;
import 'post_detail_screen.dart';

"""

def generate_screen(filename, class_name, build_method_name, extra_methods, properties, load_api_path, load_list_name, is_candidates=False):
    # candidates have search so the load is different
    
    if is_candidates:
        init_logic = """
  Future<void> _loadData() async {
    // 默认不自动加载，或只展示提示
    setState(() {
      _isLoading = false;
    });
  }
"""
    else:
        init_logic = f"""
  Future<void> _loadData() async {{
    if (!mounted) return;
    setState(() {{
      _isLoading = true;
      _errorMessage = null;
    }});
    try {{
      final dio = context.read<AuthProvider>().dio;
      final response = await dio.get('{load_api_path}');
      if (!mounted) return;
      setState(() {{
        {load_list_name} = (response.data as List?) ?? [];
        _isLoading = false;
      }});
    }} on DioException catch (e) {{
      if (!mounted) return;
      setState(() {{
        _isLoading = false;
        _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '加载失败');
      }});
    }} catch (e) {{
      if (!mounted) return;
      setState(() {{
        _isLoading = false;
        _errorMessage = e.toString();
      }});
    }}
  }}
"""
    
    methods_code = "\n\n  ".join([extract_method(text, m) for m in extra_methods])
    
    # Get build method body
    build_method_str = extract_method(text, build_method_name)
    # We replace the name to `_buildContent`
    build_method_str = build_method_str.replace(build_method_name, '_buildContent')
    
    helpers = []
    for h in ['_dioErrorMessage', '_buildEmptyState', '_showReasonDialog']:
        if h not in extra_methods and h in build_method_str + methods_code:
            m = extract_method(text, h)
            if m: helpers.append(m)
            
    helpers_code = "\n\n  ".join(helpers)
    
    code = f"""{common_imports}

class {class_name} extends StatefulWidget {{
  const {class_name}({{super.key}});

  @override
  State<{class_name}> createState() => _{class_name}State();
}}

class _{class_name}State extends State<{class_name}> {{
  bool _isLoading = true;
  String? _errorMessage;
  {properties}

  @override
  void initState() {{
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }}

  {init_logic}

  {methods_code}

  @override
  Widget build(BuildContext context) {{
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(title: const Text('{class_name.replace("Admin", "").replace("Screen", "")}')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : _buildContent(isDark),
    );
  }}

  {build_method_str}

  {helpers_code}
}}
"""
    with open(os.path.join(r'e:\AI\xynewui\client\lib\screens', filename), 'w', encoding='utf-8') as f:
        f.write(code)

print("Starting generation")

# 2. admin_candidates_screen.dart
generate_screen(
    'admin_candidates_screen.dart', 
    'AdminCandidatesScreen',
    '_buildCandidatesTab',
    ['_searchCandidates', '_inviteAdmin'],
    'List<dynamic> _candidates = [];\n  final _searchController = TextEditingController();',
    '/admin/candidates',
    '_candidates',
    is_candidates=True
)

# 3. admin_review_tasks_screen.dart
# This is complex because it involves teachers, majors, invitations, removals
# Let's extract the whole thing differently or modify generator.
