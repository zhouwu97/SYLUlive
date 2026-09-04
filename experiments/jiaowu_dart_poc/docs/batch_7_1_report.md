# Batch 7.1 Grade Detail — 完整实现报告

## 状态：✓ 实现完成，等待 Android 真机验证

---

## 一、实现内容

### 1. 核心 API 层

#### `lib/src/api/grade_detail_api.dart`
- **职责**：成绩详情查询 API，迁移 Python 四候选 endpoint 策略
- **端点序列**：
  1. `/cjcx/cjcx_cxCjxqGjh.html` (N305005) — 官方详情端点
  2. `/cjcx/cjcx_getXsjcxx.html` (N305005) — 第二候选
  3. `/cjcx/cjcx_cxCjmx.html` (N305005) — 第三候选
  4. `/cjcx/cjcx_cxXsKscjList.html` (N305005) — 最后候选
- **降级策略**：当某端点返回空 components 时，自动尝试下一个
- **Session 管理**：检测 302/901/登录页，标记 session expired

#### `lib/src/model/grade_detail.dart`
- **GradeDetail 模型**：
  - `success`: 是否成功获取详情
  - `courseName`: 课程名称
  - `totalGrade`: 总评成绩
  - `components`: 成绩构成列表
  - `message`: 错误或提示信息

#### `lib/src/model/grade_component.dart`
- **GradeComponent 模型**：
  - `name`: 分项名称（平时、期末、实验、考勤等）
  - `weight`: 权重比例（可选）
  - `score`: 分项成绩

#### `lib/src/parser/grade_detail_parser.dart`
- **职责**：解析成绩详情响应（JSON/HTML 双格式兼容）
- **JSON 解析**：
  - 候选键集合：`['items', 'rows', 'data']`
  - 分项名称：`['cjxmmc', 'xmmc', 'xm', 'name', 'mc', 'cjfmc']`
  - 分项成绩：`['cj', 'xmcj', 'score', 'df', 'cjz', 'kscj', 'bfzcj']`
  - 权重比例：`['bl', 'xmbfb', 'cjxmbl', 'weight', 'qz', 'zb']`
- **HTML 解析**：
  - 表格特征识别：包含"成绩分项"、"分项比例"、"成绩"
  - 行解析：跳过表头，提取 3 列或 2 列数据
- **名称规范化**：去除 `【】[]` 前后缀

### 2. Client 集成

#### `lib/src/core/jiaowu_client.dart`
- 新增 `getGradeDetail()` 方法
- 参数：
  - `year`: 学年（必需）
  - `semester`: 学期（必需）
  - `classId`: 教学班 ID（必需）
  - `courseName`: 课程名称（必需）
  - `courseId`: 课程 ID（可选）
  - `studentGradeId`: 学生成绩 ID（可选）

### 3. 能力声明

#### `lib/src/core/academic_capabilities.dart`
- 本地能力：`supportsGradeDetail: true`
- 服务器能力保持：`supportsGradeDetail: false`

---

## 二、测试覆盖

### 单元测试（108 个测试全过）

#### `test/parser/grade_detail_parser_test.dart` (25 tests)
- ✅ JSON 解析：items/rows/data 候选
- ✅ HTML 解析：表格识别、多列处理
- ✅ 空响应处理
- ✅ 名称规范化：去除 `【】[]`
- ✅ 总评识别：优先"总"字，其次 last component

#### `test/api/grade_detail_api_test.dart` (6 tests)
- ✅ 官方详情端点参数正确性
- ✅ 降级策略：第一个端点空 → 尝试第二个
- ✅ Session 过期检测：302/901/登录页
- ✅ 全部候选端点返回空 → unavailable detail

#### `test/integration/grade_detail_integration_test.dart` (4 tests)
- ✅ 完整流程：login → getGrades → getGradeDetail
- ✅ 验证码重试场景
- ✅ 多课程并发查询
- ✅ Session 过期场景

