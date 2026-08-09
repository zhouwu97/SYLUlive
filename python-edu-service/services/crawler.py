"""教务系统爬虫核心模块"""
import asyncio
import base64
import binascii
import hashlib
import json
import logging
import random
import re
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional, List, Tuple
from dataclasses import dataclass

import httpx
from bs4 import BeautifulSoup
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

from config import INDEX_URL, COURSE_URL, GRADE_URL

ACADEMIC_SITUATION_URL = "https://jxw.sylu.edu.cn/xsxy/xsxyqk_cxXsxyqkIndex.html"
ACADEMIC_SITUATION_SOURCE_PATH = "/xsxy/xsxyqk_cxXsxyqkIndex.html"
ACADEMIC_SITUATION_PARSER_VERSION = "academic-situation-v2"
ACADEMIC_REQUIREMENT_URL = "https://jxw.sylu.edu.cn/xjyj/xjyj_cxXjyjIndex.html"
ACADEMIC_REQUIREMENT_QUERY_URL = "https://jxw.sylu.edu.cn/xjyj/xjyj_cxXjyjjdlb.html"
ACADEMIC_REQUIREMENT_SOURCE_PATH = "/xjyj/xjyj_cxXjyjIndex.html"
ACADEMIC_REQUIREMENT_PARSER_VERSION = "credit-requirement-v2"
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

    def __init__(self, message: str = "教务登录会话已失效，请重新登录", code: str = "SESSION_EXPIRED"):
        super().__init__(message, code)


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
            "密码不正确",
            "用户不存在",
        ]
        if any(pattern in combined for pattern in patterns):
            return "教务账号或密码错误"
        return None

    def _page_title(self, html: str) -> str:
        soup = BeautifulSoup(html or "", "html.parser")
        return soup.title.get_text(strip=True) if soup.title else ""

    def _seed_cookie_jar(self, cookie: str) -> None:
        """将 Cookie 字符串注入 client jar，后续请求由 jar 自动发送。

        httpx 行为：未显式设置 Cookie header 的请求会使用 jar 中的 cookies；
        预热响应中的 Set-Cookie 也会被 jar 自动合并，不会因固定 header 而丢失。
        """
        if not self.client or not cookie:
            return
        for part in cookie.split(";"):
            part = part.strip()
            if "=" in part:
                name, _, value = part.partition("=")
                self.client.cookies.set(name.strip(), value.strip(), domain="jxw.sylu.edu.cn")

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
        """获取课表，优先桌面端 JSON（全量），回退移动端 JSON。

        失败必须按原因分类。原来两个分支都用 ``except Exception`` 吞掉，然后统一抛
        CourseNotOpenError，于是 Cookie 失效、返回登录页、响应体不是 JSON、教务系统
        改版这些完全不同的故障，对用户都显示成“当前学期课表暂未排课”：既不会触发
        重新登录，也无法从日志判断到底断在哪一步。
        """
        if not self.client:
            raise NetworkError("Client not initialized")

        base_headers = {
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }

        all_courses: List[CourseRawData] = []
        seen = set()
        # 记录每一步的失败原因，全部失败时据此决定抛哪种异常。
        failures: List[str] = []
        saw_valid_empty_response = False

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
            print(f"  [{source}] 累计 {len(all_courses)} 门课(去重后)")

        def _consume(resp, source: str) -> None:
            """解析一次课表响应；无法解析时按原因分类，不再静默吞掉。"""
            nonlocal saw_valid_empty_response
            # 901 = session expired; 302 = redirected to login page
            if resp.status_code in (901, 302):
                raise CookieLapseError(f"教务会话已失效({source})")
            if resp.status_code != 200:
                failures.append(f"{source}:http_{resp.status_code}")
                return
            body = resp.text.strip()
            if _looks_like_login_page(body):
                # 教务系统有时不发 302，而是直接用 200 返回登录页。
                raise CookieLapseError(f"教务返回登录页({source})")
            if body in ("", "null"):
                failures.append(f"{source}:empty_body")
                return
            try:
                data = resp.json()
            except ValueError:
                failures.append(f"{source}:not_json")
                return
            if not isinstance(data, dict):
                failures.append(f"{source}:unexpected_shape")
                return
            kb_list = data.get("kbList")
            if kb_list is None:
                failures.append(f"{source}:missing_kbList")
                return
            if not isinstance(kb_list, list):
                failures.append(f"{source}:kbList_not_list")
                return
            # 结构合法且确实没有课，才是真正的“未排课”。
            saw_valid_empty_response = True
            _add_from_kblist(kb_list, source)

        # ==========================================
        # Step 1: 桌面端 JSON（首选：全量课表）
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
            _consume(resp, "DESK")
        except EduError:
            raise  # CookieLapseError 等需要向上传递
        except Exception as e:
            failures.append(f"DESK:{type(e).__name__}")
            print(f"  [DESK] 失败: {type(e).__name__}")

        # ==========================================
        # Step 2: 移动端 JSON（备用回退）
        # ==========================================
        if not all_courses:
            print("  [MOBILE] 桌面端无数据，回退移动端")
            try:
                resp = await self.client.post(
                    f"{COURSE_URL}/xskbcxMobile_cxXsKb.html",
                    params={"gnmkdm": "N2154"},
                    data={"xnm": str(year), "zs": "1", "doType": "app", "xqm": str(semester), "kblx": "1"},
                    headers=base_headers,
                    timeout=10.0
                )
                print(f"  [MOBILE] status={resp.status_code}, len={len(resp.text)}")
                _consume(resp, "MOBILE")
            except EduError:
                raise
            except Exception as e:
                failures.append(f"MOBILE:{type(e).__name__}")
                print(f"  [MOBILE] 失败: {type(e).__name__}")

        if all_courses:
            return all_courses

        if saw_valid_empty_response:
            # 两个端点都给出结构合法但为空的课表，这才是真正的未排课。
            raise CourseNotOpenError("当前学期课表暂未排课")

        # 没有任何一次成功解析：这是故障，不是未排课。
        detail = ",".join(failures) if failures else "no_response"
        print(f"  [COURSES] 全部失败: {detail}")
        raise NetworkError(f"教务课表接口无法解析({detail})", "COURSE_FETCH_UNPARSABLE")

    # ============== 成绩相关 ==============

    async def _prepare_grade_page(self) -> None:
        """查询成绩前预热成绩模块页面，完成教务会话初始化"""
        headers = {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Referer": "https://jxw.sylu.edu.cn/xtgl/index_initMenu.html",
            "User-Agent": self.client.headers.get("User-Agent", ""),
        }

        resp = await self.client.get(
            f"{GRADE_URL}/cjcx_cxDgXscj.html",
            params={
                "gnmkdm": "N305005",
                "layout": "default",
            },
            headers=headers,
        )

        if resp.status_code in (302, 901) or _looks_like_login_page(resp.text):
            raise CookieLapseError("教务登录会话已失效")

        if resp.status_code != 200:
            raise NetworkError(f"成绩页面初始化失败，状态码 {resp.status_code}")

    async def fetch_grades(self, cookie: str, year: str, semester: int) -> List[dict]:
        """获取成绩原始数据 — 先预热成绩模块页面再请求 JSON 接口"""
        if not self.client:
            raise NetworkError("Client not initialized")

        # 将 Cookie 注入 client jar，后续请求由 jar 自动管理
        # 这样预热响应的 Set-Cookie 会自然流入 AJAX 请求
        self._seed_cookie_jar(cookie)

        # 预热成绩模块，完成教务会话初始化
        try:
            await self._prepare_grade_page()
        except CookieLapseError:
            raise
        except NetworkError:
            raise
        except Exception as e:
            logger.warning(
                "[EDU-GRADES] grade page warmup failed: %s, proceeding anyway", e
            )

        ajax_headers = {
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
            "Referer": (
                f"{GRADE_URL}/cjcx_cxDgXscj.html"
                "?gnmkdm=N305005&layout=default"
            ),
            "Origin": "https://jxw.sylu.edu.cn",
        }
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
                headers=ajax_headers,
            )

            # 明确跳转登录页 / 状态码 901 → Cookie 过期
            if resp.status_code in (302, 901):
                raise CookieLapseError(
                    f"成绩接口返回状态码 {resp.status_code}，Cookie 已失效"
                )

            # 页面内容包含登录表单 → Cookie 过期
            if _looks_like_login_page(resp.text):
                raise CookieLapseError("成绩接口返回登录页面，Cookie 已失效")

            # 其余非 200 → 网络/上游异常，不判 Cookie 过期
            if resp.status_code != 200:
                logger.warning(
                    "[EDU-GRADES] unexpected status "
                    "status=%s content_type=%r title=%r body_preview=%r",
                    resp.status_code,
                    resp.headers.get("Content-Type", ""),
                    self._page_title(resp.text),
                    self._response_body_preview(resp.text),
                )
                raise NetworkError(f"成绩接口返回状态码 {resp.status_code}")

            content_type = resp.headers.get("Content-Type", "").lower()

            # 非 JSON → 诊断日志，不一律判 Cookie 过期
            if "application/json" not in content_type:
                logger.warning(
                    "[EDU-GRADES] non-JSON response "
                    "status=%s content_type=%r location=%r title=%r body_preview=%r",
                    resp.status_code,
                    content_type,
                    resp.headers.get("location", ""),
                    self._page_title(resp.text),
                    self._response_body_preview(resp.text),
                )
                raise NetworkError("成绩接口返回了非 JSON 数据，教务系统可能正在维护")

            try:
                data = json.loads(resp.text)
            except json.JSONDecodeError:
                logger.warning(
                    "[EDU-GRADES] malformed JSON response "
                    "status=%s content_type=%r title=%r body_preview=%r",
                    resp.status_code,
                    content_type,
                    self._page_title(resp.text),
                    self._response_body_preview(resp.text),
                )
                raise NetworkError("成绩接口返回了无法解析的数据，教务系统可能正在维护")

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

    async def fetch_credit_requirements(self, cookie: str) -> dict:
        """抓取官方学籍预警入口，并执行页面脚本使用的 JSON 查询。"""
        if not self.client:
            raise NetworkError("Client not initialized")

        headers = {
            "Cookie": cookie,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Referer": "https://jxw.sylu.edu.cn/xtgl/index_initMenu.html",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        }
        try:
            resp = await self.client.get(
                ACADEMIC_REQUIREMENT_URL,
                params={"gnmkdm": "N105505", "layout": "default"},
                headers=headers,
            )
        except httpx.HTTPError as exc:
            raise NetworkError("连接教务学分要求页面失败") from exc

        if resp.status_code in (302, 901):
            raise CookieLapseError("Cookie已失效")
        if resp.status_code != 200:
            raise NetworkError(f"学分要求接口返回状态码 {resp.status_code}")

        body = resp.text
        if _looks_like_login_page(body):
            raise CookieLapseError("Cookie已失效")

        soup = BeautifulSoup(body or "", "html.parser")
        query = _extract_credit_requirement_query(soup)
        if query is None:
            return _credit_req_failure(
                "query_protocol_changed",
                datetime.now(timezone.utc).isoformat(),
                _credit_req_structure_signature(
                    soup, _normalize_text(soup.get_text(" ", strip=True)),
                ),
                error_code="CREDIT_REQUIREMENT_QUERY_PROTOCOL_CHANGED",
                message="学分要求查询协议发生变化，请稍后重试",
            )

        query_payload, query_context = query
        try:
            query_resp = await self.client.post(
                ACADEMIC_REQUIREMENT_QUERY_URL,
                data=query_payload,
                headers={
                    **headers,
                    "Accept": "application/json, text/javascript, */*; q=0.01",
                    "Referer": str(resp.url),
                    "X-Requested-With": "XMLHttpRequest",
                },
            )
        except httpx.HTTPError as exc:
            raise NetworkError("查询教务学分要求失败") from exc

        if query_resp.status_code in (302, 901):
            raise CookieLapseError("Cookie已失效")
        if query_resp.status_code != 200:
            raise NetworkError(
                f"学分要求查询接口返回状态码 {query_resp.status_code}",
            )
        if _looks_like_login_page(query_resp.text):
            raise CookieLapseError("Cookie已失效")

        try:
            payload = query_resp.json()
        except (json.JSONDecodeError, ValueError) as exc:
            logger.warning(
                "[EDU-CREDIT-REQ] query_protocol_failed status=%s content_type=%r body_length=%s",
                query_resp.status_code,
                query_resp.headers.get("content-type", ""),
                len(query_resp.text or ""),
            )
            return _credit_req_failure(
                "query_protocol_changed",
                datetime.now(timezone.utc).isoformat(),
                hashlib.sha256(b"invalid-credit-requirement-json").hexdigest(),
                error_code="CREDIT_REQUIREMENT_QUERY_PROTOCOL_CHANGED",
                message="教务学分要求返回格式异常，请稍后重试",
            )

        parsed = parse_credit_requirement_json(
            payload,
            query_context=query_context,
        )
        logger.warning(
            "[EDU-CREDIT-REQ] "
            "entry_status=%s query_status=%s query_content_type=%r "
            "query_body_length=%s module_count=%s course_count=%s success=%s",
            resp.status_code,
            query_resp.status_code,
            query_resp.headers.get("content-type", ""),
            len(query_resp.text or ""),
            len(parsed.get("modules") or []),
            sum(len(module.get("courses") or []) for module in parsed.get("modules") or [])
            + len(parsed.get("improvement_courses") or []),
            parsed.get("success"),
        )

        return parsed


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
    captured_at = datetime.now(timezone.utc).isoformat()
    structure_signature = _academic_structure_signature(soup)

    all_gpa_labels = [
        "当前所有课程平均学分绩点",
        "所有课程平均学分绩点",
        "当前所有课程GPA",
    ]
    degree_gpa_labels = [
        "当前学位课程平均学分绩点",
        "当前学位课平均学分绩点",
        "学位课程平均学分绩点",
        "学位课平均学分绩点",
        "当前学位课程GPA",
        "当前学位课GPA",
        "学位课GPA",
    ]

    if _looks_like_login_page(html) or not plain_text:
        return _academic_structure_failure(captured_at, structure_signature)

    all_gpa = _extract_gpa_value_any(plain_text, all_gpa_labels)
    degree_gpa = _extract_gpa_value_any(plain_text, degree_gpa_labels)
    total_part, degree_part = _split_academic_summary(plain_text)

    counts = {
        "total_courses": _find_int_optional(
            total_part, r"计划总课程(?:为)?\s*(\d+)\s*门"
        ),
        "passed_courses": _find_int_optional(
            total_part, r"(?<!未)通过\s*(\d+)\s*门"
        ),
        "failed_courses": _find_int_optional(total_part, r"未通过\s*(\d+)\s*门"),
        "not_started_courses": _find_int_optional(total_part, r"未修\s*(\d+)\s*门"),
        "in_progress_courses": _find_int_optional(total_part, r"在读\s*(\d+)\s*门"),
        "degree_total_courses": _find_int_optional(
            degree_part, r"计划学位课程(?:为)?\s*(\d+)\s*门"
        ),
        "degree_passed_courses": _find_int_optional(
            degree_part, r"(?<!未)通过\s*(\d+)\s*门"
        ),
        "degree_failed_courses": _find_int_optional(
            degree_part, r"未通过\s*(\d+)\s*门"
        ),
        "degree_not_started_courses": _find_int_optional(
            degree_part, r"未修\s*(\d+)\s*门"
        ),
        "degree_in_progress_courses": _find_int_optional(
            degree_part, r"在读\s*(\d+)\s*门"
        ),
    }

    compact_text = _compact_text(plain_text)
    has_all_gpa_anchor = any(_compact_text(label) in compact_text for label in all_gpa_labels)
    has_degree_gpa_anchor = any(
        _compact_text(label) in compact_text for label in degree_gpa_labels
    )
    has_count_anchor = "计划总课程" in compact_text and any(
        label in compact_text for label in ("通过", "未通过", "未修", "在读")
    )
    has_parsed_gpa = all_gpa is not None or degree_gpa is not None
    has_complete_counts = all(value is not None for value in counts.values())

    if not (
        has_all_gpa_anchor
        and has_degree_gpa_anchor
        and has_count_anchor
        and has_parsed_gpa
        and has_complete_counts
    ):
        return _academic_structure_failure(captured_at, structure_signature)

    courses, courses_status = _parse_academic_courses(soup)

    return {
        "success": True,
        "source": "academic_situation",
        "source_kind": "official_academic_situation",
        "source_url": ACADEMIC_SITUATION_SOURCE_PATH,
        "parser_version": ACADEMIC_SITUATION_PARSER_VERSION,
        "captured_at": captured_at,
        "official_updated_at": None,
        "structure_signature": structure_signature,
        "all_gpa": all_gpa,
        "degree_gpa": degree_gpa,
        **counts,
        "courses_status": courses_status,
        "courses": courses,
        "error_code": None,
        "message": None,
    }


def _academic_structure_failure(captured_at: str, structure_signature: str) -> dict:
    return {
        "success": False,
        "source": "academic_situation",
        "source_kind": "official_academic_situation",
        "source_url": ACADEMIC_SITUATION_SOURCE_PATH,
        "parser_version": ACADEMIC_SITUATION_PARSER_VERSION,
        "captured_at": captured_at,
        "official_updated_at": None,
        "structure_signature": structure_signature,
        "all_gpa": None,
        "degree_gpa": None,
        "total_courses": None,
        "passed_courses": None,
        "failed_courses": None,
        "not_started_courses": None,
        "in_progress_courses": None,
        "degree_total_courses": None,
        "degree_passed_courses": None,
        "degree_failed_courses": None,
        "degree_not_started_courses": None,
        "degree_in_progress_courses": None,
        "courses_status": "parse_failed",
        "courses": [],
        "error_code": "ACADEMIC_SITUATION_STRUCTURE_CHANGED",
        "message": "学业情况页面结构发生变化",
    }


def _academic_structure_signature(soup: BeautifulSoup) -> str:
    tag_sequence = [tag.name for tag in soup.find_all(True, limit=300)]
    table_headers = [
        _normalize_text(cell.get_text(" ", strip=True))
        for cell in soup.select("table th")
        if _normalize_text(cell.get_text(" ", strip=True))
    ]
    script_sources = [
        str(script.get("src") or "").split("?", 1)[0]
        for script in soup.select("script[src]")
    ]
    parts = [
        f"forms:{len(soup.select('form'))}",
        f"tables:{len(soup.select('table'))}",
        f"scripts:{len(soup.select('script'))}",
        f"iframes:{len(soup.select('iframe'))}",
        "tags:" + ",".join(tag_sequence),
        "headers:" + "|".join(table_headers),
        "scriptsrc:" + "|".join(script_sources),
    ]
    return hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()


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


def _find_int_optional(text: str, pattern: str) -> Optional[int]:
    match = re.search(pattern, text)
    if not match:
        return None
    try:
        return int(match.group(1))
    except (TypeError, ValueError):
        return None


def _parse_academic_courses(soup: BeautifulSoup) -> Tuple[List[dict], str]:
    for table in soup.select("table"):
        header_index = _academic_course_header_index(table)
        if header_index < 0:
            continue
        parsed = _parse_academic_course_table(table)
        if parsed:
            return parsed, "available"
        data_rows = table.select("tr")[header_index + 1:]
        has_data = any(
            _normalize_text(row.get_text(" ", strip=True)) for row in data_rows
        )
        return [], "parse_failed" if has_data else "empty"

    if _has_dynamic_course_source(soup):
        return [], "dynamic_source_unresolved"
    return [], "not_present"


def _academic_course_header_index(table) -> int:
    for index, tr in enumerate(table.select("tr")):
        cells = [_normalize_text(cell.get_text(" ", strip=True)) for cell in tr.select("th,td")]
        if "课程名称" in cells and "最大成绩" in cells and "修读状态" in cells:
            return index
    return -1


def _has_dynamic_course_source(soup: BeautifulSoup) -> bool:
    if soup.select("iframe, [data-url], [data-ajax], [data-source]"):
        return True
    script_text = " ".join(script.get_text(" ", strip=True) for script in soup.select("script"))
    return any(
        marker in script_text
        for marker in ("$.ajax", "fetch(", ".DataTable(", ".load(")
    )


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


# ============== 学分要求解析 ==============

def _extract_credit_requirement_query(
    soup: BeautifulSoup,
) -> Optional[Tuple[Dict[str, str], dict]]:
    """读取页面已选学院、年级和专业，复现前端 AJAX 查询参数。"""
    form = soup.select_one("form#searchForm")
    if form is None:
        return None

    field_context = {
        "jg_id": "college_name",
        "njdm_id": "enrollment_grade",
        "zyh_id": "major_name",
    }
    payload: Dict[str, str] = {}
    context: dict = {}
    for field, context_key in field_context.items():
        select_node = form.select_one(f"select[name='{field}']")
        if select_node is None:
            return None
        option = select_node.select_one("option[selected]")
        if option is None:
            # 个人培养方案不能猜测下拉框的首项；缺少当前选项即视为协议变更。
            return None
        value = str(option.get("value") or "").strip() if option else ""
        if not value:
            return None
        payload[field] = value
        label = _normalize_text(option.get_text(" ", strip=True)) if option else ""
        if label:
            context[context_key] = label

    return payload, context


def parse_credit_requirement_json(
    payload: Any,
    *,
    query_context: Optional[dict] = None,
) -> dict:
    """解析学分要求 AJAX 接口返回的节点与课程 JSON 树。"""
    captured_at = datetime.now(timezone.utc).isoformat()
    structure_signature = _credit_req_json_structure_signature(payload)
    if payload is None or payload == []:
        return {
            "success": True,
            "source_kind": "official_credit_requirement",
            "source_url": ACADEMIC_REQUIREMENT_SOURCE_PATH,
            "parser_version": ACADEMIC_REQUIREMENT_PARSER_VERSION,
            "captured_at": captured_at,
            "structure_signature": structure_signature,
            "query_context": query_context or {},
            "status": "empty",
            "modules": [],
            "improvement_courses": [],
            "error_code": None,
            "message": None,
        }
    if not isinstance(payload, list):
        return _credit_req_failure(
            "parse_failed",
            captured_at,
            structure_signature,
            error_code="CREDIT_REQUIREMENT_PARSE_FAILED",
            message="学分要求数据结构发生变化，请稍后重试",
        )

    modules: list[dict] = []
    improvement_courses: list[dict] = []

    def visit(raw_node: Any, parent_module: Optional[dict] = None) -> None:
        if not isinstance(raw_node, dict):
            return
        module = _parse_credit_requirement_json_module(raw_node)
        next_parent = parent_module
        if module is not None:
            if module["module_type"] == "improvement":
                improvement_courses.extend(module["courses"])
            elif _is_credit_requirement_expression(module["name"]):
                # “至少修 X 学分”是选修模块下的规则分支，不是独立培养模块。
                # 保留它的课程到最近的真实模块，避免把规则文本误当成首页标题。
                if parent_module is not None:
                    _merge_credit_requirement_rule(parent_module, module)
                else:
                    # 没有父节点时不能丢弃官方数据，保留原节点作为降级展示。
                    modules.append(module)
            else:
                modules.append(module)
                next_parent = module
        children = raw_node.get("xfyqjdList")
        if isinstance(children, list):
            for child in children:
                visit(child, next_parent)

    for node in payload:
        visit(node)

    if not modules and not improvement_courses:
        return _credit_req_failure(
            "parse_failed",
            captured_at,
            structure_signature,
            error_code="CREDIT_REQUIREMENT_PARSE_FAILED",
            message="学分要求数据无法解析，请稍后重试",
        )

    return {
        "success": True,
        "source_kind": "official_credit_requirement",
        "source_url": ACADEMIC_REQUIREMENT_SOURCE_PATH,
        "parser_version": ACADEMIC_REQUIREMENT_PARSER_VERSION,
        "captured_at": captured_at,
        "structure_signature": structure_signature,
        "query_context": query_context or {},
        "status": "available",
        "modules": modules,
        "improvement_courses": improvement_courses,
        "error_code": None,
        "message": None,
    }


def _is_credit_requirement_expression(name: str) -> bool:
    """判断节点名称是否只是选课规则表达式，而非培养模块名称。"""
    normalized = re.sub(r"\s+", "", name)
    return bool(
        re.fullmatch(
            r"至少修\d+(?:\.\d+)?学分(?:[（(][^）)]*[)）])?",
            normalized,
        )
        or re.fullmatch(
            r"至少修\d+门(?:[（(][^）)]*[)）])?",
            normalized,
        )
    )


def _merge_credit_requirement_rule(parent: dict, rule: dict) -> None:
    """将规则节点的课程并入父模块，且不重复课程明细。"""
    parent_courses = parent.setdefault("courses", [])
    existing_keys = {
        (
            course.get("course_code"),
            course.get("course_name"),
            course.get("actual_year"),
            course.get("actual_semester"),
        )
        for course in parent_courses
    }
    added = 0.0
    for course in rule.get("courses", []):
        key = (
            course.get("course_code"),
            course.get("course_name"),
            course.get("actual_year"),
            course.get("actual_semester"),
        )
        if key in existing_keys:
            continue
        existing_keys.add(key)
        parent_courses.append(course)
        if course.get("completed") is True:
            added += _to_float(course.get("credits"))

    if added:
        parent["earned_credits"] = max(
            _to_float(parent.get("earned_credits")),
            _to_float(parent.get("earned_credits")) + added,
        )
    parent["completed_course_count"] = sum(
        course.get("completed") is True for course in parent_courses
    )
    required_credits = parent.get("required_credits")
    required_count = parent.get("required_course_count")
    if required_credits is None and required_count is None:
        parent["status"] = "unknown"
    elif (
        (required_credits is None or parent["earned_credits"] >= required_credits)
        and (required_count is None or parent["completed_course_count"] >= required_count)
    ):
        parent["status"] = "completed"
    elif parent["earned_credits"] > 0 or parent["completed_course_count"] > 0:
        parent["status"] = "in_progress"
    else:
        parent["status"] = "shortfall"


def _parse_credit_requirement_json_module(raw: dict) -> Optional[dict]:
    name = _empty_to_none_text(raw.get("xfyqjdmc"))
    if not name:
        return None

    raw_courses = raw.get("kcList")
    courses = (
        [
            course
            for item in raw_courses
            if (course := _parse_credit_requirement_json_course(item)) is not None
        ]
        if isinstance(raw_courses, list)
        else []
    )
    required_credits = _to_nullable_float(raw.get("yqzdxf"))
    required_course_count = _to_nullable_int(raw.get("kczdms"))
    earned_credits = sum(_to_float(item.get("yxxf")) for item in raw_courses or [] if isinstance(item, dict))
    completed_course_count = sum(course.get("completed") is True for course in courses)
    is_improvement = "提高课程" in name

    credit_satisfied = (
        required_credits is None or earned_credits >= required_credits
    )
    count_satisfied = (
        required_course_count is None
        or completed_course_count >= required_course_count
    )
    if required_credits is None and required_course_count is None:
        status = "unknown"
    elif credit_satisfied and count_satisfied:
        status = "completed"
    elif earned_credits > 0 or completed_course_count > 0:
        status = "in_progress"
    else:
        status = "shortfall"

    return {
        "id": str(raw.get("xfyqjd_id") or _module_id_from_name(name)),
        "name": name,
        "module_type": "improvement" if is_improvement else _infer_module_type(name),
        "required_credits": required_credits,
        "required_course_count": required_course_count,
        "earned_credits": earned_credits,
        "completed_course_count": completed_course_count,
        "status": status,
        "is_optional": _is_optional_module(name),
        "courses": courses,
    }


def _parse_credit_requirement_json_course(raw: Any) -> Optional[dict]:
    if not isinstance(raw, dict):
        return None
    course_name = _empty_to_none_text(raw.get("kcmc"))
    if not course_name:
        return None

    earned_credits = _to_float(raw.get("yxxf"))
    numeric_grade = _to_nullable_float(raw.get("bfzcj"))
    grade = _empty_to_none_text(raw.get("cj"))
    has_actual_term = bool(
        _empty_to_none_text(raw.get("xnmc"))
        or _empty_to_none_text(raw.get("xqmc"))
    )
    if grade == "未开放":
        raw_status, completed = "未开放", False
    elif str(raw.get("tdbj") or "") == "1":
        raw_status, completed = "课程替代", True
    elif earned_credits > 0:
        raw_status, completed = "通过", True
    elif numeric_grade is not None:
        raw_status = "通过" if numeric_grade >= 60 else "不及格"
        completed = numeric_grade >= 60
    elif has_actual_term:
        raw_status, completed = "已选", None
    else:
        raw_status, completed = "未选", False

    return {
        "course_code": str(raw.get("kch") or ""),
        "course_name": course_name,
        "credits": _to_float(raw.get("xf")),
        "suggested_year": _empty_to_none_text(raw.get("jyxdxnmc")),
        "suggested_semester": _empty_to_none_text(raw.get("jyxdxqmc")),
        "actual_year": _empty_to_none_text(raw.get("xnmc")),
        "actual_semester": _empty_to_none_text(raw.get("xqmc")),
        "course_nature": _empty_to_none_text(raw.get("xbx")),
        "grade": grade,
        "raw_status": raw_status,
        "remark": _empty_to_none_text(raw.get("bz")),
        "completed": completed,
    }


def _to_nullable_int(value: Any) -> Optional[int]:
    number = _to_nullable_float(value)
    return int(number) if number is not None else None


def _credit_req_json_structure_signature(payload: Any) -> str:
    """仅基于类型和字段名生成签名，避免业务值进入日志或缓存元数据。"""
    def shape(value: Any) -> Any:
        if isinstance(value, dict):
            return {str(key): shape(child) for key, child in sorted(value.items())}
        if isinstance(value, list):
            return [shape(value[0])] if value else []
        return type(value).__name__

    encoded = json.dumps(shape(payload), sort_keys=True, ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

def parse_credit_requirement_html(html: str) -> dict:
    """解析官方"学籍预警/学分要求"页面。

    返回标准 JSON 结构，包含模块列表、提高课程和查询上下文。
    """
    soup = BeautifulSoup(html or "", "html.parser")
    plain_text = _normalize_text(soup.get_text(" ", strip=True))
    captured_at = datetime.now(timezone.utc).isoformat()
    structure_signature = _credit_req_structure_signature(soup, plain_text)

    if _looks_like_login_page(html) or not plain_text:
        return _credit_req_failure("empty", captured_at, structure_signature)

    # 提取查询上下文 — 学院、年级、专业
    query_context = _extract_credit_req_query_context(plain_text)

    # 解析模块
    modules, improvement_courses = _parse_credit_req_modules(soup, plain_text)

    # Extract table courses for the gate check
    table_courses = _extract_all_courses_from_tables(soup)

    if not modules and not improvement_courses:
        # When improvement courses are the only content, construct a minimal valid result
        if table_courses:
            imp_pos = plain_text.find("提高课程")
            if imp_pos >= 0:
                improvement_courses = [
                    c for c in table_courses
                    if plain_text.find(c.get("course_name", "")) > imp_pos
                ]
                if improvement_courses:
                    return {
                        "success": True,
                        "source_kind": "official_credit_requirement",
                        "source_url": ACADEMIC_REQUIREMENT_SOURCE_PATH,
                        "parser_version": ACADEMIC_REQUIREMENT_PARSER_VERSION,
                        "captured_at": captured_at,
                        "structure_signature": structure_signature,
                        "query_context": query_context,
                        "status": "available",
                        "modules": [],
                        "improvement_courses": improvement_courses,
                    }

        # 尝试检测是否为动态加载页面
        if _has_dynamic_course_source(soup):
            return _credit_req_failure(
                "dynamic_source_unresolved", captured_at, structure_signature,
            )
        # 检查是否有模块标题但解析失败
        if _has_credit_req_headers(plain_text):
            return _credit_req_failure(
                "parse_failed",
                captured_at,
                structure_signature,
                error_code="CREDIT_REQUIREMENT_PARSE_FAILED",
                message="学分要求页面结构发生变化",
                extra={
                    "page_title": _page_title_from_soup(soup),
                    "modules_detected": len(modules),
                    "courses_detected": sum(len(m.get("courses", [])) for m in modules),
                },
            )
        return _credit_req_failure(
            "empty", captured_at, structure_signature,
        )

    return {
        "success": True,
        "source_kind": "official_credit_requirement",
        "source_url": ACADEMIC_REQUIREMENT_SOURCE_PATH,
        "parser_version": ACADEMIC_REQUIREMENT_PARSER_VERSION,
        "captured_at": captured_at,
        "structure_signature": structure_signature,
        "query_context": query_context,
        "status": "available",
        "modules": modules,
        "improvement_courses": improvement_courses,
    }


def _page_title_from_soup(soup: BeautifulSoup) -> str:
    return soup.title.get_text(strip=True) if soup.title else ""


def _credit_req_failure(
    status: str,
    captured_at: str,
    structure_signature: str,
    error_code: str = "CREDIT_REQUIREMENT_PARSE_FAILED",
    message: str = "学分要求解析失败",
    extra: dict | None = None,
) -> dict:
    result = {
        "success": False,
        "source_kind": "official_credit_requirement",
        "source_url": ACADEMIC_REQUIREMENT_SOURCE_PATH,
        "parser_version": ACADEMIC_REQUIREMENT_PARSER_VERSION,
        "captured_at": captured_at,
        "structure_signature": structure_signature,
        "query_context": {},
        "status": status,
        "modules": [],
        "improvement_courses": [],
        "error_code": error_code,
        "message": message,
    }
    if extra:
        result.update(extra)
    return result


def _credit_req_structure_signature(soup: BeautifulSoup, plain_text: str) -> str:
    tag_sequence = [tag.name for tag in soup.find_all(True, limit=200)]
    table_count = len(soup.select("table"))
    form_count = len(soup.select("form"))
    # Count module-like headers in text
    module_header_count = len(re.findall(r"要求最低\s*\d+", plain_text))
    parts = [
        f"tables:{table_count}",
        f"forms:{form_count}",
        f"module_headers:{module_header_count}",
        "tags:" + ",".join(tag_sequence),
    ]
    return hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()


def _has_credit_req_headers(text: str) -> bool:
    """检测页面是否包含学分要求相关的标题文本。"""
    return bool(
        re.search(r"学籍预警|学分要求|模块|要求最低|提高课程|最低学分", text)
    )


def _extract_credit_req_query_context(text: str) -> dict:
    """从页面文本提取学院、年级、专业等查询上下文。"""
    context = {}
    # 学院
    m = re.search(r"学院[：:]\s*(\S+)", text)
    if m:
        context["college_name"] = m.group(1).rstrip("；;")
    # 年级
    m = re.search(r"年级[：:]\s*(\d{4})", text)
    if m:
        context["enrollment_grade"] = m.group(1)
    # 专业
    m = re.search(r"专业[：:]\s*([^\s；;]+)", text)
    if m:
        context["major_name"] = m.group(1)
    return context


def _parse_credit_req_modules(
    soup: BeautifulSoup, plain_text: str
) -> tuple[list[dict], list[dict]]:
    """From the page, parse credit requirement modules and improvement courses.

    Uses a combined strategy: first try text-based segmentation (most reliable),
    then try to attach course data from HTML tables to the matching modules.
    """
    # Strategy 1: text-based segmentation for module discovery
    modules_from_text, improvement_from_text = _parse_credit_req_from_text(
        soup, plain_text
    )

    if not modules_from_text and not improvement_from_text:
        # Strategy 2: table-based parsing as fallback
        return _parse_credit_req_tables(soup)

    # Try to enrich text-based modules with course data from HTML tables
    all_table_courses = _extract_all_courses_from_tables(soup)
    if all_table_courses:
        # Table-parsed courses are more reliable than text-parsed ones.
        # Clear text-parsed courses and use only table courses.
        for module in modules_from_text:
            module["courses"] = []
        # Also clear improvement list
        improvement_from_text.clear()
        _assign_courses_to_modules(modules_from_text, all_table_courses, plain_text)
        _assign_improvement_courses(improvement_from_text, all_table_courses, plain_text)

    return modules_from_text, improvement_from_text


def _extract_all_courses_from_tables(soup: BeautifulSoup) -> list[dict]:
    """Extract all course rows from all tables in the page."""
    all_courses = []
    field_map = {
        "课程号": "course_code",
        "课程名称": "course_name",
        "课程学分": "credits",
        "学分": "credits",
        "建议修读学年": "suggested_year",
        "建议修读学期": "suggested_semester",
        "实际修读学年": "actual_year",
        "实际修读学期": "actual_semester",
        "选必修": "course_nature",
        "课程性质": "course_nature",
        "成绩": "grade",
        "修读状态": "raw_status",
        "状态": "raw_status",
        "备注": "remark",
    }

    for table in soup.select("table"):
        headers = _detect_course_table_headers(table)
        if not headers or "course_name" not in headers.values():
            continue

        courses = _parse_requirement_course_rows(table, headers)
        all_courses.extend(courses)

    return all_courses


def _assign_courses_to_modules(
    modules: list[dict], all_courses: list[dict], plain_text: str
) -> None:
    """Assign course rows to the appropriate module based on text position.

    Courses are assigned to the module whose name appears closest before
    the course's position in the text.
    """
    # Find module text positions
    module_positions = []
    for module in modules:
        pos = plain_text.find(module["name"])
        if pos >= 0:
            module_positions.append((pos, module))

    module_positions.sort(key=lambda x: x[0])

    if not module_positions:
        return

    # Assign each course to the closest preceding module
    for course in all_courses:
        course_name = course.get("course_name", "")
        course_pos = plain_text.find(course_name)

        # Find the last module whose name appears before this course
        assigned = None
        for pos, module in module_positions:
            if pos <= course_pos:
                assigned = module
            else:
                break

        if assigned is not None:
            assigned.setdefault("courses", []).append(course)
            assigned["completed_course_count"] = len(assigned["courses"])


def _assign_improvement_courses(
    improvement_courses: list[dict], all_courses: list[dict], plain_text: str
) -> None:
    """Assign course rows as improvement courses."""
    # Look for "提高课程" marker and assign courses after it
    imp_pos = plain_text.find("提高课程")
    if imp_pos < 0:
        return

    for course in all_courses:
        course_name = course.get("course_name", "")
        course_pos = plain_text.find(course_name)
        if course_pos > imp_pos:
            improvement_courses.append(course)


def _parse_credit_req_tables(
    soup: BeautifulSoup,
) -> tuple[list[dict], list[dict]]:
    """通过 HTML 表格结构解析学分要求。

    学籍预警页面通常包含：
    - 一个或多个包含模块信息的表格（模块名、要求学分、已得学分等）
    - 每个模块后面可能紧跟课程明细表格
    """
    modules = []
    improvement_courses = []
    all_improvement_courses = []

    tables = soup.select("table")
    current_module = None

    for table in tables:
        # 检查该表格是否是模块标题行
        module_from_table = _try_extract_module_header_from_table(table)
        if module_from_table:
            if current_module and current_module.get("courses"):
                if current_module.get("module_type") == "improvement":
                    all_improvement_courses.extend(current_module["courses"])
                else:
                    modules.append(current_module)
            current_module = module_from_table
            continue

        # 检查是否是课程表格
        if current_module:
            courses = _parse_credit_req_course_table(table)
            if courses:
                current_module.setdefault("courses", []).extend(courses)
                continue

            # 可能同一个模块的头部信息分布在不同行
            extra_header = _try_extract_module_extra_header(table)
            if extra_header:
                current_module.update(extra_header)
                continue

    # 保存最后一个模块
    if current_module:
        if current_module.get("module_type") == "improvement":
            all_improvement_courses.extend(current_module.get("courses", []))
        else:
            modules.append(current_module)

    return modules, all_improvement_courses


def _try_extract_module_header_from_table(table) -> dict | None:
    """尝试从表格行中提取模块标题信息。

    模块头部通常包含：模块名称、要求最低X学分、已获得X学分等。
    """
    all_text = _normalize_text(table.get_text(" ", strip=True))
    if not all_text:
        return None

    # 匹配模块名称（常见格式）
    module_name = _extract_module_name(all_text)
    if not module_name:
        return None

    # 判断是否为提高课程
    is_improvement = "提高课程" in module_name

    module = {
        "id": _module_id_from_name(module_name),
        "name": module_name,
        "module_type": "improvement" if is_improvement else _infer_module_type(module_name),
        "required_credits": _extract_required_credits(all_text),
        "required_course_count": _extract_required_course_count(all_text),
        "earned_credits": _extract_earned_credits(all_text),
        "completed_course_count": 0,
        "status": "unknown",
        "is_optional": _is_optional_module(module_name),
        "courses": [],
    }

    # 初步计算状态（后续会根据课程数量调整）
    req = module["required_credits"]
    earned = module["earned_credits"]
    if req is None:
        module["status"] = "unknown"
    elif earned >= req:
        module["status"] = "completed"
    elif earned > 0:
        module["status"] = "in_progress"
    else:
        module["status"] = "shortfall"

    return module


def _try_extract_module_extra_header(table) -> dict | None:
    """提取分散在表格中的额外模块头部信息。"""
    all_text = _normalize_text(table.get_text(" ", strip=True))
    result = {}
    req_credits = _extract_required_credits(all_text)
    if req_credits is not None:
        result["required_credits"] = req_credits
    earned = _extract_earned_credits(all_text)
    if earned is not None:
        result["earned_credits"] = earned
    req_count = _extract_required_course_count(all_text)
    if req_count is not None:
        result["required_course_count"] = req_count
    return result if result else None


def _parse_credit_req_course_table(table) -> list[dict]:
    """尝试将表格解析为课程列表。"""
    headers = _detect_course_table_headers(table)
    if not headers or "course_name" not in headers.values():
        return []

    return _parse_requirement_course_rows(table, headers)


def _detect_course_table_headers(table) -> dict[str, str]:
    """检测课程表格的列映射。

    返回 {列索引: 字段名} 的字典。
    """
    field_map = {
        "课程号": "course_code",
        "课程名称": "course_name",
        "课程学分": "credits",
        "学分": "credits",
        "建议修读学年": "suggested_year",
        "建议修读学期": "suggested_semester",
        "实际修读学年": "actual_year",
        "实际修读学期": "actual_semester",
        "选必修": "course_nature",
        "课程性质": "course_nature",
        "成绩": "grade",
        "修读状态": "raw_status",
        "状态": "raw_status",
        "备注": "remark",
    }

    for tr in table.select("tr"):
        cells = [
            _normalize_text(cell.get_text(" ", strip=True))
            for cell in tr.select("th,td")
        ]
        if not cells:
            continue

        header_map = {}
        for idx, cell in enumerate(cells):
            if cell in field_map:
                header_map[idx] = field_map[cell]

        if "course_name" in header_map.values():
            return header_map

    return {}


def _parse_requirement_course_rows(table, header_map: dict[str, str]) -> list[dict]:
    """解析课程行数据。"""
    courses = []
    # 找到表头行索引
    rows = table.select("tr")
    header_row_idx = -1
    for idx, tr in enumerate(rows):
        cells = [
            _normalize_text(cell.get_text(" ", strip=True))
            for cell in tr.select("th,td")
        ]
        field_values = {header_map.get(i): c for i, c in enumerate(cells) if i in header_map}
        if "course_name" in field_values.values() and any(
            k in field_values for k in ("credits", "grade", "course_code")
        ):
            header_row_idx = idx
            break

    if header_row_idx < 0:
        # 尝试：可能不是标准表头，但数据行包含课程信息
        header_row_idx = 0

    for tr in rows[header_row_idx + 1:]:
        cells = [
            _normalize_text(td.get_text(" ", strip=True))
            for td in tr.select("td")
        ]
        if not any(cells):
            continue

        row = {}
        for idx, cell in enumerate(cells):
            field = header_map.get(idx)
            if field:
                row[field] = _empty_to_none_text(cell)

        course_name = row.get("course_name") or ""
        if not course_name:
            continue

        # 如果表头中没有 course_name 但有其他字段，尝试从第一个有意义的列提取
        course = {
            "course_code": row.get("course_code") or "",
            "course_name": course_name,
            "credits": _to_float(row.get("credits")),
            "suggested_year": _text_or_none(row.get("suggested_year")),
            "suggested_semester": _text_or_none(row.get("suggested_semester")),
            "actual_year": _text_or_none(row.get("actual_year")),
            "actual_semester": _text_or_none(row.get("actual_semester")),
            "course_nature": _text_or_none(row.get("course_nature")),
            "grade": _text_or_none(row.get("grade")),
            "raw_status": _text_or_none(row.get("raw_status")),
            "remark": _text_or_none(row.get("remark")),
            "completed": _parse_completed_status(row),
        }
        courses.append(course)

    return courses


def _parse_completed_status(row: dict) -> bool | None:
    """根据课程行数据判断是否已完成。"""
    status = (row.get("raw_status") or "").strip()
    grade = (row.get("grade") or "").strip()

    if status in ("已修读", "已完成", "通过", "已通过"):
        return True
    if status in ("未修读", "未通过", "未修"):
        return False

    if grade:
        if re.fullmatch(r"\d+(?:\.\d+)?", grade):
            return float(grade) >= 60
        if re.fullmatch(r"优秀|良好|中等|及格|合格", grade):
            return True
        if re.fullmatch(r"不及格|不合格", grade):
            return False

    return None


def _text_or_none(value: str | None) -> str | None:
    if value is None:
        return None
    text = value.strip()
    return text if text else None


def _extract_module_name(text: str) -> str | None:
    """提取模块名称。匹配已知的模块命名模式。"""
    # 精确匹配已知模块名称模式
    patterns = [
        r"(通识教育理论必修)",
        r"(美育模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(自然模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(体育模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(人文模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(思政模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(外语模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(计算机模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(其他模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(学科基础[^，,。.\s]*?(?:模块)?(?:[（(][^)）]+[)）])?)",
        r"(专业模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(实践模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(创新模块[^，,。.\s]*?(?:[（(][^)）]+[)）])?)",
        r"(提高课程)",
    ]
    for pattern in patterns:
        m = re.search(pattern, text)
        if m:
            name = m.group(1).strip()
            if 2 <= len(name) <= 40:
                return name
    return None


def _module_id_from_name(name: str) -> str:
    """从模块名称生成稳定的 ID。"""
    # 移除括号内容、标点、空格
    clean = re.sub(r"[（()）\s]", "", name)
    # 简单拼音映射
    keyword_map = {
        "通识教育理论必修": "general_theory_required",
        "美育": "aesthetic",
        "自然": "nature",
        "体育": "sports",
        "人文": "humanities",
        "思政": "ideology",
        "外语": "foreign_lang",
        "计算机": "computer",
        "其他": "other",
        "学科基础": "discipline_basis",
        "专业": "major",
        "实践": "practice",
        "创新": "innovation",
        "公共": "public",
        "提高课程": "improvement",
    }
    for cn, en in keyword_map.items():
        if cn in clean:
            return en
    # 降级：使用清理后名称的 hash
    return hashlib.md5(clean.encode()).hexdigest()[:12]


def _infer_module_type(name: str) -> str:
    """根据模块名称推断模块类型。"""
    if "必修" in name and ("限选" in name or "选修" in name):
        return "limited_elective"
    if "选修" in name or "限选" in name:
        return "elective"
    return "required"


def _is_optional_module(name: str) -> bool:
    """判断模块是否为可选模块。"""
    return any(token in name for token in ("选修", "限选", "选一")) and "必修" not in name


def _extract_required_credits(text: str) -> float | None:
    """从文本中提取最低要求学分。"""
    m = re.search(r"要求最低\s*(\d+(?:\.\d+)?)\s*学分", text)
    if m:
        return float(m.group(1))
    m = re.search(r"最低\s*(\d+(?:\.\d+)?)\s*学分", text)
    if m:
        return float(m.group(1))
    m = re.search(r"要求\s*(\d+(?:\.\d+)?)\s*学分", text)
    if m:
        return float(m.group(1))
    return None


def _extract_required_course_count(text: str) -> int | None:
    """从文本中提取最低要求门数。"""
    m = re.search(r"要求最低\s*(\d+)\s*门", text)
    if m:
        return int(m.group(1))
    m = re.search(r"最低\s*(\d+)\s*门", text)
    if m:
        return int(m.group(1))
    return None


def _extract_earned_credits(text: str) -> float:
    """从文本中提取已获得学分。"""
    m = re.search(r"已获得\s*(\d+(?:\.\d+)?)\s*学分", text)
    if m:
        return float(m.group(1))
    m = re.search(r"获得\s*(\d+(?:\.\d+)?)\s*学分", text)
    if m:
        return float(m.group(1))
    return 0.0


def _parse_credit_req_from_text(
    soup: BeautifulSoup, plain_text: str
) -> tuple[list[dict], list[dict]]:
    """Parse credit requirements from plain text and HTML regions.

    This is the primary parsing strategy. Module names are detected via
    known patterns, and segment boundaries are computed with a robust
    delimiter heuristic.
    """
    modules = []
    improvement_courses = []

    # Find all module header positions using known patterns
    module_patterns = [
        r"(通识教育理论必修)",
        r"(美育模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(自然模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(体育模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(人文模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(思政模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(外语模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(计算机模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(其他模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(学科基础[^\s，,。.]*(?:模块)?(?:[（(][^)）]+[)）])?)",
        r"(专业模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(实践模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(创新模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"(三选一模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)",
        r"([A-Za-z一-鿿][^\s，,。.]{0,12}模块[^\s，,。.]*?(?:[（(][^)）]+[)）])?)",
        r"(提高课程)",
    ]

    segments = []
    for pattern in module_patterns:
        for m in re.finditer(pattern, plain_text):
            name = m.group(0).strip()
            # Only accept reasonable-length names
            if 2 <= len(name) <= 40:
                segments.append((m.start(), name))

    # Remove duplicates at same position (keep longest name)
    segments.sort(key=lambda x: (x[0], -len(x[1])))
    deduped = []
    seen_positions = set()
    for pos, name in segments:
        if pos not in seen_positions:
            # Also deduplicate nearby positions (within 5 chars)
            if not any(abs(pos - p) < 5 for p in seen_positions):
                deduped.append((pos, name))
                seen_positions.add(pos)

    segments = deduped

    for i, (start, name) in enumerate(segments):
        end = segments[i + 1][0] if i + 1 < len(segments) else len(plain_text)
        segment_text = plain_text[start:end]

        is_improvement = "提高课程" in name

        module = {
            "id": _module_id_from_name(name),
            "name": name,
            "module_type": "improvement" if is_improvement else _infer_module_type(name),
            "required_credits": _extract_required_credits(segment_text),
            "required_course_count": _extract_required_course_count(segment_text),
            "earned_credits": _extract_earned_credits(segment_text),
            "completed_course_count": 0,
            "status": "unknown",
            "is_optional": _is_optional_module(name),
            "courses": _parse_courses_from_text_segment(segment_text),
        }

        # 计算状态
        req = module["required_credits"]
        earned = module["earned_credits"]
        module["completed_course_count"] = len(module["courses"])
        if req is None:
            module["status"] = "unknown"
        elif earned >= req:
            module["status"] = "completed"
        elif earned > 0:
            module["status"] = "in_progress"
        else:
            module["status"] = "shortfall"

        if is_improvement:
            improvement_courses.extend(module["courses"])
            # Don't add improvement module to modules list
        else:
            modules.append(module)

    return modules, improvement_courses


def _parse_courses_from_text_segment(text: str) -> list[dict]:
    """Parse course list from a text segment.

    Matches lines like: '215400043 课程名 2.0 学分 ...'
    Only matches when '学分' keyword is present after the numeric credit value.
    """
    courses = []
    # Match pattern: course_code + course_name + credits + '学分'
    # The '学分' keyword must be present to avoid false matches on random numbers
    course_pattern = re.compile(
        r"([A-Za-z0-9]{5,})\s+"
        r"(\S.{2,40}?)\s+"
        r"(\d+(?:\.\d+)?)\s*学分"
    )
    for m in course_pattern.finditer(text):
        course_code = m.group(1).strip()
        course_name = m.group(2).strip()
        credits = float(m.group(3))

        # Skip obviously wrong course names (containing keywords)
        if any(kw in course_name for kw in ("要求", "已获得", "最低", "模块", "课程")):
            continue
        if len(course_name) < 2 or len(course_name) > 40:
            continue

        # 在匹配后查找学年学期和成绩
        rest = text[m.end():m.end() + 120]
        term_info = _extract_term_from_text(rest)
        grade = _extract_grade_from_text(rest)
        status = _extract_status_from_text(rest)

        courses.append({
            "course_code": course_code,
            "course_name": course_name,
            "credits": credits,
            "suggested_year": None,
            "suggested_semester": None,
            "actual_year": term_info.get("year"),
            "actual_semester": term_info.get("semester"),
            "course_nature": None,
            "grade": grade,
            "raw_status": status,
            "remark": None,
            "completed": _parse_completed_status_from_text(status, grade),
        })

    return courses


def _extract_term_from_text(text: str) -> dict:
    """从文本中提取学年学期信息。"""
    m = re.search(r"(\d{4}-\d{4})\s*(第一学期|第二学期)", text)
    if m:
        sem_num = "3" if "第一" in m.group(2) else "12"
        return {"year": m.group(1), "semester": sem_num}
    return {}


def _extract_grade_from_text(text: str) -> str | None:
    """从文本中提取成绩。"""
    # 数字成绩
    m = re.search(r"(?:成绩|分数)[：:]\s*(\d+(?:\.\d+)?)", text)
    if m:
        return m.group(1)
    # 等级成绩
    m = re.search(r"(优秀|良好|中等|及格|合格|不及格|不合格)", text)
    if m:
        return m.group(1)
    # 数字成绩（无前缀）
    m = re.search(r"\b(\d{2,3}(?:\.\d+)?)\s*(?:分|已|$)", text)
    if m:
        return m.group(1)
    return None


def _extract_status_from_text(text: str) -> str | None:
    """从文本中提取修读状态。"""
    m = re.search(r"(已修读|已完成|已通过|未修读|未通过|未修|在读|修读中)", text)
    return m.group(1) if m else None


def _parse_completed_status_from_text(status: str | None, grade: str | None) -> bool | None:
    """综合状态和成绩判断完成情况。"""
    if status in ("已修读", "已完成", "通过", "已通过"):
        return True
    if status in ("未修读", "未通过", "未修"):
        return False
    if grade:
        if re.fullmatch(r"\d+(?:\.\d+)?", grade):
            return float(grade) >= 60
        if re.fullmatch(r"优秀|良好|中等|及格|合格", grade):
            return True
        if re.fullmatch(r"不及格|不合格", grade):
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
