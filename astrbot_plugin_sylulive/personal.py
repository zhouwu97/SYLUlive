"""个人结果只经确定命令输出，不送进群或模型上下文。"""
from datetime import datetime, timezone, timedelta
import re

from .client import IntegrationProblem


def personal_intent(text):
    # 只识别本人简短查询；不把姓名、账号、否定句或引文转成私人读取。
    found = re.fullmatch(
        r"(?:请|麻烦)?(?:帮我|给我)?(?:查询|查一下|查下|查|看看|看一下|看)?"
        r"(?:我的|本人|我)?(成绩|二课)(?:情况|怎么样|积分|分数|还差多少分?|多少分?|是多少)?",
        text,
    )
    return ("grades" if found[1] == "成绩" else "erke") if found else None


def format_personal(body, dataset):
    data = body.get("data")
    if not isinstance(data, dict) or data.get("dataset") != dataset:
        raise IntegrationProblem("invalid_response")
    title = "你的已同步成绩" if dataset == "grades" else "你的已同步二课摘要"
    fetched = data.get("fetched_at")
    try:
        date = datetime.fromisoformat(fetched.replace("Z", "+00:00"))
        stamp = date.astimezone(timezone(timedelta(hours=8))).strftime("%Y-%m-%d %H:%M")
    except (ValueError, TypeError, AttributeError):
        stamp = "时间未知"
    lines = [title, f"同步时间：{stamp}（非学校实时查询）"]
    if data.get("is_stale"):
        lines.append("这份数据已过期，请先在 App 或官网重新同步。")
    if data.get("is_partial"):
        lines.append("目前仅有部分数据，不能当作完整记录。")
    if dataset == "grades":
        semester_names = {3: "第一学期", 12: "第二学期", 16: "第三学期", "3": "第一学期", "12": "第二学期", "16": "第三学期"}
        terms = [f"{term.get('year', '未知学年')} {semester_names.get(term.get('semester'), '学期未标注')}"
                 for term in data.get("covered_terms", []) if isinstance(term, dict)]
        if terms:
            lines.append("已同步范围：" + "、".join(terms[:12]) + ("等" if len(terms) > 12 else ""))
        rows = data.get("grades")
        if not isinstance(rows, list):
            raise IntegrationProblem("invalid_response")
        for row in rows:
            name = row.get("course_name") or "未标注课程"
            score = next((row[k] for k in ("fraction", "score", "grade") if row.get(k) is not None), "未公布")
            suffix = f"，学分 {row['credits']}" if row.get("credits") is not None else ""
            lines.append(f"• {name}：{score}{suffix}")
        if not rows:
            lines.append("本页没有课程成绩；这不代表学校尚未出分或没有其他学期成绩。")
        if type(data.get("next_offset")) is int:
            lines.append(f"当前为部分成绩。继续查看：/sylu-grades {data['next_offset']}")
        lines.append("只包含已同步的学期，缺少的学期请先同步。")
    else:
        summary = data.get("summary")
        if not isinstance(summary, dict):
            raise IntegrationProblem("invalid_response")
        for key, label in (("graduation", "毕业要求"), ("yearly", "学年要求")):
            row = summary.get(key, {})
            values = []
            for field, text in (("earned_total", "已获"), ("required_total", "要求"),
                                ("graduation_gap", "差额"), ("yearly_gap", "差额")):
                if row.get(field) is not None:
                    values.append(f"{text} {row[field]}")
            lines.append(f"{label}：{'，'.join(values) if values else '数据未提供'}")
            for category in row.get("unmet_categories", []):
                lines.append(f"• {category.get('name', '未标注分类')}：差 {category.get('gap', '未知')}")
            if row.get("official_conclusion"):
                lines.append(str(row["official_conclusion"]))
        lines.append("这是本人同步的二课摘要，不是完整活动明细；缺项请在 App 或官网查询并同步。")
    return "\n".join(lines)
