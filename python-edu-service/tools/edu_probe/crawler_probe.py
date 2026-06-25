"""
Minimal probe crawler for grade structure inspection.

Implements only the essential methods needed to:
- Login to the edu system (CSRF token + RSA encryption + JSESSIONID)
- Fetch raw grade list JSON
- Fetch grade query page HTML for endpoint discovery

Derived from the production EduCrawler API contract (8aaf6a1).
This is NOT a replacement for services/crawler.py — probe use only.
"""
import asyncio
import base64
import binascii
import json
import re
import time
from typing import Optional, List

import httpx
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend

# --------------- config (mirrors production config.py) ---------------
INDEX_URL = "https://jxw.sylu.edu.cn/xtgl"
GRADE_URL = "https://jxw.sylu.edu.cn/cjcx"

# --------------- errors ---------------
class ProbeError(Exception):
    """Probe base error."""
    pass

class LoginFailedError(ProbeError):
    """Login failed."""
    pass

class CookieExpiredError(ProbeError):
    """Cookie expired."""
    pass

class GradesNotOpenError(ProbeError):
    """Grades not yet available for this semester."""
    pass

class NetworkError(ProbeError):
    """Network error."""
    pass

# --------------- data ---------------
class PublicKey:
    def __init__(self, modulus: str, exponent: str):
        self.modulus = modulus
        self.exponent = exponent

