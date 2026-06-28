# 成绩结构探测 — 工作步骤

## 目标

回答一个问题：**"大学外语1" 重修通过后得了 68.9 分，为什么 App 显示的是旧的不及格成绩？**

需要搞清楚：
1. 成绩列表 API (`cjcx_cxXsgrcj.html`) 返回的原始 JSON 里到底有哪些字段
2. 大学外语1 的原始记录和重修记录分别长什么样
3. 当前生产代码 (`routers/grades.py` → `GradeInfo`) 丢弃了哪些字段
4. 是否存在详情接口可以拿到平时分、期末分、权重

## 你的任务

写一个 `tools/edu_probe/run_probe.py`，登录 → 抓取 → 保存原始 JSON → 不用脱敏（本地跑），然后人工对比。

---

## 步骤 1：确认现有代码的数据流

先搞清楚当前生产代码从哪里拿数据、丢了什么。

### 1a. 看 Python 路由层映射了什么

```
文件: python-edu-service/routers/grades.py
```

找到 `GradeInfo` 的构造位置。当前只取 9 个字段：

| Python 字段 | 原始 JSON key | 说明 |
|------------|-------------|------|
| name | kcmc | 课程名 |
| class_id | jxb_id | 教学班 ID |
| teacher | jsxm | 教师 |
| is_degree | sfxwkc | 是否学位课 |
| credits | xf | 学分 |
| gpa | jd | 绩点 |
| grade_points | xfjd | 学分绩点 |
| fraction | bfzcj | 百分成绩 |
| grade | cj | 等级成绩 |

所有其他字段 → **被丢弃**。问题很可能在这里。

### 1b. 看 Pydantic 模型

```
文件: python-edu-service/models/schemas.py
```

找 `class GradeInfo(BaseModel)`。确认只有 9 个字段，没有任何重修/考试性质/平时分/期末分字段。

### 1c. 看 Go 后端转发

```
文件: server/internal/handlers/edu.go（或类似路径）
```

Go 后端负责转发 `POST /edu/grades` 到 Python 服务。确认 Go 有没有额外过滤字段。

### 1d. 看 Flutter 模型

```
文件: client/lib/models/edu_grade.dart
```

确认 `EduGrade.fromJson` 解析了哪些字段。当前只有 `name, displayGrade, credits, gpa, isDegree` 五个。

---

## 步骤 2：写全自动探针脚本

创建 `tools/edu_probe/run_probe.py`：

```python
"""一键运行：登录教务 → 抓取所有学期 → 保存原始 JSON → 输出大学外语1 对比"""
import asyncio, json, getpass, sys
from pathlib import Path
from crawler_probe import ProbeCrawler

OUTPUT = Path(__file__).resolve().parent / "output"

async def main():
    student_id = input("学号: ").strip()
    password = getpass.getpass("教务密码: ").strip()

    async with ProbeCrawler(timeout=20) as crawler:
        cookie = await crawler.login(student_id, password)
        print(f"登录成功\n")

        # 探测从入学年到当前的所有学期
        enrollment_year = int("20" + student_id[:2])  # 学号前2位 = 入学年
        current_year = 2026
        semesters_to_try = []

        for y in range(enrollment_year, current_year + 1):
            for s in [3, 12]:  # 3=第一学期, 12=第二学期
                if y == current_year and s == 12:
                    continue  # 跳过未来学期(现在是6月, 第二学期刚结束?)
                semesters_to_try.append((str(y), s))

        all_data = {}
        for year, semester in semesters_to_try:
            try:
                items = await crawler.fetch_grades(cookie, year, semester)
                key = f"{year}_{semester}"
                all_data[key] = items
                print(f"{year} 学期{semester}: {len(items)} 条")

                # 找大学外语
                for item in items:
                    if "大学外语" in item.get("kcmc", ""):
                        print(f"  → {item['kcmc']}: cj={item.get('cj')}, bfzcj={item.get('bfzcj')}")
                        # 打印全部字段
                        print(f"  → 完整字段: {list(item.keys())}")
                        for k, v in sorted(item.items()):
                            print(f"     {k}: {v}")

            except Exception as e:
                print(f"{year} 学期{semester}: {type(e).__name__}")

        # 保存全部原始数据到 output/
        OUTPUT.mkdir(parents=True, exist_ok=True)
        with open(OUTPUT / "all_grades_raw.json", "w", encoding="utf-8") as f:
            json.dump(all_data, f, ensure_ascii=False, indent=2, default=str)
        print(f"\n原始数据已保存到 output/all_grades_raw.json")
        print(f"共 {len(all_data)} 个学期，请检查 output/all_grades_raw.json")

asyncio.run(main())
```

