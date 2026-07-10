"""教务系统爬虫核心模块"""
import asyncio
import base64
import binascii
import json
import logging
import random
import re
import time
from datetime import datetime
from typing import Any, Dict, Optional, List, Tuple
from dataclasses import dataclass

import httpx
from bs4 import BeautifulSoup
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

from config import INDEX_URL, COURSE_URL, GRADE_URL

ACADEMIC_SITUATION_URL = "https://jxw.sylu.edu.cn/xsxy/xsxyqk_cxXsxyqkIndex.html"
STUDENT_INFO_URL = "https://jxw.sylu.edu.cn/xsxxxggl/xsgrxxwh_cxXsgrxx.html"
INDEX_INIT_MENU_URL = f"{INDEX_URL}/index_initMenu.html"

logger = logging.getLogger(__name__)


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
    """课表未开放"""
    pass


class GradesNotOpenError(EduError):
    """成绩未开放"""
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

    def _cookie_string(self) -> str:
        return "; ".join(f"{name}={value}" for name, value in self.client.cookies.items()) if self.client else ""

    def _cookie_names(self, cookie: str) -> List[str]:
        return re.findall(r"(?:^|;\s*)([^=;\s]+)=", cookie or "")

    def _set_cookie_names(self, value: str) -> List[str]:
        if not value:
            return []
        return re.findall(r"(?:^|,\s*)([^=;,\s]+)=", value)

    def _response_body_preview(self, html: str, limit: int = 300) -> str:
        text = BeautifulSoup(html or "", "html.parser").get_text(" ", strip=True)
        if not text:
            text = html or ""
        text = re.sub(r"\s+", " ", text).strip()
        return text[:limit]

    def _alert_message(self, html: str) -> Optional[str]:
        match = re.search(r'alert\("([^"]+)"\)', html or "")
        return match.group(1) if match else None

    def _student_info_parse_result(self, html: str) -> Dict[str, bool]:
        info = self._parse_student_info_body(html)
        return {
            "name": bool(info.name),
            "grade": bool(info.grade),
            "college": bool(info.college),
            "major": bool(info.major),
        }

    def _log_unknown_login(self, resp: httpx.Response, probe: Dict[str, Any]) -> None:
        logger.warning(
            "[EDU-LOGIN-UNKNOWN] "
            "login_post_status=%s login_post_location=%r login_post_set_cookie_names=%s "
            "login_post_title=%r login_post_body_hint=%r "
            "cookie_probe_status=%s cookie_probe_title=%r cookie_probe_body_hint=%r "
            "cookie_names=%s student_info_parse_result=%s "
            "menu_probe_status=%s menu_probe_title=%r menu_probe_body_hint=%r",
            resp.status_code,
            resp.headers.get("location", ""),
            self._set_cookie_names(resp.headers.get("set-cookie", "")),
            self._page_title(resp.text),
            self._response_body_preview(resp.text),
            probe.get("cookie_probe_status"),
            probe.get("cookie_probe_title", ""),
            probe.get("cookie_probe_body_hint", ""),
            probe.get("cookie_names", []),
            probe.get("student_info_parse_result", {}),
            probe.get("menu_probe_status"),
            probe.get("menu_probe_title", ""),
            probe.get("menu_probe_body_hint", ""),
        )

    def _parse_student_info_body(self, body: str) -> StudentInfo:
        # 学校页面字段稳定在 col_xxx 容器里，这里集中解析供登录探活和正式接口复用。
        name = ""
        grade = ""
        college = ""
        major = ""

        xm_match = re.search(r'id="col_xm"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if xm_match:
            name = xm_match.group(1).strip()

        nj_match = re.search(r'id="col_njdm_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if nj_match:
            grade = nj_match.group(1).strip()

        jg_match = re.search(r'id="col_jg_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if jg_match:
            college = jg_match.group(1).strip()

        zy_match = re.search(r'id="col_zyh_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if zy_match:
            major = zy_match.group(1).strip()

        return StudentInfo(name=name, grade=grade, college=college, major=major)

    def _has_student_info_fields(self, html: str) -> bool:
        info = self._parse_student_info_body(html)
        return any((info.name, info.grade, info.college, info.major))

    def _has_homepage_fields(self, html: str) -> bool:
        if _looks_like_login_page(html):
            return False
        text = BeautifulSoup(html or "", "html.parser").get_text(" ", strip=True)
        combined = f"{text} {html or ''}"
        tokens = ("退出", "个人信息", "学生", "课表", "成绩", "学籍", "index_initMenu", "gnmkdm")
        return sum(1 for token in tokens if token in combined) >= 2

    async def _verify_login_cookie(self, cookie: str, student_id: str) -> Tuple[bool, Dict[str, Any]]:
        probe: Dict[str, Any] = {
            "cookie_names": self._cookie_names(cookie),
            "student_info_parse_result": {},
        }
        if not self.client or not cookie:
            return False, probe

        headers = {
            "Cookie": cookie,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        }
        try:
            info_resp = await self.client.get(
                STUDENT_INFO_URL,
                params={"gnmkdm": "N100801", "layout": "default", "su": student_id},
                headers={**headers, "Connection": "close"},
            )
            probe.update({
                "cookie_probe_status": info_resp.status_code,
                "cookie_probe_title": self._page_title(info_resp.text),
                "cookie_probe_body_hint": self._response_body_preview(info_resp.text),
                "student_info_parse_result": self._student_info_parse_result(info_resp.text),
            })
            if (
                info_resp.status_code == 200
                and not _looks_like_login_page(info_resp.text)
                and self._has_student_info_fields(info_resp.text)
            ):
                return True, probe

            menu_resp = await self.client.get(
                INDEX_INIT_MENU_URL,
                headers={**headers, "Referer": f"{INDEX_URL}/login_slogin.html"},
            )
            probe.update({
                "menu_probe_status": menu_resp.status_code,
                "menu_probe_title": self._page_title(menu_resp.text),
                "menu_probe_body_hint": self._response_body_preview(menu_resp.text),
            })
            if menu_resp.status_code == 200 and self._has_homepage_fields(menu_resp.text):
                return True, probe
            if menu_resp.status_code == 302:
                location = menu_resp.headers.get("location", "")
                probe["menu_probe_location"] = location
                success = "index_initMenu" in location or ("index" in location and "login_slogin" not in location)
                return success, probe
        except httpx.HTTPError as exc:
            probe["cookie_probe_error"] = str(exc)
            logger.warning("[EDU-LOGIN-PROBE] cookie validation failed: %s", exc)

        return False, probe

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

        alert_message = self._alert_message(resp.text)
        if alert_message:
            credential_message = self._credential_error_message(alert_message)
            if credential_message:
                raise LoginFailedError(credential_message, "INVALID_CREDENTIALS")
            raise LoginFailedError(
                "学校登录页面可能发生变化，请稍后重试或联系管理员",
                "CAS_FLOW_CHANGED",
            )

        credential_message = self._credential_error_message(resp.text)
        if credential_message:
            raise LoginFailedError(credential_message, "INVALID_CREDENTIALS")

        cookie = self._cookie_string()

        if resp.status_code == 302:
            location = resp.headers.get("location", "")
            if ("index_initMenu" in location or "index" in location) and "login_slogin" not in location and cookie:
                return cookie

        # 登录后优先用当前 cookie 访问学生信息页/主页，避免只靠登录页二次 302 误判。
        cookie_ok, cookie_probe = await self._verify_login_cookie(cookie, student_id)
        if cookie_ok:
            return cookie

        # 如果上面的方法失败,检查原始响庁
        if resp.status_code == 302:
            # 尝试获取JSESSIONID
            set_cookie = resp.headers.get("set-cookie", "")
            if 'JSESSIONID' in set_cookie:
                for part in set_cookie.split(','):
                    if 'JSESSIONID' in part:
                        match = re.search(r'JSESSIONID=([^;]+)', part)
                        if match:
                            cookie = f"JSESSIONID={match.group(1)}"
                            cookie_ok, cookie_probe = await self._verify_login_cookie(cookie, student_id)
                            if cookie_ok:
                                return cookie
            self._log_unknown_login(resp, cookie_probe)
            raise LoginFailedError("教务登录会话建立失败，请稍后重试", "SESSION_COOKIE_MISSING")
        elif resp.status_code == 200:
            self._log_unknown_login(resp, cookie_probe)
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
            STUDENT_INFO_URL,
            params={"gnmkdm": "N100801", "layout": "default", "su": student_id},
            headers=headers
        )

        if resp.status_code != 200:
            raise CookieLapseError("获取学生信息失败,Cookie可能已失敁")

        return self._parse_student_info_body(resp.text)

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
            raise CourseNotOpenError("当前学期课表暂未排课")

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

    async def fetch_academic_situation(self, cookie: str) -> dict:
        """抓取学生学业情况查询页面。"""
        if not self.client:
            raise NetworkError("Client not initialized")

        resp = await self.client.get(
            ACADEMIC_SITUATION_URL,
            params={"gnmkdm": "N105515", "layout": "default"},
            headers={
                "Cookie": cookie,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Referer": "https://jxw.sylu.edu.cn/xtgl/index_initMenu.html",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            },
        )

        if resp.status_code in (302, 901):
            raise CookieLapseError("Cookie已失效")
        if resp.status_code != 200:
            raise NetworkError(f"学业情况接口返回状态码 {resp.status_code}")

        body = resp.text
        if _looks_like_login_page(body):
            raise CookieLapseError("Cookie已失效")

        return parse_academic_situation_html(body)


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


def parse_academic_situation_html(html: str) -> dict:
    """解析官方“学生学业情况查询”HTML。"""
    soup = BeautifulSoup(html or "", "html.parser")
    plain_text = _normalize_text(soup.get_text(" ", strip=True))
    total_part, degree_part = _split_academic_summary(plain_text)

    return {
        "success": True,
        "source": "academic_situation",
        "all_gpa": _extract_gpa_value_any(plain_text, [
            "当前所有课程平均学分绩点",
            "所有课程平均学分绩点",
            "当前所有课程GPA",
        ]),
        "degree_gpa": _extract_gpa_value_any(plain_text, [
            "当前学位课程平均学分绩点",
            "当前学位课平均学分绩点",
            "学位课程平均学分绩点",
            "学位课平均学分绩点",
            "当前学位课程GPA",
            "当前学位课GPA",
            "学位课GPA",
        ]),
        "total_courses": _find_int(total_part, r"计划总课程(?:为)?\s*(\d+)\s*门"),
        "passed_courses": _find_int(total_part, r"通过\s*(\d+)\s*门"),
        "failed_courses": _find_int(total_part, r"未通过\s*(\d+)\s*门"),
        "not_started_courses": _find_int(total_part, r"未修\s*(\d+)\s*门"),
        "in_progress_courses": _find_int(total_part, r"在读\s*(\d+)\s*门"),
        "degree_total_courses": _find_int(degree_part, r"计划学位课程(?:为)?\s*(\d+)\s*门"),
        "degree_passed_courses": _find_int(degree_part, r"通过\s*(\d+)\s*门"),
        "degree_failed_courses": _find_int(degree_part, r"未通过\s*(\d+)\s*门"),
        "degree_not_started_courses": _find_int(degree_part, r"未修\s*(\d+)\s*门"),
        "degree_in_progress_courses": _find_int(degree_part, r"在读\s*(\d+)\s*门"),
        "courses": _parse_academic_courses(html),
        "message": None,
        "updated_at": datetime.now().isoformat(),
    }


def _looks_like_login_page(html: str) -> bool:
    text = html or ""
    return any(token in text for token in ("login_slogin", "统一身份认证", "用户登录"))


def _split_academic_summary(text: str) -> Tuple[str, str]:
    total_start = text.find("计划总课程")
    degree_start = text.find("计划学位课程")
    table_start = _first_existing_index(text, ["修读状态", "课程名称", "最大成绩"])

    if total_start < 0:
        total_start = 0
    if degree_start < 0:
        return text[total_start:table_start], ""
    if table_start < 0:
        table_start = len(text)
    return text[total_start:degree_start], text[degree_start:table_start]


def _first_existing_index(text: str, tokens: List[str]) -> int:
    indexes = [text.find(token) for token in tokens if text.find(token) >= 0]
    return min(indexes) if indexes else -1


def _find_float(text: str, pattern: str) -> Optional[float]:
    match = re.search(pattern, text)
    if not match:
        return None
    try:
        return float(match.group(1))
    except (TypeError, ValueError):
        return None


def _compact_text(value: str) -> str:
    return re.sub(r"\s+", "", value or "")


def _extract_gpa_value_any(text: str, labels: List[str]) -> Optional[float]:
    for label in labels:
        value = _extract_gpa_value(text, label)
        if value is not None:
            return value

    compact = _compact_text(text)
    for label in labels:
        compact_label = _compact_text(label)
        index = compact.find(compact_label)
        if index < 0:
            continue

        window = compact[index:index + 100]
        match = re.search(r"([0-9]+(?:\.[0-9]+)?)", window)
        if match:
            try:
                return float(match.group(1))
            except (TypeError, ValueError):
                pass

    return None


def _extract_gpa_value(text: str, label: str) -> Optional[float]:
    """
    从官方学业情况文本中提取 GPA。
    兼容：
    当前所有课程平均学分绩点（GPA）：2.61728
    当前所有课程平均学分绩点 （GPA） ： 2.61728
    当前所有课程平均学分绩点 GPA : 2.61728
    """
    if not text:
        return None

    # 先用宽松正则：label 后面允许任意空白、括号、GPA、冒号，再取第一个数字
    pattern = (
        re.escape(label)
        + r"\s*[\(（]?\s*GPA\s*[\)）]?\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)"
    )
    value = _find_float(text, pattern)
    if value is not None:
        return value

    # fallback：定位 label 后，在后面一小段文本里找第一个浮点数
    index = text.find(label)
    if index < 0:
        return None

    window = text[index:index + 120]
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)", window)
    if not match:
        return None

    try:
        return float(match.group(1))
    except (TypeError, ValueError):
        return None


def _find_int(text: str, pattern: str) -> int:
    match = re.search(pattern, text)
    if not match:
        return 0
    try:
        return int(match.group(1))
    except (TypeError, ValueError):
        return 0


def _parse_academic_courses(html: str) -> List[dict]:
    soup = BeautifulSoup(html or "", "html.parser")
    for table in soup.select("table"):
        parsed = _parse_academic_course_table(table)
        if parsed:
            return parsed
    return []


def _parse_academic_course_table(table) -> List[dict]:
    rows = table.select("tr")
    header_index = -1
    headers: List[str] = []

    for index, tr in enumerate(rows):
        cells = [_normalize_text(cell.get_text(" ", strip=True)) for cell in tr.select("th,td")]
        if "课程名称" in cells and "最大成绩" in cells and "修读状态" in cells:
            header_index = index
            headers = cells
            break

    if header_index < 0:
        return []

    field_map = {
        "修读状态": "study_status",
        "成绩学年": "academic_year",
        "学期": "semester",
        "课程号": "course_code",
        "课程名称": "course_name",
        "学时": "hours",
        "课程性质": "course_nature",
        "学分": "credits",
        "课程类别": "course_category",
        "最大成绩": "max_grade",
        "绩点": "gpa",
        "成绩": "grade",
        "补考": "makeup_grade",
        "重修": "retake_grade",
        "建议修读学年": "suggested_year",
        "建议修读学期": "suggested_semester",
        "课程重要性质数": "important_nature_count",
    }

    courses = []
    for tr in rows[header_index + 1:]:
        cells = [_normalize_text(td.get_text(" ", strip=True)) for td in tr.select("td")]
        if not any(cells):
            continue

        row: Dict[str, Any] = {}
        for header, cell in zip(headers, cells):
            field = field_map.get(header)
            if field:
                row[field] = _empty_to_none_text(cell)

        if not row.get("course_name"):
            continue

        row["course_code"] = row.get("course_code") or ""
        row["credits"] = _to_float(row.get("credits"))
        row["gpa"] = _to_nullable_float(row.get("gpa"))
        row["is_degree"] = _is_degree_course(row)
        row["has_retake"] = _has_value(row.get("retake_grade"))
        row["effective_grade"] = _effective_grade(row)
        row["effective_passed"] = _effective_passed(row)
        courses.append(row)

    return courses


def _empty_to_none_text(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    if not text or text in ("--", "—", "-"):
        return None
    return text


def _has_value(value: Optional[str]) -> bool:
    return _empty_to_none_text(value) is not None


def _to_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _to_nullable_float(value: Any) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _is_degree_course(row: Dict[str, Any]) -> bool:
    text = " ".join(
        str(row.get(key) or "")
        for key in ("course_nature", "course_category")
    )
    important = str(row.get("important_nature_count") or "").strip()
    return "学位" in text or (important not in ("", "0", "0.0"))


def _effective_grade(row: Dict[str, Any]) -> Optional[str]:
    for key in ("max_grade", "retake_grade", "makeup_grade", "grade"):
        value = _empty_to_none_text(row.get(key))
        if value:
            return value
    return None


def _effective_passed(row: Dict[str, Any]) -> Optional[bool]:
    status = str(row.get("study_status") or "").strip()
    if "未通过" in status:
        return False
    if "通过" in status or "已通过" in status:
        return True
    if "在读" in status or "未修" in status:
        return None

    grade = _effective_grade(row)
    if not grade:
        return None

    numeric = float(grade) if re.fullmatch(r"\d+(?:\.\d+)?", grade) else None
    if numeric is not None:
        return numeric >= 60
    if re.fullmatch(r"优秀|良好|中等|及格|合格", grade):
        return True
    if re.fullmatch(r"不及格|不合格|未通过", grade):
        return False
    return None


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