# --------------- crawler ---------------
class ProbeCrawler:
    """Minimal edu system crawler for grade structure probing."""

    def __init__(self, timeout: float = 15.0):
        self.timeout = timeout
        self.client: Optional[httpx.AsyncClient] = None

    async def __aenter__(self):
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=False,
            verify=False,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
                "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                "Cache-Control": "no-cache",
            },
        )
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.client:
            await self.client.aclose()

    def _ts(self) -> str:
        return str(int(time.time() * 1000))

    # --- auth ---

    async def get_csrf_token(self) -> str:
        if not self.client:
            raise NetworkError("Client not initialized")
        for retry in range(3):
            try:
                resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                if resp.status_code == 200:
                    match = re.search(
                        r'id="csrftoken"\s+name="csrftoken"\s+value="([^"]+)"',
                        resp.text,
                    )
                    if match:
                        csrf = match.group(1)
                        if "," in csrf:
                            csrf = csrf.split(",")[0]
                        return csrf
                    raise LoginFailedError("CSRF token not found")
                elif resp.status_code == 302:
                    resp = await self.client.get(f"{INDEX_URL}/login_slogin.html")
                    match = re.search(
                        r'id="csrftoken"\s+name="csrftoken"\s+value="([^"]+)"',
                        resp.text,
                    )
                    if match:
                        csrf = match.group(1)
                        if "," in csrf:
                            csrf = csrf.split(",")[0]
                        return csrf
                else:
                    raise NetworkError(
                        f"CSRF fetch failed: HTTP {resp.status_code}"
                    )
            except httpx.TimeoutException:
                if retry < 2:
                    await asyncio.sleep(0.5)
                    continue
                raise NetworkError("CSRF fetch timeout")
        raise NetworkError("CSRF fetch failed after retries")

    async def get_public_key(self) -> PublicKey:
        if not self.client:
            raise NetworkError("Client not initialized")
        ts = self._ts()
        resp = await self.client.get(
            f"{INDEX_URL}/login_getPublicKey.html",
            params={"time": ts, "_": ts},
        )
        if resp.status_code != 200:
            raise NetworkError(f"Public key fetch failed: HTTP {resp.status_code}")
        try:
            data = resp.json()
            return PublicKey(modulus=data["modulus"], exponent=data["exponent"])
        except (json.JSONDecodeError, KeyError) as e:
            raise NetworkError(f"Public key parse failed: {e}")

    def rsa_encrypt(self, password: str, public_key: PublicKey) -> str:
        try:
            mod_bytes = base64.b64decode(public_key.modulus)
            exp_bytes = base64.b64decode(public_key.exponent)
            pub = rsa.RSAPublicNumbers(
                e=int.from_bytes(exp_bytes, "big"),
                n=int.from_bytes(mod_bytes, "big"),
            ).public_key(default_backend())
            encrypted = pub.encrypt(password.encode("utf-8"), padding.PKCS1v15())
            return base64.b64encode(encrypted).decode("ascii")
        except binascii.Error as e:
            raise LoginFailedError(f"RSA encrypt failed: {e}")

    async def login(self, student_id: str, password: str) -> str:
        if not self.client:
            raise NetworkError("Client not initialized")

        csrf = await self.get_csrf_token()
        pubkey = await self.get_public_key()
        encrypted_pw = self.rsa_encrypt(password, pubkey)

        ts = self._ts()
        resp = await self.client.post(
            f"{INDEX_URL}/login_slogin.html",
            data={
                "csrftoken": csrf,
                "language": "zh_CN",
                "yhm": student_id,
                "mm": encrypted_pw,
            },
            params={"time": ts},
        )

        # Extract JSESSIONID from cookies
        jsessionid = None
        for name, value in self.client.cookies.items():
            if name == "JSESSIONID":
                jsessionid = value
                break

        if jsessionid:
            redirect_resp = await self.client.get(
                f"{INDEX_URL}/login_slogin.html"
            )
            if redirect_resp.status_code == 302:
                location = redirect_resp.headers.get("location", "")
                if "index_initMenu" in location or "index" in location:
                    parts = []
                    for n, v in self.client.cookies.items():
                        parts.append(f"{n}={v}")
                    return "; ".join(parts)

        # Fallback: check set-cookie header on original response
        if resp.status_code == 302:
            set_cookie = resp.headers.get("set-cookie", "")
            if "JSESSIONID" in set_cookie:
                for part in set_cookie.split(","):
                    if "JSESSIONID" in part:
                        m = re.search(r"JSESSIONID=([^;]+)", part)
                        if m:
                            return f"JSESSIONID={m.group(1)}"
            if "alert" in resp.text:
                err = re.search(r'alert\("([^"]+)"\)', resp.text)
                if err:
                    raise LoginFailedError(err.group(1))
            raise LoginFailedError("Login failed: check credentials")
        elif resp.status_code == 200:
            err = re.search(r'alert\("([^"]+)"\)', resp.text)
            if err:
                raise LoginFailedError(err.group(1))
            raise LoginFailedError("Account or password error")
        else:
            raise NetworkError(f"Login request failed: HTTP {resp.status_code}")

    # --- grades ---

    async def fetch_grades(
        self, cookie: str, year: str, semester: int
    ) -> List[dict]:
        """Fetch raw grade list. Returns list of item dicts."""
        if not self.client:
            raise NetworkError("Client not initialized")

        resp = await self.client.post(
            f"{GRADE_URL}/cjcx_cxXsgrcj.html",
            params={"doType": "query", "gnmkdm": "N305005"},
            data={
                "xnm": year,
                "xqm": str(semester),
                "queryModel.showCount": "50",
            },
            headers={"Cookie": cookie},
        )

        if resp.status_code != 200:
            raise CookieExpiredError(
                f"Grades fetch failed: HTTP {resp.status_code}"
            )

        ct = resp.headers.get("Content-Type", "")
        if "text/html" in ct:
            raise CookieExpiredError("Cookie expired")

        try:
            data = resp.json()
        except json.JSONDecodeError:
            raise GradesNotOpenError("Grades JSON parse failed")

        items = data.get("items", [])
        if not items:
            raise GradesNotOpenError("No grades for this semester")

        return items

    async def fetch_grade_page(self, cookie: str) -> str:
        """Fetch the grade query page HTML for JS/endpoint discovery."""
        if not self.client:
            raise NetworkError("Client not initialized")

        resp = await self.client.get(
            f"{GRADE_URL}/cjcx_cxXsgrcj.html",
            params={"gnmkdm": "N305005"},
            headers={"Cookie": cookie},
        )

        if resp.status_code != 200:
            raise CookieExpiredError(
                f"Page fetch failed: HTTP {resp.status_code}"
            )

        return resp.text
