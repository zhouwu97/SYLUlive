# 教务成绩抓取结构探测报告

**生成时间**: 2026-06-25
**探测账号**: 24***0128
**探测范围**: 2024-2025 第一学期 ~ 2025-2026 第一学期（5 个学期：2024/3、2024/12、2025/3、2025/12、2026/3，其中 2026/3 暂未开放）

---

## 摘要

本次探测的核心结论是：

> 教务成绩接口 `cjcx_cxXsgrcj.html` 已经完整返回正常考试、补考、重修三类记录，
> 并附带课程代码 `kch_id`、考试性质 `ksxz` / `ksxzdm`、开课类别 `kklxdm`、
> 成绩变动时间 `cjbdsj` 等全套字段。
>
> 数据并没有"没抓到"，而是在 Python `routers/grades.py` 映射 `GradeInfo` 时被
> **裁剪到只剩 9 个字段**，导致下游 Go 后端和 Flutter 应用无法识别同一门课程
> 的不同考试记录，也无法区分历史学期成绩和当前实际状态。
>
> 同一接口还存在**分页截断**的隐藏风险：服务器响应里不返回总页数，生产代码
> 写死的 `queryModel.showCount=50` 会静默丢弃超出 50 条后的成绩记录。
>
> 另外，生产 `services/crawler.py` 源码当前存在 UTF-8 解码损坏（49 个 CJK
> 续字节异常），只能依赖旧 `.pyc` 运行；这是任何改造前的前置阻塞项（见 §7）。

---

## 1. 探测方法

### 1.1 工具链

| 文件 | 作用 |
|------|------|
| `crawler_probe.py` | 最小探针爬虫，按生产 `EduCrawler` 的 8aaf6a1 契约重写，仅含登录 + 成绩抓取所需方法 |
| `run_probe_file.py` | 非交互探针：读取 `.credentials.json`，遍历所有学期，落盘原始 JSON + 字段清单 + 大学外语聚焦 |
| `run_probe_pagination.py` | 补充探针：探测全量查询行为和分页截断行为 |
| `inspect_site_layout.py` | 静态侦察：不登录抓登录页骨架 + 引用的 JS 列表 |
| `sanitize.py` | 输出脱敏工具（学号仅保留后 4 位，姓名替换为 `***`，Cookie 不落盘） |

### 1.2 探测路径

```
Flutter → Go backend (:8080) → Python FastAPI (:8081)
                               → ProbeCrawler
                               → jxw.sylu.edu.cn/cjcx/cjcx_cxXsgrcj.html
```

### 1.3 凭据

- 凭据由开发者本人通过本地 `.credentials.json`（gitignored）提供，仅本机运行使用
- Cookie 仅留在内存，未写入任何文件
- 所有 raw JSON 留在 `tools/edu_probe/output/`（gitignored）
- 探测结束后 `.credentials.json` 由开发者自行删除或保留

---

## 2. 全链路字段丢失分析

### 2.1 原始 items 字段清单（71 个）

5 个学期、49 条 items 合并后得到 **71 个字段**（见 `output/field_inventory.json`）。
这里挑出与"考试识别"和"课程聚合"直接相关的字段：