**这个脚本做的事**：
- 从入学年到当前，自动遍历所有学期
- 对每个学期调用 `fetch_grades()`
- 找到所有包含"大学外语"的记录，**打印全部字段名和值**
- 把所有原始 JSON 保存到 `output/all_grades_raw.json`

---

## 步骤 3：运行探针

```bash
cd E:/AI/xynewui/python-edu-service
python tools/edu_probe/run_probe.py
```

输入学号和密码。等待约 10-30 秒。

输出示例：
```
2023 学期3: 8 条
  → 大学外语1: cj=不及格, bfzcj=53.4
  → 完整字段: ['kcmc', 'jxb_id', 'jsxm', 'sfxwkc', 'xf', 'jd', 'xfjd', 'bfzcj', 'cj', 'ksxz', 'cjbz', ...]
     bfzcj: 53.4
     cj: 不及格
     cjbz: None
     jd: 0
     jsxm: ***
     jxb_id: ***
     kcmc: 大学外语1
     ksxz: 正常考试
     sfxwkc: 是
     xf: 3.0
     xfjd: 0
2024 学期3: 10 条
  → 大学外语1: cj=合格, bfzcj=68.9
  → 完整字段: ['kcmc', 'jxb_id', 'jsxm', 'sfxwkc', 'xf', 'jd', 'xfjd', 'bfzcj', 'cj', 'ksxz', 'cjbz', ...]
     bfzcj: 68.9
     cj: 合格
     cjbz: 重修通过
     jd: 1.7
     ksxz: 重修
     xf: 3.0
```

---

## 步骤 4：人工对比

打开 `output/all_grades_raw.json`，找到大学外语1 的两条记录，逐字段对比。

重点关注以下字段（如果 API 返回了它们）：

| 关注点 | 可能对应字段 | 说明 |
|--------|------------|------|
| 考试性质 | `ksxz` | 正常考试 / 补考 / 重修 |
| 成绩备注 | `cjbz` | 可能包含"重修通过" |
| 课程代码 | `kch` / `kch_id` | 同一门课的稳定标识 |
| 有效成绩 | 未知 | 可能是 `bfzcj` 或另一字段 |
| 平时成绩 | `pscj` | |
| 期末成绩 | `qmcj` | |
| 总评成绩 | `zpcj` | |
| 重修标记 | `cxbj` / `ksxz` | |

---

## 步骤 5：对照生产代码，确定根因

拿到原始数据后，回头看：

1. **Python `routers/grades.py`** 丢弃了哪些字段？
   - 对照 `GradeInfo` 的 9 个字段和原始 JSON 的全部字段
   - 如果 `ksxz`（考试性质）和 `cjbz`（成绩备注）在原始数据里但不在 `GradeInfo` 里 → **Python 层丢弃了关键信息**

2. **Flutter `EduGrade`** 丢弃了哪些字段？
   - 当前只有 5 个字段
   - 如果 Go 后端透传了 `ksxz` 但 Flutter 没解析 → **Flutter 层丢弃了关键信息**

3. **Go 后端** 有没有额外过滤？
   - 检查 Go handler 是否只转发 `GradeInfo` 的字段

4. 大学外语1 原考试和重修记录是否在**不同学期**？
   - 如果重修记录在 2024 秋，原记录在 2023 秋 → App 可能请求了错误学期

---

## 步骤 6：写分析报告

在 `tools/edu_probe/report/grade_structure_report.md` 中记录：

```markdown
## 根因分析

1. 大学外语1 有两条记录：
   - 2023 秋：bfzcj=53.4, cj=不及格, ksxz=正常考试
   - 2024 秋：bfzcj=68.9, cj=合格, ksxz=重修, cjbz=重修通过

2. 当前生产代码的问题：
   - Python GradeInfo 没有 ksxz 和 cjbz 字段 → 丢弃
   - Flutter EduGrade 只有 5 个字段 → 即使 Go 透传也无法显示
   - App 请求了 2023 秋的成绩 → 拿到了不及格记录

3. 修复方向：
   - Python schemas.py: GradeInfo 增加 ksxz, cjbz 字段
   - Python routers/grades.py: 映射 ksxz, cjbz
   - Flutter EduGrade: 增加 examType, gradeNote 字段
   - Flutter UI: 显示考试性质和成绩备注
```

---

## 不做的事

- 不修改 `services/crawler.py`
- 不修改 `routers/grades.py`
- 不修改 Go handler
- 不修改 Flutter
- 不提交 `output/all_grades_raw.json`（含真实成绩）
