"""教务系统爬虫核心模块"""
import asyncio
import base64
import binascii
import json
import random
import re
import time
from typing import Optional, List, Tuple
from dataclasses import dataclass

import httpx
from bs4 import BeautifulSoup
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

from config import INDEX_URL, COURSE_URL, GRADE_URL


# ============== 错误定义 ==============

class EduError(Exception):
    """教务错误基类"""

    def __init__(self, message: str, code: str = "EDU_ERROR"):
        super().__init__(message)
        self.code = code


class CookieLapseError(EduError):
    """Cookie失效"""

    def __init__(self, message: str = "教务登录会话已失效，请重新登录"):
        super().__init__(message, "SESSION_EXPIRED")


class LoginFailedError(EduError):
    """登录失败"""

    def __init__(self, message: str, code: str = "UNKNOWN_LOGIN_STATE"):
        super().__init__(message, code)


class CourseNotOpenError(EduError):
    """课表未开攁"""
    pass


class GradesNotOpenError(EduError):
    """成绩未开攁"""
    pass


class NetworkError(EduError):
    """网络错误"""

    def __init__(self, message: str, code: str = "REMOTE_SYSTEM_UNAVAILABLE"):
        super().__init__(message, code)


# ============== 数据模型 ==============

@dataclass
class PublicKey:
    """RSA公钥"""
    modulus: str
    exponent: str


@dataclass
class CourseRawData:
    """原始课表数据"""
    name: str
    teacher: str
    location: str
    time: str  # 节次字符串，如"1-2节"
    week_day: str  # 星期，如"1"
    week_str: str  # 周数字符串，如"1-16周"


@dataclass
class StudentInfo:
    """学生信息"""
    name: str
    grade: str
    college: str
    major: str


# ============== 爬虫核心籁==============

