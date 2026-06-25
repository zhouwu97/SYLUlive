"""                              """
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


# ==============              ==============

class EduError(Exception):
    """                  """
    pass


class CookieLapseError(EduError):
    """Cookie      """
    pass


class LoginFailedError(EduError):
    """            """
    pass


class CourseNotOpenError(EduError):
    """              ?"""
    pass


class GradesNotOpenError(EduError):
    """              ?"""
    pass


class NetworkError(EduError):
    """            """
    pass


# ==============              ==============

@dataclass
class PublicKey:
    """RSA      """
    modulus: str
    exponent: str


@dataclass
class CourseRawData:
    """                  """
    name: str
    teacher: str
    location: str
    time: str  #               ?"1-2  ?
    week_day: str  #         ?"1"
    week_str: str  #               ?"1-16  ?


@dataclass
class StudentInfo:
    """            """
    name: str
    grade: str
    college: str
    major: str


# ==============               ?==============

class EduCrawler:
    """                  """

    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout
        self.client: Optional[httpx.AsyncClient] = None
        self.cookies: List[httpx.Cookies] = []

    async def __aenter__(self):
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=False,
            verify=False,  #       SSL      
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
        """                                ?"""
        return str(int(time.time() * 1000))

    # ==============              ==============

    async def get_csrf_token(self) -> str:
        """      CSRF Token         Cookie"""
        if not self.client:
            raise NetworkError("Client not initialized")

        for retry in range(3):
            try:
                resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                if resp.status_code == 200:
                    #    HTML         csrftoken                                                      
                    match = re.search(r'id="csrftoken" name="csrftoken" value="([^"]+)"', resp.text)
                    if match:
                        csrf = match.group(1)
                        #                                  
                        if ',' in csrf:
                            csrf = csrf.split(',')[0]
                        return csrf
                    raise LoginFailedError("            CSRF Token")
                elif resp.status_code == 302:
                    #                   cookie
                    self.cookies = resp.cookies
                    #                               
                    resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                    match = re.search(r'id="csrftoken" name="csrftoken" value="([^"]+)"', resp.text)
                    if match:
                        csrf = match.group(1)
                        if ',' in csrf:
                            csrf = csrf.split(',')[0]
                        return csrf
                else:
                    raise NetworkError(f"      CSRF                  : {resp.status_code}")
            except httpx.TimeoutException:
                if retry < 2:
                    await asyncio.sleep(0.5)
                    continue
                raise NetworkError("      CSRF      ")

        raise NetworkError("      CSRF      ")

    async def get_public_key(self) -> PublicKey:
        """      RSA      """
        if not self.client:
            raise NetworkError("Client not initialized")

        timestamp = self._now_time_ms()
        resp = await self.client.get(
            f"{INDEX_URL}/login_getPublicKey.html",
            params={"time": timestamp, "_": timestamp}
        )

        if resp.status_code != 200:
            raise NetworkError(f"                              : {resp.status_code}")

        try:
            data = resp.json()
            return PublicKey(modulus=data["modulus"], exponent=data["exponent"])
        except (json.JSONDecodeError, KeyError) as e:
            raise NetworkError(f"                  : {e}")

    def _rsa_encrypt(self, password: str, public_key: PublicKey) -> str:
        """RSA            """
        try:
            #       base64   modulus   exponent
            modulus_bytes = base64.b64decode(public_key.modulus)
            exponent_bytes = base64.b64decode(public_key.exponent)

            #             
            from cryptography.hazmat.primitives.asymmetric import rsa
            from cryptography.hazmat.backends import default_backend
            public_numbers = rsa.RSAPublicNumbers(
                e=int.from_bytes(exponent_bytes, 'big'),
                n=int.from_bytes(modulus_bytes, 'big')
            )
            pub_key = public_numbers.public_key(default_backend())

            #       
            encrypted = pub_key.encrypt(
                password.encode('utf-8'),
                padding.PKCS1v15()
            )
            return base64.b64encode(encrypted).decode('ascii')
        except binascii.Error as e:
            raise LoginFailedError(f"                  : {e}")

    async def login(self, student_id: str, password: str) -> str:
        """                           Cookie        ?"""
        if not self.client:
            raise NetworkError("Client not initialized")

        # 1.       CSRF Token
        csrf_token = await self.get_csrf_token()

        # 2.             
        public_key = await self.get_public_key()

        # 3.             
        encrypted_password = self._rsa_encrypt(password, public_key)

        # 4.             
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

        #       POST                  302        ?
        #             302   login_slogin.html                                             cookie              ?
        #                                        cookie            

        #                      JSESSIONID                        
        jsessionid = None
        for name, value in self.client.cookies.items():
            if name == 'JSESSIONID':
                jsessionid = value
                break

        if jsessionid:
            #                cookie                  
            redirect_resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
            #                                             ?
            if redirect_resp.status_code == 302:
                location = redirect_resp.headers.get('location', '')
                if 'index_initMenu' in location or 'index' in location:
                    #                      cookie        ?
                    cookie_parts = []
                    for name, value in self.client.cookies.items():
                        cookie_parts.append(f"{name}={value}")
                    return "; ".join(cookie_parts)

        #                                                ?
        if resp.status_code == 302:
            #                alert
            if 'alert' in resp.text:
                error_match = re.search(r'alert\("([^"]+)"\)', resp.text)
                if error_match:
                    raise LoginFailedError(error_match.group(1))
            #             JSESSIONID
            set_cookie = resp.headers.get("set-cookie", "")
            if 'JSESSIONID' in set_cookie:
                for part in set_cookie.split(','):
                    if 'JSESSIONID' in part:
                        match = re.search(r'JSESSIONID=([^;]+)', part)
                        if match:
                            return f"JSESSIONID={match.group(1)}"
            raise LoginFailedError("                                   ?")
        elif resp.status_code == 200:
            error_match = re.search(r'alert\("([^"]+)"\)', resp.text)
            if error_match:
                raise LoginFailedError(error_match.group(1))
            raise LoginFailedError("                    ?")
        else:
            raise NetworkError(f"                              : {resp.status_code}")

    async def get_student_info(self, cookie: str, student_id: str) -> StudentInfo:
        """                        """
        if not self.client:
            raise NetworkError("Client not initialized")

        #                URL                                          
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
            raise CookieLapseError("                           Cookie              ?")

        body = resp.text

        #                      HTML         id="col_xxx"      <p>        ?
        name = ""
        grade = ""
        college = ""
        major = ""

        #              id=col_xm
        xm_match = re.search(r'id="col_xm"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if xm_match:
            name = xm_match.group(1).strip()

        #              id=col_njdm_id
        nj_match = re.search(r'id="col_njdm_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if nj_match:
            grade = nj_match.group(1).strip()

        #              id=col_jg_id
        jg_match = re.search(r'id="col_jg_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if jg_match:
            college = jg_match.group(1).strip()

        #              id=col_zyh_id
        zy_match = re.search(r'id="col_zyh_id"[^>]*>.*?<p[^>]*>([^<]+)</p>', body, re.DOTALL)
        if zy_match:
            major = zy_match.group(1).strip()

        return StudentInfo(name=name, grade=grade, college=college, major=major)

    # ==============              ==============

    async def fetch_courses(self, cookie: str, year: str, semester: int) -> List[CourseRawData]:
        """               ?               JSON                              JSON"""
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
            print(f"  [{source}]        {len(all_courses)}                     ?")

        # ==========================================
        # Step 1:         ?JSON                          ?
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
                raise CookieLapseError("Cookie        ?(DESK)")
            if resp.status_code == 200 and resp.text.strip() not in ("null", ""):
                data = resp.json()
                kb_list = data.get("kbList", [])
                _add_from_kblist(kb_list, "DESK")
        except EduError:
            raise  # CookieLapseError                     ?
        except Exception as e:
            print(f"  [DESK]       : {e}")

        # ==========================================
        # Step 2:         ?JSON                 ?
        # ==========================================
        if not all_courses:
            print("  [MOBILE]                                    ?..")
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
                print(f"  [MOBILE]       : {e}")

        if not all_courses:
            raise CourseNotOpenError("                             ?")

        return all_courses

    # ==============              ==============

    async def fetch_grades(self, cookie: str, year: str, semester: int) -> List[dict]:
        """                        """
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
            raise CookieLapseError("                     Cookie              ?")

        content_type = resp.headers.get("Content-Type", "")
        if "text/html" in content_type:
            raise CookieLapseError("Cookie        ?")

        try:
            data = json.loads(resp.text)
        except json.JSONDecodeError:
            raise GradesNotOpenError("                        ")

        items = data.get("items", [])
        if not items:
            raise GradesNotOpenError("                        ")

        return items


# ==============              ==============

def parse_weeks(week_str: str) -> List[int]:
    """                          ?'1-16  ?18  ? -> [1,2,3,...,16,18]"""
    weeks = []
    if not week_str:
        return weeks

    #       "  ?  ?
    week_str = week_str.replace("  ?, """)

    #                
    parts = week_str.split(",")
    for part in parts:
        part = part.strip()
        if "-" in part:
            #              "1-16"
            try:
                start, end = part.split("-")
                for i in range(int(start), int(end) + 1):
                    weeks.append(i)
            except ValueError:
                continue
        else:
            #       
            try:
                weeks.append(int(part))
            except ValueError:
                continue

    return sorted(list(set(weeks)))


def parse_time_sections(time_str: str) -> Tuple[int, int]:
    """                                                            

                  ?
      - "1-2  ? / "3-4  ?   ?(1, 2) / (3, 4)
      - "0102" / "0304"   ?(1, 2) / (3, 4)  ?              ?                    ?                  
    """
    if not time_str:
        return (1, 2)
    #       1: "3-4  ?   ?"3-4"
    match = re.search(r'(\d+)[-~](\d+)', time_str)
    if match:
        return (int(match.group(1)), int(match.group(2)))
    #       2: "0304"  ?                  2        ?      
    if time_str.isdigit() and len(time_str) >= 4:
        return (int(time_str[:2]), int(time_str[2:4]))
    #       3:                         
    nums = re.findall(r'\d+', time_str)
    if len(nums) >= 2:
        return (int(nums[0]), int(nums[-1]))
    elif nums:
        return (int(nums[0]), int(nums[0]))
    return (1, 2)

