"""
沈阳理工大学二课系统爬虫 (穿透深信服 WebVPN)
==============================================

功能概述:
  1. 穿透深信服 Sangfor WebVPN，通过 AES-CFB128 加密内网域名访问二课平台
  2. 模拟登录 ASP.NET WebForms 架构的二课系统
  3. 自动识别图形验证码 (ddddocr)
  4. RSA 公钥密码加密 + Base64 编码

技术栈:
  - requests.Session()  —— 保持全局 Cookie 持久化
  - BeautifulSoup4      —— HTML 解析，提取动态 Token 和公钥
  - ddddocr             —— 图形验证码 OCR 识别
  - pycryptodome        —— AES-CFB128 (URL加密) + RSA/PKCS1_v1_5 (密码加密)

对外接口 (供 Go 后端调度):
  方式一 — Python API 直接调用:
      crawler = SyluCrawler(vpn_ticket="xxx")
      result = crawler.login("学号", "密码")

  方式二 — 命令行子进程调用:
      python erke_crawler.py <学号> <密码> [VPN_TICKET]
      输出 JSON 到 stdout，退出码 0=成功 1=失败

依赖: pip install requests beautifulsoup4 ddddocr pycryptodome
"""

import base64
import binascii
import json
import re
import sys
from urllib.parse import quote_plus, urlencode

import ddddocr
import requests
from bs4 import BeautifulSoup
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.PublicKey import RSA


# ═══════════════════════════════════════════════════════════════════
#  SyluCrawler — 二课系统爬虫主类
# ═══════════════════════════════════════════════════════════════════