class EduCrawler:
    """教务系统爬虫"""

    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout
        self.client: Optional[httpx.AsyncClient] = None
        self.cookies: List[httpx.Cookies] = []

    async def __aenter__(self):
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=False,
            verify=True,  # 启用SSL验证
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                "Cache-Control": "no-cache",
            }
        )
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.client:
            await self.client.aclose()

    def _now_time_ms(self) -> str:
        """获取当前时间戳(毫秒!"""
        return str(int(time.time() * 1000))

    def _credential_error_message(self, html: str) -> Optional[str]:
        """仅在官方页面明确提示账号/密码错误时返回用户提示。"""
        text = BeautifulSoup(html or "", "html.parser").get_text(" ", strip=True)
        combined = f"{text} {html or ''}"
        patterns = [
            "用户名或密码错误",
            "账号或密码错误",
            "账户或密码错误",
            "账号密码错误",
            "密码错误",
            "用户不存在",
        ]
        if any(pattern in combined for pattern in patterns):
            return "教务账号或密码错误"
        return None

    def _page_title(self, html: str) -> str:
        soup = BeautifulSoup(html or "", "html.parser")
        return soup.title.get_text(strip=True) if soup.title else ""

    # ============== 认证相关 ==============

    async def get_csrf_token(self) -> str:
        """获取CSRF Token和初始Cookie"""
        if not self.client:
            raise NetworkError("Client not initialized")

        for retry in range(3):
            try:
                resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                if resp.status_code == 200:
                    # 从HTML中提取csrftoken(可能有逗号分隔的两个值,取第一个)
                    match = re.search(r'id="csrftoken" name="csrftoken" value="([^"]+)"', resp.text)
                    if match:
                        csrf = match.group(1)
                        # 如果有逗号,取第一部分
                        if ',' in csrf:
                            csrf = csrf.split(',')[0]
                        return csrf
                    raise LoginFailedError(
                        "学校登录页面可能发生变化，请稍后重试或联系管理员",
                        "CSRF_MISSING",
                    )
                elif resp.status_code == 302:
                    # 重定向,获取cookie
                    self.cookies = resp.cookies
                    # 再次请求获取完整页面
                    resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                    match = re.search(r'id="csrftoken" name="csrftoken" value="([^"]+)"', resp.text)
                    if match:
                        csrf = match.group(1)
                        if ',' in csrf:
                            csrf = csrf.split(',')[0]
                        return csrf
                else:
                    raise NetworkError(f"获取CSRF失败,状态码: {resp.status_code}")
            except httpx.TimeoutException:
                if retry < 2:
                    await asyncio.sleep(0.5)
                    continue
                raise NetworkError("获取CSRF超时")

        raise NetworkError("获取CSRF失败")

    async def get_public_key(self) -> PublicKey:
        """获取RSA公钥"""
        if not self.client:
            raise NetworkError("Client not initialized")

        timestamp = self._now_time_ms()
        resp = await self.client.get(
            f"{INDEX_URL}/login_getPublicKey.html",
            params={"time": timestamp, "_": timestamp}
        )

        if resp.status_code != 200:
            raise NetworkError("学校教务系统暂时不可用，请稍后再试")

        try:
            data = resp.json()
            return PublicKey(modulus=data["modulus"], exponent=data["exponent"])
        except (json.JSONDecodeError, KeyError) as e:
            raise LoginFailedError(
                "学校登录加密参数解析失败，请稍后重试或联系管理员",
                "PUBLIC_KEY_PARSE_ERROR",
            ) from e

    def _rsa_encrypt(self, password: str, public_key: PublicKey) -> str:
        """RSA加密密码"""
        try:
            # 解码base64的modulus和exponent
            modulus_bytes = base64.b64decode(public_key.modulus)
            exponent_bytes = base64.b64decode(public_key.exponent)

            # 构建公钥
            from cryptography.hazmat.primitives.asymmetric import rsa
            from cryptography.hazmat.backends import default_backend
            public_numbers = rsa.RSAPublicNumbers(
                e=int.from_bytes(exponent_bytes, 'big'),
                n=int.from_bytes(modulus_bytes, 'big')
            )
            pub_key = public_numbers.public_key(default_backend())

            # 加密
            encrypted = pub_key.encrypt(
                password.encode('utf-8'),
                padding.PKCS1v15()
            )
            return base64.b64encode(encrypted).decode('ascii')
        except binascii.Error as e:
            raise LoginFailedError(
                "教务密码加密失败，请稍后重试",
                "PUBLIC_KEY_PARSE_ERROR",
            ) from e

    async def login(self, student_id: str, password: str) -> str:
        """登录教务系统，返回Cookie字符串"""
        if not self.client:
            raise NetworkError("Client not initialized")

        # 1. 获取CSRF Token
        csrf_token = await self.get_csrf_token()

        # 2. 获取公钥
        public_key = await self.get_public_key()

        # 3. 加密密码
        encrypted_password = self._rsa_encrypt(password, public_key)

        # 4. 执行登录
        timestamp = self._now_time_ms()
        login_data = {
            "csrftoken": csrf_token,
            "language": "zh_CN",
            "yhm": student_id,
            "mm": encrypted_password,
        }

        resp = await self.client.post(
            f"{INDEX_URL}/login_slogin.html",
            data=login_data,
            params={"time": timestamp}
        )

        # 登录POST后,可能返回302重定吁
        # 即使返回302到login_slogin.html,也可能是登录成功(服务器设置cookie后重定向!
        # 需要跟随重定向,用更新后的cookie继续请求

        # 获取当前有效的JSESSIONID(登录后设置的)
        jsessionid = None
        for name, value in self.client.cookies.items():
            if name == 'JSESSIONID':
                jsessionid = value
                break

        if jsessionid:
            # 用登录后的cookie尝试访问主页
            redirect_resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
            # 如果重定向到主页,说明登录成劁
            if redirect_resp.status_code == 302:
                location = redirect_resp.headers.get('location', '')
                if 'index_initMenu' in location or 'index' in location:
                    # 登录成功!构建cookie字符丁
                    cookie_parts = []
                    for name, value in self.client.cookies.items():
                        cookie_parts.append(f"{name}={value}")
                    return "; ".join(cookie_parts)

        # 如果上面的方法失败,检查原始响庁
        if resp.status_code == 302:
            # 检查是否有alert
            if 'alert' in resp.text:
                error_match = re.search(r'alert\("([^"]+)"\)', resp.text)
                if error_match:
                    message = error_match.group(1)
                    credential_message = self._credential_error_message(message)
                    if credential_message:
                        raise LoginFailedError(credential_message, "INVALID_CREDENTIALS")
                    raise LoginFailedError(
                        "学校登录页面可能发生变化，请稍后重试或联系管理员",
                        "CAS_FLOW_CHANGED",
                    )
            # 尝试获取JSESSIONID
            set_cookie = resp.headers.get("set-cookie", "")
            if 'JSESSIONID' in set_cookie:
                for part in set_cookie.split(','):
                    if 'JSESSIONID' in part:
                        match = re.search(r'JSESSIONID=([^;]+)', part)
                        if match:
                            return f"JSESSIONID={match.group(1)}"
            raise LoginFailedError("教务登录会话建立失败，请稍后重试", "SESSION_COOKIE_MISSING")
        elif resp.status_code == 200:
            error_match = re.search(r'alert\("([^"]+)"\)', resp.text)
            if error_match:
                message = error_match.group(1)
                credential_message = self._credential_error_message(message)
                if credential_message:
                    raise LoginFailedError(credential_message, "INVALID_CREDENTIALS")
                raise LoginFailedError(
                    "学校登录页面可能发生变化，请稍后重试或联系管理员",
                    "CAS_FLOW_CHANGED",
                )
            credential_message = self._credential_error_message(resp.text)
            if credential_message:
                raise LoginFailedError(credential_message, "INVALID_CREDENTIALS")
            raise LoginFailedError(
                "学校登录状态未知，请稍后重试或联系管理员",
                "UNKNOWN_LOGIN_STATE",
            )
        else:
            raise NetworkError(f"登录请求失败,状态码: {resp.status_code}")

    async def get_student_info(self, cookie: str, student_id: str) -> StudentInfo:
        """获取学生基本信息"""
        if not self.client:
            raise NetworkError("Client not initialized")

        # 使用正确的URL获取学生信息(参考学长项目)
        headers = {
            "Cookie": cookie,
            "Connection": "close"
        }
        resp = await self.client.get(
            f"https://jxw.sylu.edu.cn/xsxxxggl/xsgrxxwh_cxXsgrxx.html",
            params={"gnmkdm": "N100801", "layout": "default", "su": student_id},
            headers=headers
        )

        if resp.status_code != 200:
            raise CookieLapseError("获取学生信息失败,Cookie可能已失敁")

        body = resp.text

        # 解析学生信息(HTML结构:id="col_xxx"下有<p>标签!
        name = ""
        grade = ""
        college = ""
        major = ""

        # 提取姓名 id=col_xm
        xm_match = re.search(r'id="col_xm"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if xm_match:
            name = xm_match.group(1).strip()

        # 提取年级 id=col_njdm_id
        nj_match = re.search(r'id="col_njdm_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if nj_match:
            grade = nj_match.group(1).strip()

        # 提取学院 id=col_jg_id
        jg_match = re.search(r'id="col_jg_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if jg_match:
            college = jg_match.group(1).strip()

        # 提取专业 id=col_zyh_id
        zy_match = re.search(r'id="col_zyh_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if zy_match:
            major = zy_match.group(1).strip()

        return StudentInfo(name=name, grade=grade, college=college, major=major)

    # ============== 课表相关 ==============

    async def fetch_courses(self, cookie: str, year: str, semester: int) -> List[CourseRawData]:
        """获取课表  优先桌面端JSON(全量),回退移动端JSON"""
        if not self.client:
            raise NetworkError("Client not initialized")

        base_headers = {
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }

        all_courses: List[CourseRawData] = []
        seen = set()

        def _add_from_kblist(kb_list, source=""):
            for item in kb_list:
                course = CourseRawData(
                    name=item.get("kcmc", ""),
                    teacher=item.get("xm", ""),
                    location=item.get("cdmc", ""),
                    time=item.get("jc", ""),
                    week_day=str(item.get("xqj", "1")),
                    week_str=item.get("zcd", "")
                )
                key = (course.name, course.week_day, course.time)
                if key not in seen:
                    seen.add(key)
                    all_courses.append(course)
            print(f"  [{source}] 新增 {len(all_courses)} 门课(去重后!")

        # ==========================================
        # Step 1: 桌面竁JSON(首选:全量课表!
        # ==========================================
        desktop_headers = dict(base_headers)
        desktop_headers.update({
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
            "Referer": f"{COURSE_URL}/xskbcx_cxXsKb.html?gnmkdm=N2154",
            "Origin": COURSE_URL,
        })

        try:
            resp = await self.client.post(
                f"{COURSE_URL}/xskbcx_cxXsKb.html",
                params={"gnmkdm": "N2154"},
                data={"xnm": str(year), "xqm": str(semester), "kblx": "1"},
                headers=desktop_headers,
                timeout=10.0
            )
            print(f"  [DESK] status={resp.status_code}, len={len(resp.text)}")
            # 901 = session expired; 302 = redirected to login page
            if resp.status_code in (901, 302):
                raise CookieLapseError("Cookie已过朁(DESK)")
            if resp.status_code == 200 and resp.text.strip() not in ("null", ""):
                data = resp.json()
                kb_list = data.get("kbList", [])
                _add_from_kblist(kb_list, "DESK")
        except EduError:
            raise  # CookieLapseError 等需要向上传撁
        except Exception as e:
            print(f"  [DESK] 失败: {e}")

        # ==========================================
        # Step 2: 移动竁JSON(备用回退!
        # ==========================================
        if not all_courses:
            print("  [MOBILE] 桌面端无数据,回退移动竁..")
            try:
                resp = await self.client.post(
                    f"{COURSE_URL}/xskbcxMobile_cxXsKb.html",
                    params={"gnmkdm": "N2154"},
                    data={"xnm": str(year), "zs": "1", "doType": "app", "xqm": str(semester), "kblx": "1"},
                    headers=base_headers,
                    timeout=10.0
                )
                if resp.status_code == 200 and resp.text.strip() not in ("null", ""):
                    data = resp.json()
                    kb_list = data.get("kbList", [])
                    _add_from_kblist(kb_list, "MOBILE")
            except Exception as e:
                print(f"  [MOBILE] 失败: {e}")

        if not all_courses:
            raise CourseNotOpenError("当前学期课表暂未开攁")

        return all_courses

    # ============== 成绩相关 ==============

    async def fetch_grades(self, cookie: str, year: str, semester: int) -> List[dict]:
        """获取成绩原始数据"""
        if not self.client:
            raise NetworkError("Client not initialized")

        headers = {"Cookie": cookie}
        query_data = {"doType": "query", "gnmkdm": "N305005"}
        page_size = 500
        page = 1
        all_items: List[dict] = []

        while True:
            form_data = {
                "xnm": year,
                "xqm": str(semester),
                "queryModel.showCount": str(page_size),
                "queryModel.currentPage": str(page),
            }

            resp = await self.client.post(
                f"{GRADE_URL}/cjcx_cxXsgrcj.html",
                params=query_data,
                data=form_data,
                headers=headers
            )

            if resp.status_code != 200:
                raise CookieLapseError("获取成绩失败,Cookie可能已失敁")

            content_type = resp.headers.get("Content-Type", "")
            if "text/html" in content_type:
                raise CookieLapseError("Cookie已失敁")

            try:
                data = json.loads(resp.text)
            except json.JSONDecodeError:
                raise GradesNotOpenError("成绩数据解析失败")

            items = data.get("items", [])
            all_items.extend(items)
            if len(items) < page_size:
                break
            page += 1

        if not all_items:
            raise GradesNotOpenError("当前学期暂无成绩")

        return all_items

    async def fetch_grade_detail(
        self,
        cookie: str,
        year: str,
        semester: int,
        class_id: str,
        course_name: str,
        course_id: Optional[str] = None,
        student_grade_id: Optional[str] = None,
    ) -> dict:
        """按课程查询成绩构成明细。"""
        if not self.client:
            raise NetworkError("Client not initialized")

        headers = {
            "Cookie": cookie,
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Referer": f"{GRADE_URL}/cjcx_cxDgXscj.html?gnmkdm=N305005&layout=default",
        }
        base_form = {
            "xnm": year,
            "xqm": str(semester),
            "jxb_id": class_id,
            "jxbid": class_id,
            "kcmc": course_name,
        }
        if student_grade_id:
            base_form["xh_id"] = student_grade_id
        if course_id:
            base_form["kch_id"] = course_id
            base_form["kch"] = course_id

        candidates = [
            ("cjcx_cxCjxqGjh.html", base_form),
            ("cjcx_getXsjcxx.html", base_form),
            ("cjcx_cxCjmx.html", base_form),
            ("cjcx_cxXsKscjList.html", {
                **base_form,
                "doType": "query",
                "queryModel.showCount": "20",
            }),
        ]

        last_message = "暂未获取到成绩构成"
        for endpoint, form_data in candidates:
            resp = await self.client.post(
                f"{GRADE_URL}/{endpoint}",
                params={"gnmkdm": "N305005"},
                data=form_data,
                headers=headers,
            )

            if resp.status_code in (302, 901):
                raise CookieLapseError("Cookie已失敁")
            if resp.status_code != 200:
                last_message = f"详情接口返回状态码 {resp.status_code}"
                continue
            if "text/html" in resp.headers.get("Content-Type", "") and "login_slogin" in resp.text:
                raise CookieLapseError("Cookie已失敁")

            parsed = parse_grade_detail_response(resp.text, course_name)
            if parsed["components"]:
                return parsed
            if parsed.get("message"):
                last_message = parsed["message"]

        return {
            "success": False,
            "course_name": course_name,
            "total_grade": "",
            "components": [],
            "message": last_message,
        }


def parse_grade_detail_response(body: str, course_name: str) -> dict:
    """解析成绩构成响应，兼容 JSON 和 HTML 表格。"""
    text = body.strip()
    if not text:
        return _empty_grade_detail(course_name, "详情响应为空")

    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None

    if payload is not None:
        components = _parse_grade_detail_json(payload)
        total_grade = _find_total_grade(components)
        return {
            "success": bool(components),
            "course_name": course_name,
            "total_grade": total_grade,
            "components": components,
            "message": None if components else "详情 JSON 中没有成绩构成",
        }

    components = _parse_grade_detail_html(text)
    total_grade = _find_total_grade(components)
    return {
        "success": bool(components),
        "course_name": course_name,
        "total_grade": total_grade,
        "components": components,
        "message": None if components else "详情 HTML 中没有成绩构成",
    }


def _empty_grade_detail(course_name: str, message: str) -> dict:
    return {
        "success": False,
        "course_name": course_name,
        "total_grade": "",
        "components": [],
        "message": message,
    }


def _parse_grade_detail_json(payload) -> List[dict]:
    rows = []
    if isinstance(payload, dict):
        if isinstance(payload.get("items"), list):
            rows = payload["items"]
        elif isinstance(payload.get("rows"), list):
            rows = payload["rows"]
        elif isinstance(payload.get("data"), list):
            rows = payload["data"]
        elif isinstance(payload.get("data"), dict):
            return _parse_grade_detail_json(payload["data"])
        else:
            for value in payload.values():
                if isinstance(value, list):
                    rows = value
                    break
    elif isinstance(payload, list):
        rows = payload

    components: List[dict] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = _first_non_empty(row, ["cjxmmc", "xmmc", "xm", "name", "mc", "cjfmc"])
        score = _first_non_empty(row, ["cj", "xmcj", "score", "df", "cjz", "kscj", "bfzcj"])
        weight = _first_non_empty(row, ["bl", "xmbfb", "cjxmbl", "weight", "qz", "zb"])
        if not name or not score:
            continue
        components.append({"name": _normalize_component_name(name), "weight": weight or None, "score": score})
    return components


def _parse_grade_detail_html(html: str) -> List[dict]:
    soup = BeautifulSoup(html, "html.parser")
    components: List[dict] = []

    for table in soup.select("table"):
        header_cells = [
            _normalize_text(cell.get_text(" ", strip=True))
            for cell in table.select("tr th, tr td")
        ][:8]
        header_text = " ".join(header_cells)
        if not any(token in header_text for token in ("成绩分项", "分项比例", "成绩")):
            continue

        for tr in table.select("tr"):
            cells = [_normalize_text(td.get_text(" ", strip=True)) for td in tr.select("td")]
            cells = [cell for cell in cells if cell]
            if len(cells) < 2:
                continue
            if any(token in cells[0] for token in ("成绩分项", "分项名称")):
                continue

            if len(cells) >= 3:
                name, weight, score = cells[0], cells[1], cells[2]
            else:
                name, weight, score = cells[0], None, cells[1]
            if name and score:
                components.append({"name": _normalize_component_name(name), "weight": weight or None, "score": score})

    return components


def _first_non_empty(row: dict, keys: List[str]) -> str:
    for key in keys:
        value = row.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return ""


def _find_total_grade(components: List[dict]) -> str:
    for component in components:
        if "总" in component.get("name", ""):
            return component.get("score", "")
    return components[-1]["score"] if components else ""


def _normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _normalize_component_name(value: str) -> str:
    text = _normalize_text(value)
    return text.strip("【】[] ").strip()


# ============== 辅助函数 ==============

def parse_weeks(week_str: str) -> List[int]:
    """解析周数字符串，如'1-16周,18周' -> [1,2,3,...,16,18]"""
    weeks = []
    if not week_str:
        return weeks

    # 移除"周"
    week_str = week_str.replace("周", "")

    # 按逗号分割
    parts = week_str.split(",")
    for part in parts:
        part = part.strip()
        if "-" in part:
            # 范围,如 "1-16"
            try:
                start, end = part.split("-")
                for i in range(int(start), int(end) + 1):
                    weeks.append(i)
            except ValueError:
                continue
        else:
            # 单周
            try:
                weeks.append(int(part))
            except ValueError:
                continue

    return sorted(list(set(weeks)))


def parse_time_sections(time_str: str) -> Tuple[int, int]:
    """将节次字符串转换为实际起始和结束节次数字

    支持格式!
      - "1-2芁 / "3-4芁 ↁ(1, 2) / (3, 4)
      - "0102" / "0304" ↁ(1, 2) / (3, 4)!位数字,剁位是起始节,吁位是结束节)
    """
    if not time_str:
        return (1, 2)
    # 格式1: "3-4芁 戁"3-4"
    match = re.search(r'(\d+)[-~](\d+)', time_str)
    if match:
        return (int(match.group(1)), int(match.group(2)))
    # 格式2: "0304"!位数字,取前2位和吁位)
    if time_str.isdigit() and len(time_str) >= 4:
        return (int(time_str[:2]), int(time_str[2:4]))
    # 格式3: 纯数字或逗号分隔
    nums = re.findall(r'\d+', time_str)
    if len(nums) >= 2:
        return (int(nums[0]), int(nums[-1]))
    elif nums:
        return (int(nums[0]), int(nums[0]))
    return (1, 2)