| 字段 | 含义 | 是否被生产 GradeInfo 提取 |
|------|------|--------------------------|
| `kch` | 课程编号 | ❌ 丢弃 |
| `kch_id` | 课程 ID（同一门课稳定标识） | ❌ 丢弃 |
| `kcmc` | 课程名称 | ✅ → `name` |
| `jxb_id` | 教学班 ID | ✅ → `class_id` |
| `jsxm` | 教师姓名 | ✅ → `teacher` |
| `sfxwkc` | 是否为学位课 | ✅ → `is_degree` |
| `xf` | 学分 | ✅ → `credits` |
| `jd` | 绩点 | ✅ → `gpa` |
| `xfjd` | 学分绩点 | ✅ → `grade_points` |
| `bfzcj` | 百分制成绩 | ✅ → `fraction` |
| `cj` | 等级成绩 / 百分成绩字符串 | ✅ → `grade` |
| `ksxz` | **考试性质**（正常考试 / 补考 / 重修） | ❌ **丢弃** |
| `ksxzdm` | **考试性质代码**（01 / 11 / 16） | ❌ **丢弃** |
| `kklxdm` | **开课类别**（主修课程 / 重修课程） | ❌ **丢弃** |
| `cjbdsj` | 成绩变动时间 | ❌ 丢弃 |
| `cjbdczr` | 成绩变动操作人 | ❌ 丢弃（隐私字段，不应透传） |
| `kcbj` | 课程标记（主修 / 辅修） | ❌ 丢弃 |
| `xnm` / `xqm` | 学年 / 学期代码 | ❌ 丢弃（生产代码在请求时知道，但不带回 items） |

**71 个字段中，生产 `GradeInfo` 仅使用 9 个，其余 62 个被静默丢弃。**

### 2.2 三层链路对照

| 层级 | 文件 | 处理逻辑 | 是否丢 `ksxz/cjbz/kch_id` |
|------|------|---------|--------------------------|
| L0 教务 API | `cjcx_cxXsgrcj.html` | 完整返回 71 字段，含重修/补考 | ✅ 有 |
| L1 Python | `routers/grades.py` → `GradeInfo(...)` | 只赋值 9 字段（`kcmc/jxb_id/jsxm/sfxwkc/xf/jd/xfjd/bfzcj/cj`） | ❌ **首次丢字段点** |
| L1 Pydantic | `models/schemas.py` → `class GradeInfo` | 仅声明 9 字段，无 `exam_type` / `course_id` | ❌ 与 L1 一致 |
| L2 Go | `server/internal/handlers/edu.go` → `GetGrades` | `c.Data(resp.StatusCode, "application/json", resp.Body())` 透明转发 | — Python 已丢，Go 无机会补 |
| L3 Flutter | `client/lib/models/edu_grade.dart` → `EduGrade.fromJson` | 只解析 `name/grade/credits/gpa/is_degree` 5 字段 | ❌ 再次缩减 |

### 2.3 大学外语1 实测三条记录

同一 `kch_id=210700016`，三种考试性质，三个学期：

| 学期 | kcmc | ksxz | ksxzdm | bfzcj | jd | kklxdm | jxb_id |
|------|------|------|--------|-------|-----|--------|--------|
| 2024-2025 第一 | 大学外语1 | 正常考试 | 01 | 53.4 | 0.00 | 主修课程 | 1BC8... |
| 2024-2025 第二 | 大学外语1 | 补考     | 11 | 40.9 | 0.00 | （无该字段） | 2DC1... |
| 2025-2026 第一 | 大学外语1 | 重修     | 16 | **68.9** | 1.89 | **重修课程** | 3F27... |

> 注：`cj`（等级成绩字符串）与 `bfzcj`（百分成绩）在本校三种 ksxz 下数值一致。
> 部分跨学期补考 item 缺 `kklxdm`，所以以 `ksxz` + `ksxzdm` 为权威考试性质字段，
> `kklxdm="重修课程"` 仅作辅助佐证，不作主键。

---

## 3. 根因结论

**根因不是教务成绩接口缺少重修数据。**

`cjcx_cxXsgrcj.html` 已完整返回正常考试、补考、重修三条记录，
并包含课程代码、考试性质、考试性质代码以及重修课程标识。

数据在 Python `routers/grades.py` 映射 `GradeInfo` 时被裁剪到 9 字段，
导致下游 Go 后端和 Flutter 客户端无字段可读，无法区分同一课程的不同考试记录。

Flutter 客户端又按选中学期独立展示，并将历史不及格记录直接用于
"当前未通过课程"统计，因此无法识别该课程后续已经重修通过。

**另外发现一个隐藏的截断 Bug**（见第 4 节）：生产 `showCount=50` 在四年制
本科生常见成绩数（60-80 条）下会静默丢失后段记录。

