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
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

from config import INDEX_URL, COURSE_URL, GRADE_URL


# ============== 错误定义 ==============

class EduError(Exception):
    """教务错误基类"""
    pass


class CookieLapseError(EduError):
    """Cookie失效"""
    pass


class LoginFailedError(EduError):
    """登录失败"""
    pass


class CourseNotOpenError(EduError):
    """课表未开放"""
    pass


class GradesNotOpenError(EduError):
    """成绩未开放"""
    pass


class NetworkError(EduError):
    """网络错误"""
    pass


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
    time: str  # 节次字符串 "1-2节"
    week_day: str  # 星期几 "1"
    week_str: str  # 周数字符串 "1-16周"


@dataclass
class StudentInfo:
    """学生信息"""
    name: str
    grade: str
    college: str
    major: str


# ============== 爬虫核心类 ==============

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
            verify=False,  # 禁用SSL验证（学校教务系统使用自签名证书）
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
        """获取当前时间戳（毫秒）"""
        return str(int(time.time() * 1000))

    # ============== 认证相关 ==============

    async def get_csrf_token(self) -> str:
        """获取CSRF Token和初始Cookie"""
        if not self.client:
            raise NetworkError("Client not initialized")

        for retry in range(3):
            try:
                resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                if resp.status_code == 200:
                    # 从HTML中提取csrftoken（可能有逗号分隔的两个值，取第一个）
                    match = re.search(r'id="csrftoken" name="csrftoken" value="([^"]+)"', resp.text)
                    if match:
                        csrf = match.group(1)
                        # 如果有逗号，取第一部分
                        if ',' in csrf:
                            csrf = csrf.split(',')[0]
                        return csrf
                    raise LoginFailedError("无法获取CSRF Token")
                elif resp.status_code == 302:
                    # 重定向，获取cookie
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
                    raise NetworkError(f"获取CSRF失败，状态码: {resp.status_code}")
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
            raise NetworkError(f"获取公钥失败，状态码: {resp.status_code}")

        try:
            data = resp.json()
            return PublicKey(modulus=data["modulus"], exponent=data["exponent"])
        except (json.JSONDecodeError, KeyError) as e:
            raise NetworkError(f"解析公钥失败: {e}")

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
            raise LoginFailedError(f"密码加密失败: {e}")

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

        # 登录POST后，可能返回302重定向
        # 即使返回302到login_slogin.html，也可能是登录成功（服务器设置cookie后重定向）
        # 需要跟随重定向，用更新后的cookie继续请求

        # 获取当前有效的JSESSIONID（登录后设置的）
        jsessionid = None
        for name, value in self.client.cookies.items():
            if name == 'JSESSIONID':
                jsessionid = value
                break

        if jsessionid:
            # 用登录后的cookie尝试访问主页
            redirect_resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
            # 如果重定向到主页，说明登录成功
            if redirect_resp.status_code == 302:
                location = redirect_resp.headers.get('location', '')
                if 'index_initMenu' in location or 'index' in location:
                    # 登录成功！构建cookie字符串
                    cookie_parts = []
                    for name, value in self.client.cookies.items():
                        cookie_parts.append(f"{name}={value}")
                    return "; ".join(cookie_parts)

        # 如果上面的方法失败，检查原始响应
        if resp.status_code == 302:
            # 检查是否有alert
            if 'alert' in resp.text:
                error_match = re.search(r'alert\("([^"]+)"\)', resp.text)
                if error_match:
                    raise LoginFailedError(error_match.group(1))
            # 尝试获取JSESSIONID
            set_cookie = resp.headers.get("set-cookie", "")
            if 'JSESSIONID' in set_cookie:
                for part in set_cookie.split(','):
                    if 'JSESSIONID' in part:
                        match = re.search(r'JSESSIONID=([^;]+)', part)
                        if match:
                            return f"JSESSIONID={match.group(1)}"
            raise LoginFailedError("登录失败，请检查账号密码")
        elif resp.status_code == 200:
            error_match = re.search(r'alert\("([^"]+)"\)', resp.text)
            if error_match:
                raise LoginFailedError(error_match.group(1))
            raise LoginFailedError("账号或密码错误")
        else:
            raise NetworkError(f"登录请求失败，状态码: {resp.status_code}")

    async def get_student_info(self, cookie: str, student_id: str) -> StudentInfo:
        """获取学生基本信息"""
        if not self.client:
            raise NetworkError("Client not initialized")

        # 使用正确的URL获取学生信息（参考学长项目）
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
            raise CookieLapseError("获取学生信息失败，Cookie可能已失效")

        body = resp.text

        # 解析学生信息（HTML结构：id="col_xxx"下有<p>标签）
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
        """获取课表原始数据"""
        if not self.client:
            raise NetworkError("Client not initialized")

        headers = {"Cookie": cookie}
        form_data = {
            "xnm": year,
            "zs": "1",
            "doType": "app",
            "xqm": str(semester),
            "kblx": "1",
        }

        resp = await self.client.post(
            f"{COURSE_URL}/xskbcxMobile_cxXsKb.html",
            params={"gnmkdm": "N2154"},
            data=form_data,
            headers=headers
        )

        if resp.status_code != 200:
            raise CookieLapseError("获取课表失败，Cookie可能已失效")

        body = resp.text

        # 空响应表示Cookie失效
        if body == "null" or not body.strip():
            raise CookieLapseError("Cookie已失效")

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            raise CookieLapseError("课表数据解析失败")

        # 检查是否有课表数据
        kb_list = data.get("kbList", [])
        if not kb_list:
            raise CourseNotOpenError("当前学期课表暂未开放")

        courses = []
        for item in kb_list:
            course = CourseRawData(
                name=item.get("kcmc", ""),
                teacher=item.get("xm", ""),
                location=item.get("cdmc", ""),
                time=item.get("jc", ""),
                week_day=item.get("xqj", "1"),
                week_str=item.get("zcd", "")
            )
            courses.append(course)

        return courses

    # ============== 成绩相关 ==============

    async def fetch_grades(self, cookie: str, year: str, semester: int) -> List[dict]:
        """获取成绩原始数据"""
        if not self.client:
            raise NetworkError("Client not initialized")

        headers = {"Cookie": cookie}
        query_data = {"doType": "query", "gnmkdm": "N305005"}
        form_data = {
            "xnm": year,
            "xqm": str(semester),
            "queryModel.showCount": "50",
        }

        resp = await self.client.post(
            f"{GRADE_URL}/cjcx_cxXsgrcj.html",
            params=query_data,
            data=form_data,
            headers=headers
        )

        if resp.status_code != 200:
            raise CookieLapseError("获取成绩失败，Cookie可能已失效")

        content_type = resp.headers.get("Content-Type", "")
        if "text/html" in content_type:
            raise CookieLapseError("Cookie已失效")

        try:
            data = json.loads(resp.text)
        except json.JSONDecodeError:
            raise GradesNotOpenError("成绩数据解析失败")

        items = data.get("items", [])
        if not items:
            raise GradesNotOpenError("当前学期暂无成绩")

        return items


# ============== 辅助函数 ==============

def parse_weeks(week_str: str) -> List[int]:
    """解析周数字符串，如 '1-16周,18周' -> [1,2,3,...,16,18]"""
    weeks = []
    if not week_str:
        return weeks

    # 移除"周"字
    week_str = week_str.replace("周", "")

    # 按逗号分割
    parts = week_str.split(",")
    for part in parts:
        part = part.strip()
        if "-" in part:
            # 范围，如 "1-16"
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


def time_to_section(time_str: str) -> int:
    """将节次字符串转换为节次数字"""
    time_map = {
        "1-2节": 1,
        "3-4节": 2,
        "5-6节": 3,
        "7-8节": 4,
        "9-10节": 5,
        "11-12节": 6,
        "13-14节": 7,
        "15-16节": 8,
        "17-18节": 9,
    }
    return time_map.get(time_str, 1)
