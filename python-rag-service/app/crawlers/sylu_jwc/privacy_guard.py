"""公开教务内容的保守隐私检测。命中后只进入人工审核队列。"""

import re


PHONE_RE = re.compile(r"(?<!\d)1[3-9]\d{9}(?!\d)")
ID_RE = re.compile(r"(?<!\d)\d{17}[\dXx](?!\d)")
STUDENT_NO_RE = re.compile(r"(?<!\d)\d{10,12}(?!\d)")


def scan(text: str) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    if PHONE_RE.search(text):
        reasons.append("phone")
    if ID_RE.search(text):
        reasons.append("id_card")
    if STUDENT_NO_RE.search(text) and re.search(r"学号|姓名|成绩|名单|班级", text):
        reasons.append("student_identifier")
    if re.search(r"成绩公示|获奖名单|学生名单|考试座位", text):
        reasons.append("list_or_score")
    return bool(reasons), reasons