#### `test/core/jiaowu_client_test.dart` (73 tests，含原有)
- ✅ `getGradeDetail()` 方法集成
- ✅ Session 未认证检测
- ✅ 参数传递正确性

---

## 三、Differential 验证

### Python ↔ Dart 对照测试

#### 测试环境
- Python: 旧服务器 `EduCrawler`
- Dart: 本地 `JiaowuClient`
- 账号: `2403060128` / `@Zhoukangwu0`
- 查询范围: 2025-12 学期前两门课程

#### 验证结果

```
================================================================================
Python ↔ Dart 成绩详情 Differential 比较
================================================================================

课程 1: 数据通信与机器人控制
--------------------------------------------------------------------------------
  ✓ 完全一致

课程 2: 信号与系统
--------------------------------------------------------------------------------
  ✓ 完全一致

================================================================================
总结
================================================================================
Missing:           0
Extra:             0
Changed:           0
OrderOnlyChanged:  0

✓ PASS: Python ↔ Dart 成绩详情完全一致
```

#### 详细对照

**课程 1: 数据通信与机器人控制**
- 总评: 良好 ✓
- 分项数: 4 ✓
- 分项内容:
  - 平时成绩: 100 (40%) ✓
  - 作品成绩: 83 (30%) ✓
  - 课程报告: 82 (30%) ✓
  - 总评: 良好 ✓

**课程 2: 信号与系统**
- 总评: 55.8 ✓
- 分项数: 3 ✓
- 分项内容:
  - 平时: 84.7 (50%) ✓
  - 期末: 27 (50%) ✓
  - 总评: 55.8 ✓

---

## 四、Android Probe

### 实现状态
- ✅ Android probe app 已创建
- ✅ 集成 `jiaowu_dart_poc` 本地包
- ✅ 网络权限已配置
- ✅ UI 实现：账号输入 + 日志输出
- ⏳ **等待真机验证**

### Probe 功能
1. 登录教务系统
2. 获取学生 Profile
3. 获取成绩列表
4. 查询前两门课程成绩详情
5. 实时日志输出

### 运行指南
详见 `android_probe/README.md`

**快速运行**：
```bash
cd experiments/jiaowu_dart_poc/android_probe
flutter devices  # 确认设备连接
flutter run      # 运行到真机
```

---

## 五、迁移对照

### Python 端原始能力

```python
def fetch_grade_detail(
    self,
    year: str,
    semester: int,
    class_id: str,
    course_name: str,
    course_id: str = None,
    student_grade_id: str = None,
) -> Dict[str, Any]:
    """
    尝试四个候选端点：
    1. cjcx_cxCjxqGjh.html
    2. cjcx_getXsjcxx.html
    3. cjcx_cxCjmx.html
    4. cjcx_cxXsKscjList.html
    """
```

### Dart 端等价实现

```dart
Future<GradeDetail> fetch({
  required String year,
  required int semester,
  required String classId,
  required String courseName,
  String? courseId,
  String? studentGradeId,
}) async {
  // 四候选端点循环尝试
  for (final candidate in _candidates) {
    final detail = await _tryFetch(candidate, ...);
    if (detail.success && detail.components.isNotEmpty) {
      return detail;
    }
  }
  // 全部失败 → unavailable
}
```

### 迁移完整度：100%

| 功能点           | Python | Dart | 状态 |
| ------------- | ------ | ---- | -- |
| 四候选端点         | ✅      | ✅    | ✓  |
| 降级策略          | ✅      | ✅    | ✓  |
| JSON 解析       | ✅      | ✅    | ✓  |
| HTML 解析       | ✅      | ✅    | ✓  |
| Session 过期检测 | ✅      | ✅    | ✓  |
| 名称规范化         | ✅      | ✅    | ✓  |
| 总评识别          | ✅      | ✅    | ✓  |

---

## 六、目录结构