class SyluCrawler:
    """
    沈阳理工大学二课系统爬虫 (穿透深信服 WebVPN)

    WebVPN URL 加密算法 (AES-CFB128):
      - 内网目标地址: http://xg.sylu.edu.cn/SyluTW/Sys/SystemForm/main.htm
      - 将内网域名 xg.sylu.edu.cn 通过 AES-CFB128 加密后拼接为 VPN 代理 URL
      - Key/IV 均为固定值: b'wrdvpnisthebest!' (16 字节)
      - 最终 URL 格式:
        https://webvpn.sylu.edu.cn/http/{hex(KEY)}{hex(AES(domain))}{path}

    密码 RSA 加密规则:
      - HTML 中 <input id="pubKey"> 下发 Base64 格式公钥
      - 使用 PKCS#1 v1.5 填充 → RSA 加密 → Base64 编码 → 作为 pwd 字段提交
    """

    # ── WebVPN 配置常量 ──────────────────────────────────────────
    VPN_BASE = "https://webvpn.sylu.edu.cn"     # 深信服 WebVPN 入口
    TARGET_DOMAIN = "xg.sylu.edu.cn"             # 内网二课系统域名
    AES_KEY = b"wrdvpnisthebest!"                # AES-CFB128 密钥 (16 字节)
    AES_IV = b"wrdvpnisthebest!"                 # AES-CFB128 初始向量 (16 字节)

    # ── 登录页路径 ──────────────────────────────────────────────
    LOGIN_PATH = "/SyluTW/Sys/UserLogin.aspx"
    SCORE_PATH = "/SyluTW/Sys/SystemForm/StuAction/StuActionSearch.aspx"

    # ── queryBtn 按钮的 GBK 原始字节 ─────────────────────────────
    # 服务器期望的表单值为: %B5%C7++++++++++++%C2%BC
    # 解码后 = "登" + 12个空格 + "录"  (GBK 编码)
    # \xb5\xc7 → "登", \xc2\xbc → "录"
    # 注意: 必须用 bytes 类型，因为 Python str 的 \x 转义会被解释为
    #       Latin-1 Unicode 码点而非原始字节
    QUERY_BTN_RAW = b"\xb5\xc7            \xc2\xbc"

    # ── 常用 User-Agent ─────────────────────────────────────────
    USER_AGENT = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    )

    # ═══════════════════════════════════════════════════════════
    #  构造 / 析构
    # ═══════════════════════════════════════════════════════════

    def __init__(self, vpn_ticket=None):
        """
        初始化爬虫实例

        Args:
            vpn_ticket: 可选。WebVPN 的认证票据
                Cookie 名: wengine_vpn_ticketwebvpn_sylu_edu_cn
                如果用户已在外网完成 VPN 认证，可传入此票据跳过 VPN 登录步骤
        """
        # ── 创建 requests.Session (保持全局 Cookie) ──
        self.session = requests.Session()
        self.session.verify = False  # WebVPN 证书链不完整
        self.session.headers["User-Agent"] = self.USER_AGENT

        # ── 注入 WebVPN 票据 ──
        if vpn_ticket:
            self.session.cookies.set(
                "wengine_vpn_ticketwebvpn_sylu_edu_cn",
                vpn_ticket,
                domain="webvpn.sylu.edu.cn",
            )
            self._vpn_authenticated = True
        else:
            self._vpn_authenticated = False

        # ── 初始化 OCR 引擎 (ddddocr) ──
        self.ocr = ddddocr.DdddOcr(show_ad=False)

        # ── 缓存加密后的主机名 (域名固定，只算一次) ──
        self._encrypted_host = self._encrypt_domain(self.TARGET_DOMAIN)

    # ═══════════════════════════════════════════════════════════
    #  WebVPN URL 加密 — AES-CFB128
    # ═══════════════════════════════════════════════════════════

    def _encrypt_domain(self, domain):
        """
        使用 AES-CFB128 加密内网域名

        WebVPN URL 拼接规则:
          https://webvpn.sylu.edu.cn/http/{hex(KEY)}{hex(AES(domain))}{path}

        算法细节:
          - 模式: AES.MODE_CFB, segment_size=128
          - CFB 是流密码模式: 明文长度 == 密文长度，**无需填充**
          - Key 和 IV 均为固定值 b'wrdvpnisthebest!'

        Args:
            domain: 内网域名 (str)，例如 "xg.sylu.edu.cn"

        Returns:
            str: hex(KEY) + hex(密文)，例如 "77726476706e69737468656265737421..."
        """
        cipher = AES.new(self.AES_KEY, AES.MODE_CFB, self.AES_IV, segment_size=128)

        # CFB 模式下输出长度 == 输入长度，无需 PKCS#7 padding
        encrypted = cipher.encrypt(domain.encode())

        key_hex = binascii.hexlify(self.AES_KEY).decode()
        domain_hex = binascii.hexlify(encrypted).decode()

        return key_hex + domain_hex

    def get_vpn_url(self, path):
        """
        构造加密后的 WebVPN 完整代理 URL

        Args:
            path: 内网路径 (str)，以 "/" 开头，例如 "/SyluTW/Sys/SystemForm/Login.aspx"

        Returns:
            str: 完整的 WebVPN 代理 URL
        """
        if not path.startswith("/"):
            path = "/" + path
        return f"{self.VPN_BASE}/http/{self._encrypted_host}{path}"

    # ═══════════════════════════════════════════════════════════
    #  RSA 密码加密 — PKCS#1 v1.5
    # ═══════════════════════════════════════════════════════════

    def rsa_encrypt(self, text, pub_key_str):
        """
        使用服务器下发的 RSA 公钥对明文密码加密

        工作流:
          1. 检查公钥是否为 PEM 格式，若不是则包装为 PEM
          2. 导入公钥
          3. PKCS#1 v1.5 填充 → 加密
          4. Base64 编码结果

        Args:
            text: 用户明文密码 (str)
            pub_key_str: 服务器在 HTML 中 <input id="pubKey"> 下发的公钥字符串
                         可能是纯 Base64 或 PEM 格式

        Returns:
            str: Base64 编码的加密密码
        """
        # 自动识别并补全 PEM 格式
        if "BEGIN PUBLIC KEY" not in pub_key_str:
            pub_key_str = (
                f"-----BEGIN PUBLIC KEY-----\n"
                f"{pub_key_str}\n"
                f"-----END PUBLIC KEY-----"
            )

        key = RSA.import_key(pub_key_str)
        cipher = PKCS1_v1_5.new(key)
        encrypted = cipher.encrypt(text.encode())
        return base64.b64encode(encrypted).decode()

    # ═══════════════════════════════════════════════════════════
    #  VPN 认证
    # ═══════════════════════════════════════════════════════════

    def vpn_login(self, vpn_username, vpn_password):
        """
        登录深信服 WebVPN 获取认证票据

        如果用户没有现成的 VPN Ticket，可通过此方法先进行 VPN 登录。
        登录成功后会设置 Cookie: wengine_vpn_ticketwebvpn_sylu_edu_cn

        Args:
            vpn_username: VPN 用户名
            vpn_password: VPN 密码

        Returns:
            dict: {"success": bool, "message": str}
        """
        login_url = f"{self.VPN_BASE}/login"

        try:
            # 1. 预请求 (获取可能的 CSRF Token / 建立 Session)
            self.session.get(login_url, timeout=10)

            # 2. POST 登录
            post_data = {
                "username": vpn_username,
                "password": vpn_password,
                "remember_cookie": "on",
            }
            self.session.post(
                login_url, data=post_data,
                allow_redirects=False, timeout=10,
            )

            # 3. 检查是否获取到 Ticket
            ticket_key = "wengine_vpn_ticketwebvpn_sylu_edu_cn"
            if ticket_key in self.session.cookies:
                self._vpn_authenticated = True
                return {"success": True, "message": "VPN 登录成功"}
            else:
                return {"success": False, "message": "VPN 登录失败，请检查账号密码"}

        except requests.RequestException as e:
            return {"success": False, "message": f"VPN 网络错误: {e}"}
        except Exception as e:
            return {"success": False, "message": f"VPN 登录异常: {e}"}

    # ═══════════════════════════════════════════════════════════
    #  核心登录流程
    # ═══════════════════════════════════════════════════════════

    def _extract_input_value(self, soup, input_id, required=False):
        """
        从 BeautifulSoup 解析的 HTML 中安全提取 <input> 的 value 属性

        Args:
            soup: BeautifulSoup 对象
            input_id: <input> 的 id 属性值
            required: 是否为关键参数 (缺失时抛 ValueError)

        Returns:
            str: value 属性值 (找不到时返回 "")

        Raises:
            ValueError: 当 required=True 且未找到该 input 时
        """
        element = soup.find("input", {"id": input_id})
        if element is None:
            if required:
                raise ValueError(f"页面中未找到必要的 input: #{input_id}")
            return ""
        return element.get("value", "")

    def _extract_captcha(self, soup):
        """从登录页提取伪验证码 (位于 #code-box 的纯文本，非图片)"""
        code_box = soup.find(id="code-box") or soup.find(attrs={"id": "code-box"})
        if code_box:
            captcha = code_box.get_text(strip=True)
            if captcha:
                print(f"[INFO]  提取伪验证码: {captcha}")
                return captcha
        # 兜底
        print("[WARN]  未找到 #code-box，使用兜底验证码 'K777'")
        return "K777"

    def _gbk_urlencode(self, data):
        """
        将表单字典按 GBK 编码进行 URL 编码

        ASP.NET WebForms 服务器通常期望 GBK/GB2312 编码的表单数据。
        如果使用 UTF-8 编码 (requests 默认行为)，中文参数会被错误解析。

        特殊处理: 值为 bytes 类型时，视为已编码的原始 GBK 字节，
                  直接用 quote_plus 编码，不再二次编码。

        Args:
            data: 表单数据字典，value 可以是 str 或 bytes

        Returns:
            str: URL 编码后的表单字符串 (GBK)
        """
        # 先用 urlencode 处理 str 类型的字段 (GBK 编码)
        str_data = {k: v for k, v in data.items() if not isinstance(v, bytes)}
        str_body = urlencode(str_data, encoding="gbk") if str_data else ""

        # 再单独处理 bytes 类型的字段 (已经是原始 GBK 字节)
        bytes_parts = []
        for k, v in data.items():
            if isinstance(v, bytes):
                key_enc = quote_plus(k.encode("gbk"), safe="")
                val_enc = quote_plus(v, safe="")
                bytes_parts.append(f"{key_enc}={val_enc}")

        # 拼接
        if str_body and bytes_parts:
            return str_body + "&" + "&".join(bytes_parts)
        elif bytes_parts:
            return "&".join(bytes_parts)
        else:
            return str_body

    def login(self, username, password):
        """
        执行完整的二课系统登录流程

        严格按照以下顺序执行:

          步骤 1 — GET 踩点
              携带 Session Cookie 请求加密后的登录页 URL

          步骤 2 — 解析动态参数
              从 HTML 中提取 ASP.NET 必须的隐藏字段:
              - __VIEWSTATE          (视图状态)
              - __VIEWSTATEGENERATOR (视图状态生成器)
              - __EVENTVALIDATION    (事件验证)
              - pubKey               (RSA 公钥)

          步骤 3 — 验证码识别
              定位验证码图片 → 下载 → ddddocr OCR 识别
              识别结果作为 codeInput 字段提交

          步骤 4 — 密码 RSA 加密
              使用 pubKey 对明文密码进行:
              PKCS#1 v1.5 填充 → RSA 加密 → Base64 编码

          步骤 5 — POST 登录
              构造完整表单 (GBK 编码)，提交到登录 URL
              根据响应判断登录成功或失败

        Args:
            username: 学号 (str)
            password: 明文密码 (str)

        Returns:
            dict:
              {
                "success": bool,
                "message": str,
                "data": {                       # 仅在 success=True 时存在
                    "cookies": dict,            # Session 中的所有 Cookie
                    "redirect_url": str,        # 登录后跳转的 URL
                }
              }
        """
        login_url = self.get_vpn_url(self.LOGIN_PATH)

        try:
            # ════════════════════════════════════════════════
            #  步骤 1: GET 踩点登录页
            # ════════════════════════════════════════════════
            resp = self.session.get(login_url, timeout=15)
            if resp.status_code != 200:
                return {
                    "success": False,
                    "message": (
                        f"无法访问登录页 (HTTP {resp.status_code})，"
                        f"请检查 VPN 连接是否正常"
                    ),
                }

            # 自动检测编码 (ASP.NET 页面可能使用 GBK)
            if resp.encoding and resp.encoding.lower() in ("iso-8859-1", "latin-1"):
                resp.encoding = "gbk"

            soup = BeautifulSoup(resp.text, "html.parser")

            # ════════════════════════════════════════════════
            #  步骤 2: 提取 ASP.NET 动态参数
            # ════════════════════════════════════════════════
            viewstate = self._extract_input_value(soup, "__VIEWSTATE")
            viewstate_gen = self._extract_input_value(soup, "__VIEWSTATEGENERATOR")
            event_validation = self._extract_input_value(soup, "__EVENTVALIDATION")
            pub_key = self._extract_input_value(soup, "pubKey")

            # 关键参数缺失检查
            if not viewstate:
                return {
                    "success": False,
                    "message": "登录页解析失败: 未找到 __VIEWSTATE，页面结构可能已变更",
                }
            if not pub_key:
                return {
                    "success": False,
                    "message": "登录页解析失败: 未找到 RSA 公钥 (pubKey)",
                }

            # ════════════════════════════════════════════════
            #  步骤 3: 提取伪验证码 (#code-box 文本)
            # ════════════════════════════════════════════════
            captcha_code = self._extract_captcha(soup)

            # ════════════════════════════════════════════════
            #  步骤 4: RSA 公钥加密密码
            # ════════════════════════════════════════════════
            try:
                pwd_encrypted = self.rsa_encrypt(password, pub_key)
            except Exception as e:
                return {"success": False, "message": f"RSA 密码加密失败: {e}"}

            # ════════════════════════════════════════════════
            #  步骤 5: 构造表单并 POST 登录
            # ════════════════════════════════════════════════
            post_data = {
                "__EVENTTARGET":        "",
                "__EVENTARGUMENT":      "",
                "__VIEWSTATE":          viewstate,
                "__VIEWSTATEGENERATOR": viewstate_gen,
                "__EVENTVALIDATION":    event_validation,
                "UserName":             username,
                "Password":             password,
                "pwd":                  pwd_encrypted,
                "pubKey":               pub_key,
                "codeInput":            captcha_code,
                "queryBtn":             self.QUERY_BTN_RAW,
            }

            # 使用 GBK 编码整个表单 (ASP.NET 服务器期望 GBK)
            body = self._gbk_urlencode(post_data)

            resp = self.session.post(
                login_url,
                data=body,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                timeout=15,
                allow_redirects=True,
            )

            # ════════════════════════════════════════════════
            #  判断登录结果（检查重定向脚本）
            # ════════════════════════════════════════════════
            post_soup = BeautifulSoup(resp.text, "html.parser")

            # 方式 1 — 检查 JS 重定向脚本
            for script in post_soup.find_all("script"):
                if script.string and (
                    "window.location.href='SystemForm/main.htm'" in script.string or
                    'window.location.href="SystemForm/main.htm"' in script.string
                ):
                    print("[INFO]  登录成功！获取成绩页...")
                    # 构造成绩页 URL
                    score_url = login_url.replace("UserLogin.aspx", "SystemForm/StuAction/StuActionSearch.aspx")
                    score_resp = self.session.get(score_url, timeout=15)
                    cookies = self.session.cookies.get_dict()
                    return {
                        "success": True,
                        "message": "登录成功",
                        "data": {
                            "cookies": cookies,
                            "score_html": score_resp.text,
                            "score_url": score_url,
                        },
                    }

            # 方式 2 — JavaScript alert 错误
            alert_match = re.search(r"alert\s*\(\s*'([^']+)'\s*\)", resp.text)
            if alert_match:
                return {"success": False, "message": alert_match.group(1)}

            # 方式 3 — 页面错误元素
            for eid in ("msg", "error", "lblMsg"):
                error_elem = post_soup.find(id=eid) or post_soup.find(attrs={"id": eid})
                if error_elem and error_elem.get_text(strip=True):
                    return {"success": False, "message": error_elem.get_text(strip=True)}

            return {
                "success": False,
                "message": "登录失败，请检查学号、密码或验证码是否正确",
            }

        except requests.Timeout:
            return {"success": False, "message": "登录请求超时，请检查网络连接"}
        except requests.ConnectionError:
            return {"success": False, "message": "网络连接失败，请确认 VPN 是否正常"}
        except requests.RequestException as e:
            return {"success": False, "message": f"网络请求错误: {e}"}
        except Exception as e:
            return {"success": False, "message": f"系统内部错误: {e}"}

    # ═══════════════════════════════════════════════════════════
    #  二课成绩查询
    # ═══════════════════════════════════════════════════════════

    def get_scores(self):
        """
        获取二课成绩列表

        前置条件: 必须先调用 login() 成功登录

        Returns:
            dict:
              {
                "success": bool,
                "data": [
                    {"item": str, "score": str, "date": str},
                    ...
                ],
                "message": str
              }
        """
        score_path = "/SyluTW/Sys/Score/ScoreList.aspx"
        score_url = self.get_vpn_url(score_path)

        try:
            resp = self.session.get(score_url, timeout=10)
            soup = BeautifulSoup(resp.text, "html.parser")

            # 尝试多种可能的表格选择器
            table = None
            for selector in ("gridview", "GridView", "table", "datagrid", "dgData"):
                table = soup.find("table", {"class": selector})
                if table:
                    break

            # 如果 class 匹配都找不到，找第一个有 >1 行的 table
            if not table:
                for t in soup.find_all("table"):
                    if len(t.find_all("tr")) > 1:
                        table = t
                        break

            scores = []
            if table:
                rows = table.find_all("tr")[1:]  # 跳过表头
                for row in rows:
                    cols = row.find_all("td")
                    if len(cols) >= 3:
                        scores.append({
                            "item":  cols[0].get_text(strip=True),
                            "score": cols[1].get_text(strip=True),
                            "date":  cols[2].get_text(strip=True),
                        })

            return {"success": True, "data": scores}

        except requests.RequestException as e:
            return {"success": False, "message": f"网络错误: {e}"}
        except Exception as e:
            return {"success": False, "message": f"解析错误: {e}"}

    # ═══════════════════════════════════════════════════════════
    #  Cookie 导入/导出 (供 Go 后端持久化会话)
    # ═══════════════════════════════════════════════════════════

    def export_cookies(self):
        """
        导出当前 Session 中的所有 Cookie 为字典

        用途: Go 后端调用 login() 成功后，通过此方法获取 Cookie 字典，
              存入数据库以实现会话持久化，避免每次请求都重新登录。

        Returns:
            dict: Cookie 键值对
        """
        return self.session.cookies.get_dict()

    def import_cookies(self, cookies_dict):
        """
        从字典批量导入 Cookie 到当前 Session

        Args:
            cookies_dict: Cookie 键值对字典
        """
        for name, value in (cookies_dict or {}).items():
            self.session.cookies.set(name, value)


