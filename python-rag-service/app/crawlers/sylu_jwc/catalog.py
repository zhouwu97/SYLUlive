"""教务处栏目目录。

栏目 URL 使用网站自身的分页链接发现逻辑，不能把第二页简单拼成 /2.htm。
"""

from dataclasses import dataclass


BASE_URL = "https://jwc.sylu.edu.cn"


@dataclass(frozen=True)
class CategoryConfig:
    slug: str
    name: str
    category_id: str | None
    list_path: str
    audience: tuple[str, ...]


CATEGORY_CONFIG: dict[str, CategoryConfig] = {
    "jwtz": CategoryConfig("jwtz", "教务通知", "1116", "/jwtz.htm", ("student",)),
    "jwgg": CategoryConfig("jwgg", "教务公告", "1119", "/jwgg.htm", ("student", "teacher")),
    "jgzt": CategoryConfig("jgzt", "教改专题", "1134", "/jgzt.htm", ("teacher", "faculty")),
    "jxglwj": CategoryConfig("jxglwj", "教学管理文件", "1121", "/jxglwj.htm", ("student", "teacher")),
    "xzzx_jw": CategoryConfig("xzzx_jw", "下载中心", None, "/xzzx/jw.htm", ("student", "teacher")),
    "calendar": CategoryConfig("calendar", "校历", None, "/xl.htm", ("student", "teacher")),
}


def requested_categories(slugs: list[str] | None) -> list[CategoryConfig]:
    """规范化请求栏目，拒绝外部 URL 和未知栏目。"""
    if not slugs:
        slugs = ["jwtz", "jwgg", "jgzt", "jxglwj", "xzzx_jw"]
    result: list[CategoryConfig] = []
    seen: set[str] = set()
    for slug in slugs:
        config = CATEGORY_CONFIG.get(slug)
        if config is None or slug in seen:
            continue
        result.append(config)
        seen.add(slug)
    return result