```
experiments/jiaowu_dart_poc/
├── lib/src/
│   ├── api/
│   │   └── grade_detail_api.dart          # 新增
│   ├── model/
│   │   ├── grade_detail.dart               # 新增
│   │   └── grade_component.dart            # 新增
│   ├── parser/
│   │   └── grade_detail_parser.dart        # 新增
│   ├── core/
│   │   ├── jiaowu_client.dart              # 更新：集成 getGradeDetail
│   │   └── academic_capabilities.dart      # 更新：supportsGradeDetail
├── test/
│   ├── parser/
│   │   └── grade_detail_parser_test.dart   # 新增 25 tests
│   ├── api/
│   │   └── grade_detail_api_test.dart      # 新增 6 tests
│   └── integration/
│       └── grade_detail_integration_test.dart # 新增 4 tests
├── tools/differential/
│   ├── python_query.py                     # 新增
│   ├── dart_query.dart                     # 新增
│   ├── compare.py                          # 新增
│   └── run_differential.sh                 # 新增
└── android_probe/                          # 新增
    ├── lib/main.dart
    ├── android/
    │   └── app/src/main/AndroidManifest.xml
    └── README.md
```

---

## 七、后续步骤

### Gate 条件

- ⏳ **Android 真机验证**
  - 连接 Android 设备
  - 运行 `android_probe`
  - 确认日志输出符合预期
  - 截图或记录日志

### 通过标准

Android probe 成功完成且日志输出包含：
```
✓ 登录成功
✓ Profile: 周康武 (2403060128)
✓ 成绩列表: 13 条
✓ 总评: 良好
✓ 分项数: 4
✓ Android Probe 完成
```

### 完成后

1. 记录 Android probe 输出
2. 标记 Batch 7.1 为 **COMPLETE**
3. 合并到 `jiaowu` 分支
4. 进入 Batch 7.2 (Academic Situation / GPA)

---

## 八、技术细节

### TLS 证书处理

Dart 端内嵌 TrustAsia G5 中间证书：
```dart
static const String _trustAsiaG5Intermediate = '''
-----BEGIN CERTIFICATE-----
MIIFKDCCAxCgAwIBAgIQDoLwvCUBH+fy3vTDkyjWBzANBgkqhkiG9w0BAQ0FADBc
...
-----END CERTIFICATE-----
''';
```

Python 端（differential 验证时）禁用 SSL 验证：
```python
verify=False  # 仅用于测试
```

### Session 管理

三种过期检测：
1. HTTP 302 → 登录页
2. HTTP 901 → 自定义过期状态
3. 200 但响应是登录页 HTML

检测到过期后：
```dart
_session.markExpired();
throw SessionExpiredException('...');
```

### 解析器容错

- JSON 格式：尝试 `items`/`rows`/`data` 多个键
- HTML 格式：多列兼容（2 列或 3 列）
- 空数据：返回 `success: false` 而非抛异常
- 名称清理：统一去除 `【】[]` 装饰符

---

## 九、已知限制

1. **Android probe 未验证**：需要真机连接
2. **Differential 仅两门课程**：可以扩展到全部成绩
3. **TLS 证书硬编码**：生产环境需考虑证书更新机制
4. **Session 过期恢复**：当前仅检测，未实现自动重登

---

## 十、总结

### 实现质量

- ✅ **代码完整**：API/Model/Parser/Client 全部实现
- ✅ **测试充分**：108 个测试覆盖所有路径
- ✅ **Differential PASS**：Python ↔ Dart 完全一致
- ✅ **文档完善**：README、注释、报告齐全
- ⏳ **Android 验证**：等待真机运行

### 迁移目标达成

Batch 7.1 目标：
> **完整迁移 Python 端成绩详情抓取能力到 Dart 本地实现**

当前状态：
- 代码层面：✅ 100% 完成
- 验证层面：✅ Differential PASS，⏳ Android 待验证

### 下一步

**立即行动**：连接 Android 设备，运行 probe

**完成后**：进入 Batch 7.2 (Academic Situation)

---

生成时间: 2026-09-03
报告版本: v1.0