# ═══════════════════════════════════════════════════════════════════
#  命令行入口 (供 Go 后端通过 subprocess / os/exec 调度)
# ═══════════════════════════════════════════════════════════════════
#
#  调用方式:
#    python erke_crawler.py <学号> <密码> [VPN_TICKET]
#
#  输出:
#    JSON 字符串 → stdout
#    退出码 0 → 成功
#    退出码 1 → 失败
#
#  Go 后端示例:
#    cmd := exec.Command("python3", "erke_crawler.py", studentID, password, vpnTicket)
#    output, _ := cmd.Output()
#    var result map[string]interface{}
#    json.Unmarshal(output, &result)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({
            "success": False,
            "message": (
                "参数不足，用法: "
                "python erke_crawler.py <学号> <密码> [VPN_TICKET]"
            ),
        }, ensure_ascii=False))
        sys.exit(1)

    username   = sys.argv[1]
    password   = sys.argv[2]
    vpn_ticket = sys.argv[3] if len(sys.argv) > 3 else None

    # 创建爬虫实例并执行登录
    crawler = SyluCrawler(vpn_ticket=vpn_ticket)
    result = crawler.login(username, password)

    # 输出 JSON 到 stdout (Go 后端读取)
    print(json.dumps(result, ensure_ascii=False))

    # 退出码: 0=成功, 1=失败
    sys.exit(0 if result.get("success") else 1)