---

## 4. 全量查询与分页行为

### 4.1 全量查询

| 测试 | 入参 | items 数 | 结论 |
|------|------|---------|------|
| A1 | `xnm=""` + `xqm=""` + `showCount=50` | **49** | ✅ 一次返回全部学期 |
| A2 | 不传 `xnm` / `xqm`，仅 `showCount=50` | 3 | ❌ 仅当前默认学期，不可用 |
| B3 | 分学期 showCount=500 累加 | 15+16+15+3+0 = **49** | 与 A1 一致，互验 |

→ **`xnm=""` 和 `xqm=""` 显式空字符串可一次拉全部成绩，不必逐学期循环请求。**

### 4.2 顶层分页字段

A1 / A3 / B1 顶层观察到的字段：

```
currentPage, currentResult, entityOrField, items, limit, offset,
pageNo, pageSize, showCount, sortName, sortOrder, sorts,
totalCount, totalPage, totalResult
```

但在实际响应里：

- `totalCount`、`totalResult`、`totalPage`、`currentPage` **始终为 0**
- 服务端把 `queryModel` 嵌在每条 item 里（也全是 0），而不是顶层

**→ 服务器实际不告诉你总共多少页。** 唯一可行的截断感知方式是：

1. 优先上调 `showCount`（如 500，对四年成绩绰绰有余），或
2. 客户端循环递增 `currentPage` 直到 **当前页 items 数小于 `showCount`**（或返回空 list）

正确的循环写法（**只能用以下参数名**，已由 B1 实验证实）：

```python
page_size = 500
page = 1
all_items: list[dict] = []

while True:
    resp = await crawler.fetch_grades_page(
        cookie=cookie,
        xnm="",             # 显式空字符串 = 全部学期
        xqm="",
        show_count=page_size,
        current_page=page,
    )
    items = resp.get("items", [])
    all_items.extend(items)
    if len(items) < page_size:    # 当前页未填满 = 最后一页
        break
    page += 1
```

**实际生效的表单参数名**（B1 实验用 `queryModel.currentPage=1` 和 `=2`
返回零重叠的两页，证明此参数名正确）：

```
queryModel.showCount      ← 每页大小
queryModel.currentPage    ← 1 起始的页码
xnm                       ← 学年代码，空字符串表示全部
xqm                       ← 学期代码，空字符串表示全部
```

注意 `currentPage` 必须**放在 `queryModel.` 命名空间下**，顶层 `currentPage`
是只读的响应字段，并不是请求入参。

### 4.3 隐藏截断风险

当前生产写死 `queryModel.showCount=50`，对本账号 4 个学期共 49 条恰好不爆。
但对四年制本科生常见 60-80 条成绩，**会静默丢弃第 51 条之后的记录**——
包括大学外语这种接近毕业学期才重修通过的课程。

**这是独立于字段裁剪的第二个 Bug，必须一并修。**

### 4.4 JS 静态侦察结论（不需登录）

- 前端栈：正方 `zftal-ui-v5-1.0.2` + jQuery + Bootstrap + 客户端 RSA 加密
- 登录表单实际有 21 个字段，`crawler_probe` 只提交 `csrftoken/yhm/mm/language` 4 个，
  目前可登录，说明其它字段服务器不强校验
- CSRF 契约 `id="csrftoken" name="csrftoken" value="..."` 仍有效
- 7 个候选详情端点都返回 302（非 404），说明都存在但需登录：
  - `cjcx_cxCjmx.html`（成绩明细）
  - `cjcx_cxXsKscjList.html`（学生考试成绩列表）
  - `cjcx_cxXsKscjcx.html`（学生考试成绩查询）
  - `cjcx_getXsKscjAllList.html`、`cjcx_getXsjcxx.html`
  - `cj_cxHisCj.html`（历史成绩）
- 引用的前端 JS 中**没有公开发硬编码** `ksxz` / `cjbz` 等字段名
  （`jquery.utils.pinyin.min.js` 里出现的字符串经核对是拼音码表的噪声字符）

