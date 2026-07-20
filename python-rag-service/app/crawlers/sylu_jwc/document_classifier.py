"""抓取后初步分类，结果只用于审核路由，不代表自动发布。"""

import re


def classify(title: str, content: str, category_slug: str) -> tuple[str, list[str]]:
    text = f"{title}\n{content}"
    if category_slug == "jgzt":
        return "teaching_reform", ["teacher", "faculty"]
    if category_slug == "xzzx_jw":
        if re.search(r"申请表|审批表|登记表|模板|表格", text):
            return "form", ["student", "teacher"]
        if re.search(r"流程|办理|联系方式", text):
            return "procedure", ["student", "teacher"]
        return "unknown", ["student", "teacher"]
    if re.search(r"管理办法|管理规定|认定及处理|条例", text):
        return "policy", ["student", "teacher"]
    if re.search(r"考试安排|日课表|课程表|实践环节", text):
        return "exam_schedule", ["student"]
    if re.search(r"报名|截止|时间安排|通知", text):
        return "deadline_notice", ["student", "teacher"]
    return "notice", ["student", "teacher"]