---

## 5. 推荐修复方向：方案 B+

### 5.1 设计原则

- **不删除任何考试记录**：正常考试、补考、重修都是合法考试历史
- **不在抓取层替前端决定哪条成绩"该显示"**：聚合 / 替换 / 状态计算下沉到专用接口
- **历史学期成绩保持真实**：2024-2025 第一学期显示 53.4 是对的
- **跨学期状态用聚合表达**：单独提供"考试历史"能力，前端把它当状态修饰

### 5.2 新数据模型

`GradeInfo` 扩展为 `GradeAttempt`（每次考试一条记录）：

```python
class GradeAttempt(BaseModel):
    """一次考试的真实记录（正常考试/补考/重修 各自一条）"""
    course_id: str          # kch_id  — 跨学期聚合主键
    course_code: str        # kch
    course_name: str        # kcmc
    class_id: str           # jxb_id
    teacher: Optional[str]  # jsxm

    academic_year_start: int   # xnm，存储起始年（如 2024），不存 "2024-2025"
    semester: int              # xqm，存 3 或 12（3=第一学期, 12=第二学期）

    exam_type: str             # ksxz：正常考试/补考/重修（中文名称）
    exam_type_code: str        # ksxzdm：01 / 11 / 16（真代码字段）
    course_category: str       # kklxdm：主修课程/重修课程（见下方命名说明）

    is_degree: bool            # sfxwkc == "是"
    credits: float             # xf
    gpa: float                 # jd
    grade_points: float        # xfjd
    fraction: float            # bfzcj
    display_grade: str         # cj

    score_changed_at: Optional[str]  # cjbdsj  — 可选，仅在改分时出现
```

**`kklxdm` 命名说明（重要）**：字段名含 `dm`（代码），但实测 49 条记录里
返回的全是中文名称（主修课程 / 重修课程 / 通识选修课 / 必修课程 / 主修），
且 API 中**没有配套的 `kklxmc` 或 `kklxdm_code` 字段**。这是教务系统的命名不一致。
因此模型用 `course_category: str` 承载中文值，**不要命名为 `course_type_code`**，
否则会误导读者以为它是真代码。若后续登录态详情端点里发现了真正的开课类别代码字段，
再追加 `course_category_code: str` 分离保存。

**学年字段类型说明**：`academic_year_start: int` 存起始年（`2024`），不存
字符串 `"2024-2025"`。显示时由客户端统一转换为 `"2024-2025 学年"`，
避免有的模块用 `2024`、有的模块用 `2024-2025` 的不一致。
`semester: int` 同理存 `3` 或 `12`，由客户端转"第一学期 / 第二学期"。

**不透传**：`cjbdczr`（成绩变动操作人，可能涉及教师或管理员隐私，与用户功能无关）。

### 5.3 列表接口保持"按学期返回考试记录"

```
GET /api/edu/grades?year=2024&semester=3
```

返回该学期真实记录，不去重、不跨学期替换、不改写历史。

→ 用户在 2024-2025 第一学期里看到的依然是 53.4，这是正确的历史信息。

### 5.4 新增课程考试历史能力

```
GET /api/edu/grades/history?course_id=210700016
```

返回：

```json
{
  "course_id": "210700016",
  "course_name": "大学外语1",
  "current_status": "passed",
  "effective_attempt": {
    "academic_year_start": 2025,
    "semester": 3,
    "exam_type": "重修",
    "grade": "68.9"
  },
  "attempts": [
    {"academic_year_start": 2024, "semester": 3,  "exam_type": "正常考试", "grade": "53.4"},
    {"academic_year_start": 2024, "semester": 12, "exam_type": "补考",     "grade": "40.9"},
    {"academic_year_start": 2025, "semester": 3,  "exam_type": "重修",     "grade": "68.9"}
  ]
}
```

聚合规则放在服务端（Python 或 Go 二选一），**不塞进 Flutter**。

**聚合规则**（不依赖 `ksxzdm` 数值大小，因其语义未在教务文档中确认）：

1. 按 `academic_year_start` 升序、再按 `semester` 升序排序
2. 同一学期多条记录按 `cjbdsj`（成绩变动时间）升序排序
3. `passed` 判定：存在任意明确及格记录 → 课程当前状态为 `passed`
4. `effective_attempt` 取最近一次明确及格记录
5. 若从未明确及格：取最近一次明确不及格记录，状态为 `failed`
6. 未录入 / 缓考等未知状态不算及格，也不直接算不及格，状态为 `unknown`

### 5.5 UI 最终语义

- 成绩主页保留"按学期查看"的现有设计
- 选中学期里的不及格考试记录直接显示为 `不及格`
- 旧学期里的不及格记录，若后续学期里已重修通过，加标签 `后续已重修通过`
- 不再把"当前未通过课程"等同于"某学期里某条记录不及格"
- "当前未通过课程"列表改为：**跨全部学期聚合后仍无及格记录的课程**
- 点击课程时展开完整考试历史（正常 53.4 / 补考 40.9 / 重修 68.9 ✓）

---

## 6. 分页修复

`crawler.fetch_grades` 当前：

```python
data={"xnm": year, "xqm": str(semester), "queryModel.showCount": "50"}
```

应改为：

```python
data={"xnm": year, "xqm": str(semester), "queryModel.showCount": "500"}
```

或更稳妥的做法：

- 首次用 `queryModel.showCount=500` 拉一次（500 足以覆盖四年总成绩）
- 若返 items 数等于 500，则循环递增 `queryModel.currentPage` 直到
  当前页 items 数 **小于** `showCount`（或返回空 list）
- 不能假设所有学生成绩少于 50 条
- 详见 §4.2 末尾的可运行循环示例

---

## 7. 生产源码前置门槛 — 必须先恢复 `services/crawler.py`

**实测**（2026-06-25）：当前 `python-edu-service/services/crawler.py` 文件
在 UTF-8 解码时失败：

```
python -m py_compile services/crawler.py
→ Sorry: UnicodeDecodeError: 'utf-8' codec can't decode bytes
       in position 12-13: unexpected end of data
```

这与 `tools/edu_probe/README.md` 记录的"49 corrupted CJK continuation bytes"
一致。生产 Python 服务当前只能依赖旧 `.pyc` 字节码运行；一旦源码被 Python
重启 / 编辑触发重新编译，整个 edu 服务会**直接无法启动**。

在任何成绩逻辑改造之前必须：

1. 从可信历史版本（Git）或运行镜像中的 `__pycache__` 反编译，恢复出 UTF-8
   可读的 `services/crawler.py`
2. `python -m py_compile services/crawler.py` 通过
3. `python -m pytest` 全绿
4. 人工对比生产行为（登录 / 学生信息 / 课表 / 成绩 / Cookie 失效重登）
5. 确认与 `crawler_probe.py` 的契约（URL / 表单字段 / RSA 加密路径）一致

**绝对不能**把 `crawler_probe.py`（探针用最小重写版本）直接覆盖到生产路径，
它不是完整的 `EduCrawler`（缺课表、学生信息、Cookie 失效自动重登等方法）。

---

## 8. 推荐实施顺序

> 本次（feat-prep）只整理证据并提交本报告，不修改生产代码。

后续工程改造分两部分。

### 8.1 第一部分 — 立即实施（不依赖成绩详情接口）

1. ✅ 完成 `grade_structure_report.md`（本文档）
2. ✅ 补测全成绩查询和分页（见 §4）
3. **恢复 `services/crawler.py` 源码**（见 §7，强制前置）
4. 扩展 Python `GradeInfo` → `GradeAttempt`，透传 `exam_type / course_id / course_category`
5. 修复 `services/crawler.py` 的 `showCount=50` 截断 Bug
6. 扩展 Flutter `EduGrade`，先正确显示考试性质字段
7. 在 Python 层新增 `GET /api/edu/grades/history?course_id=...` 聚合接口
8. Flutter 详情悬浮窗：展示教师、考试类型和考试历史
9. Flutter "当前未通过课程"统计改为跨学期聚合判定

### 8.2 第二部分 — 探测到位后再实施（平时分 / 期末分）

第一部分完成后，使用已登录态探针逐一验证以下详情端点（仅静态侦察证实它们
存在且都返回 302，**尚未使用登录态 Cookie 请求过，参数与响应结构未知**）：

```
cjcx_cxCjmx.html            成绩明细
cjcx_cxXsKscjList.html      学生考试成绩列表
cjcx_cxXsKscjcx.html        学生考试成绩查询
cjcx_getXsKscjAllList.html  学生全部考试成绩列表
cjcx_getXsjcxx.html         学生成绩详情
cj_cxHisCj.html              历史成绩
```

对每个端点记录：请求方法 / `gnmkdm` / Referer / 表单参数 /
是否需要 `jxb_id` / 是否需要 `kch_id` / 是否需要 `xnm/xqm` /
返回 HTML 还是 JSON / 是否包含平时分、期末分、比例和总评 /
是否返回完整考试历史。

只有确认真实字段后，才能扩展模型：

```python
usual_score: Optional[float]       # 平时分
usual_weight: Optional[float]      # 平时权重
final_score: Optional[float]       # 期末分
final_weight: Optional[float]      # 期末权重
assessment_type: Optional[str]     # 考试课 / 考查课
```

否则仍然是在猜接口。

### 8.3 建议提交粒度

```
docs(edu-probe): document grade attempts and retake data flow
fix(edu): restore valid production crawler source
fix(edu): prevent silent grade pagination truncation
feat(edu): preserve exam attempt metadata
feat(edu): expose aggregated course grade history
feat(edu): show retake history and current pass status
```

其中第一轮先完成**重修和考试历史**，**不要同时加入平时分、期末分**；
成绩构成要等登录态详情端点探测完成后再接入。

---

## 9. 本次不实施的范围（红线）

按 `WORK_PLAN.md` 第 242 行起的要求，本轮**不修改**以下文件，等待人工审查本报告后再开改造分支：

- `services/crawler.py`
- `routers/grades.py`
- `models/schemas.py`
- `server/internal/handlers/edu.go`
- `client/lib/models/edu_grade.dart`
- `client/lib/providers/edu_provider.dart` 等 Flutter UI 代码

**凭据文件已删除**：`tools/edu_probe/.credentials.json` 在探针完成后立即
执行 `Remove-Item` 删除。它在 `.gitignore` 内不会进 git，但仍按最小曝光原则
从磁盘清除。后续若需复查，请使用 `run_probe.py`（交互版，`getpass.getpass()`
输入密码，不落盘）或临时再生成 `.credentials.json` 后立即删除。

---

## 附录 A：输出文件清单

| 路径 | 说明 |
|------|------|
| `output/all_grades_raw.json` | 5 个学期原始成绩 JSON |
| `output/field_inventory.json` | 71 个字段清单（含类型、出现次数、样例） |
| `output/daxuewaiyu_records.json` | 大学外语全部记录聚焦文件 |
| `output/supplementary_probe.json` | A1/A2/A3/B1/B2/B3 完整响应 |
| `output/site_layout/site_layout_report.md` | 静态侦察报告（登录页 / JS 引用 / 端点 302 状态） |
| `output/site_layout/login_page.html` | 登录页 HTML |
| `output/site_layout/site_layout_summary.json` | 静态侦察 JSON 摘要 |
| `output/site_layout/js/*` | 引用的 23 个 JS 文件 |

---

*本报告由 `tools/edu_probe/` 探针工具集自动采集证据后人工撰写。
凭据仅在本地短暂使用，探针完成后 `.credentials.json` 已从磁盘删除，
确保未写入 git 历史。*