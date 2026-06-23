"""
二课成绩测试爬取脚本
==================
完整复现 Flutter 端 WebVpnService + SyluClientCrawler 流程：
  1. VPN CAS 认证 → wengine_vpn_ticket
  2. 二课 UserLogin.aspx 登录 (RSA + 伪验证码)
  3. 明细: StuActionSearch.aspx → 活动列表 + 按类别汇总
  4. 毕业要求: StuFinishStudentScore.aspx → A~E 标准 + 已得分 + 结论
  5. 学年要求: StuFinishStudentScoreXN.aspx → 分学年标准 + 学年得分 + 累计得分 + 结论
"""
import os, sys, io, re, time, random, string, base64, binascii, urllib.parse

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
for k in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY']:
    os.environ.pop(k, None)

import urllib3
urllib3.disable_warnings()

import requests
from bs4 import BeautifulSoup
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.PublicKey import RSA

# ====================================================================
#  配置
# ====================================================================

STUDENT_ID = "2403060128"
VPN_PASSWORD = "@Zhoukangwu0"
ERKE_PASSWORD = "@Zhoukangwu0"

AES_KEY = b"wrdvpnisthebest!"
AES_IV  = b"wrdvpnisthebest!"
VPN_HOST = "https://webvpn.sylu.edu.cn"
TARGET_DOMAIN = "xg.sylu.edu.cn"

QUERY_BTN_RAW = b"\xb5\xc7            \xc2\xbc"  # "登          录" GBK

# ====================================================================
#  工具函数
# ====================================================================

def make_vpn_url(path: str) -> str:
    cipher = AES.new(AES_KEY, AES.MODE_CFB, AES_IV, segment_size=128)
    encrypted = cipher.encrypt(TARGET_DOMAIN.encode())
    key_hex = binascii.hexlify(AES_KEY).decode()
    domain_hex = binascii.hexlify(encrypted).decode()
    if not path.startswith("/"):
        path = "/" + path
    return f"{VPN_HOST}/http/{key_hex}{domain_hex}{path}"


def aes_encrypt(raw_password: str, salt: str) -> str:
    """CAS AES-CBC: 64随机字符 + 密码 → AES-CBC(salt, random IV) → Base64"""
    chars = string.ascii_letters + string.digits
    prefix = "".join(random.choice(chars) for _ in range(64))
    plaintext = prefix + raw_password
    key = salt.encode("utf-8")
    iv = "".join(random.choice(chars) for _ in range(16)).encode("utf-8")
    pad_len = 16 - len(plaintext.encode("utf-8")) % 16
    padded = plaintext + chr(pad_len) * pad_len
    cipher = AES.new(key, AES.MODE_CBC, iv)
    return base64.b64encode(cipher.encrypt(padded.encode("utf-8"))).decode()


def rsa_encrypt(password: str, pub_key: str) -> str:
    """RSA PKCS#1 v1.5 加密 (二课系统)"""
    if "BEGIN PUBLIC KEY" not in pub_key:
        pub_key = f"-----BEGIN PUBLIC KEY-----\n{pub_key}\n-----END PUBLIC KEY-----"
    key = RSA.import_key(pub_key)
    return base64.b64encode(PKCS1_v1_5.new(key).encrypt(password.encode())).decode()


def gbk_urlencode(data: dict) -> str:
    parts = []
    for k, v in data.items():
        if isinstance(v, bytes):
            parts.append(f"{urllib.parse.quote_plus(k.encode('gbk'), safe='')}={urllib.parse.quote_plus(v, safe='')}")
        else:
            parts.append(f"{urllib.parse.quote_plus(k.encode('gbk'), safe='')}={urllib.parse.quote_plus(str(v).encode('gbk'), safe='')}")
    return "&".join(parts)


def decode_html(resp) -> str:
    """智能解码 GBK/UTF-8 HTML"""
    if resp.encoding and "8859" in str(resp.encoding).lower():
        return resp.content.decode("gbk", errors="ignore")
    return resp.text


# ====================================================================
#  Phase 1: VPN CAS 登录
# ====================================================================

def vpn_cas_login(username: str, password: str) -> requests.Session | None:
    session = requests.Session()
    session.verify = False
    session.headers["User-Agent"] = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )

    # 1. VPN 首页 → 找 CAS 入口
    resp = session.get(VPN_HOST, timeout=15, allow_redirects=True)
    soup = BeautifulSoup(resp.text, "html.parser")
    cas_link = soup.find("a", id="cas-login")
    if not cas_link:
        print("[VPN] FAIL: 找不到 CAS 入口")
        return None
    cas_url = urllib.parse.urljoin(resp.url, cas_link["href"].replace("&amp;", "&"))

    # 2. 进入 CAS 登录页
    resp = session.get(cas_url, timeout=15, allow_redirects=True)
    soup = BeautifulSoup(resp.text, "html.parser")

    if "pwdEncryptSalt" not in resp.text:
        print("[VPN] FAIL: 未到达 CAS 登录页")
        return None

    salt_el = soup.find("input", id="pwdEncryptSalt") or soup.find("input", attrs={"name": "pwdEncryptSalt"})
    salt = salt_el["value"] if salt_el else ""
    execution = soup.find("input", attrs={"name": "execution"})["value"]
    lt = soup.find("input", attrs={"name": "lt"})["value"]

    print(f"[VPN] CAS params: salt={salt[:20]}... execution={execution[:30]}...")

    # 3. AES 加密密码
    encrypted_pwd = aes_encrypt(password, salt)

    # 4. POST CAS
    form = soup.find("form")
    action = form.get("action", "") if form else ""
    post_url = urllib.parse.urljoin(resp.url, action) if action else resp.url
    svc = re.search(r"[?&]service=([^&]+)", resp.url)
    if svc and "service=" not in post_url:
        post_url += ("&" if "?" in post_url else "?") + "service=" + svc.group(1)

    resp = session.post(
        post_url,
        data={
            "username": username,
            "password": encrypted_pwd,
            "_eventId": "submit",
            "cllt": "userNameLogin",
            "dllt": "generalLogin",
            "lt": lt,
            "execution": execution,
        },
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": resp.url,
            "Origin": VPN_HOST,
        },
        timeout=15,
        allow_redirects=True,
    )

    # 5. 跟随重定向直到拿到 ticket
    for _ in range(5):
        ticket = session.cookies.get("wengine_vpn_ticketwebvpn_sylu_edu_cn", "")
        if ticket and ticket.startswith("wrdvpn-"):
            break
        next_url = resp.headers.get("location")
        if not next_url:
            js_match = re.search(r"window\.location\.href\s*=\s*'([^']+)'", resp.text)
            if js_match:
                next_url = urllib.parse.urljoin(resp.url, js_match.group(1))
        if not next_url:
            break
        resp = session.get(
            urllib.parse.urljoin(resp.url, next_url) if not next_url.startswith("http") else next_url,
            timeout=10,
            allow_redirects=False,
        )

    ticket = session.cookies.get("wengine_vpn_ticketwebvpn_sylu_edu_cn", "")
    if ticket and ticket.startswith("wrdvpn-"):
        print(f"[VPN] SUCCESS: ticket={ticket[:40]}...")
        return session
    print("[VPN] FAIL: 未获取 VPN ticket")
    return None


# ====================================================================
#  Phase 2: 二课登录
# ====================================================================

def erke_login(session: requests.Session, username: str, password: str) -> bool:
    """登录二课系统"""
    login_url = make_vpn_url("/SyluTW/Sys/UserLogin.aspx")
    resp = session.get(login_url, timeout=15, allow_redirects=True)
    soup = BeautifulSoup(resp.text, "html.parser")

    if "__VIEWSTATE" not in resp.text:
        print(f"[二课] FAIL: 登录页无 __VIEWSTATE")
        return False

    vs = (soup.find("input", id="__VIEWSTATE") or soup.find("input", attrs={"name": "__VIEWSTATE"}))["value"]
    vsg = soup.find("input", id="__VIEWSTATEGENERATOR") or soup.find("input", attrs={"name": "__VIEWSTATEGENERATOR"})
    vsg = vsg["value"] if vsg else ""
    ev = soup.find("input", id="__EVENTVALIDATION") or soup.find("input", attrs={"name": "__EVENTVALIDATION"})
    ev = ev["value"] if ev else ""
    pub = (soup.find("input", id="pubKey") or soup.find("input", attrs={"name": "pubKey"}))["value"]
    code_box = soup.find(id="code-box")
    captcha = code_box.get_text(strip=True) if code_box else "K777"

    enc_pwd = rsa_encrypt(password, pub)
    body = gbk_urlencode({
        "__EVENTTARGET": "", "__EVENTARGUMENT": "",
        "__VIEWSTATE": vs, "__VIEWSTATEGENERATOR": vsg, "__EVENTVALIDATION": ev,
        "UserName": username, "Password": password, "pwd": enc_pwd,
        "pubKey": pub, "codeInput": captcha, "queryBtn": QUERY_BTN_RAW,
    })

    resp = session.post(
        login_url, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded", "Referer": login_url},
        timeout=15, allow_redirects=True,
    )

    post_soup = BeautifulSoup(resp.text, "html.parser")
    for script in post_soup.find_all("script"):
        if script.string and "main.htm" in script.string:
            print("[二课] SUCCESS")
            return True

    alert = re.search(r"alert\s*\(\s*'([^']+)'\s*\)", resp.text)
    if alert:
        print(f"[二课] FAIL: {alert.group(1)}")
        return False
    print("[二课] FAIL: 登录失败")
    return False


# ====================================================================
#  Phase 3: 数据解析
# ====================================================================

def parse_activity_list(session: requests.Session) -> dict:
    """解析 StuActionSearch.aspx → 活动明细 + 按类别汇总"""
    url = make_vpn_url("/SyluTW/Sys/SystemForm/StuAction/StuActionSearch.aspx")
    resp = session.get(url, timeout=15)
    html = decode_html(resp)
    soup = BeautifulSoup(html, "html.parser")

    scores = []
    rows = soup.select("#GridView1 tr") or soup.select("#DataGrid1 tr") or soup.select("table tr")
    for row in rows:
        cols = row.find_all("td")
        if len(cols) >= 8:
            item_name = cols[0].get_text(strip=True)
            score_val = cols[7].get_text(strip=True)
            date_val  = cols[2].get_text(strip=True)
            category  = cols[3].get_text(strip=True)
            if item_name and item_name not in ("活动名称", "序号"):
                if category in ("文体活动", "技能特长"):
                    category = "文体活动和技能特长"
                scores.append({"item": item_name, "score": score_val, "date": date_val, "category": category})

    scores.sort(key=lambda s: s["date"].split("至")[0].strip(), reverse=True)

    graduation_required = {
        "思想成长": 10.0, "实践实习": 10.0, "创新创业": 5.0,
        "志愿公益": 10.0, "文体活动和技能特长": 5.0,
    }
    category_totals = {}
    for s in scores:
        cat = s["category"]
        if cat:
            category_totals[cat] = category_totals.get(cat, 0) + float(s["score"])

    summary = []
    for cat, req in graduation_required.items():
        earned = category_totals.get(cat, 0)
        summary.append({"category": cat, "score": round(earned, 2), "required": req})

    return {"scores": scores, "summary": summary}


def parse_score_summary(html: str, page_label: str) -> dict:
    """
    解析两类汇总页面:
      - StuFinishStudentScore.aspx     → 毕业要求
      - StuFinishStudentScoreXN.aspx   → 学年要求

    返回结构:
      requirements: [{category, required}, ...]  # A~E 要求分
      earned:       [{category, score}, ...]     # 已得分
      total_earned: [{category, score}, ...]     # 累计总分 (仅学年页)
      year:         str | None                    # 学年标签 (仅学年页)
      conclusion:   str                           # 结论
    """
    soup = BeautifulSoup(html, "html.parser")
    text = soup.get_text()
    text = re.sub(r"\s+", " ", text)

    result = {
        "page": page_label,
        "year": None,
        "requirements": [],
        "earned": [],
        "total_earned": [],
        "total_required": 0,
        "total_earned_sum": 0,
        "total_overall_sum": 0,
        "conclusion": "",
    }

    categories = ["思想成长", "实践实习", "创新创业", "志愿公益", "文体活动和技能特长"]

    # 提取学年
    year_match = re.search(r"(\d{4}-\d{4})学年", text)
    if year_match:
        result["year"] = year_match.group(1)

    # ---- 解析要求分 (大于等于XX.XX) ----
    req_pattern = re.compile(r"([A-E])[、.]\s*(.+?)[：:]\s*大于等于(\d+\.?\d*)")
    for m in req_pattern.finditer(text):
        label = m.group(2).strip()
        req_val = float(m.group(3))
        result["requirements"].append({"category": label, "required": req_val})

    if not result["requirements"]:
        # Fallback: 从表格按位置解析
        result["requirements"] = _fallback_parse_requirements(soup)

    # ---- 解析已得分 ----
    # 策略: 在 "我得到的活动分值" 和 "我得到的活动总分值" 之间/之后找 A~E 分值
    earned_section = text.split("我得到的活动分值")[1] if "我得到的活动分值" in text else ""
    if "我得到的活动总分值" in earned_section:
        earned_section, total_section = earned_section.split("我得到的活动总分值", 1)
    else:
        total_section = ""

    earned_pattern = re.compile(r"([A-E])[、.]\s*(.+?)[：:]\s*(\d+\.?\d*)")
    for m in earned_pattern.finditer(earned_section):
        label = m.group(2).strip()
        score = float(m.group(3))
        result["earned"].append({"category": label, "score": score})

    # 学年总分
    total_match = re.search(r"活动总分[：:]\s*(\d+\.?\d*)", earned_section)
    if total_match:
        result["total_earned_sum"] = float(total_match.group(1))

    # ---- 累计总分 (仅学年页) ----
    for m in earned_pattern.finditer(total_section):
        label = m.group(2).strip()
        score = float(m.group(3))
        result["total_earned"].append({"category": label, "score": score})

    total_match = re.search(r"活动总分[：:]\s*(\d+\.?\d*)", total_section)
    if total_match:
        result["total_overall_sum"] = float(total_match.group(1))

    # ---- 结论 ----
    conclusion_match = re.search(r"结论[：:]\s*(.+?)$", text, re.MULTILINE)
    if conclusion_match:
        result["conclusion"] = conclusion_match.group(1).strip()

    # 如果 still empty, use fallback table parsing
    if not result["earned"]:
        result = _fallback_parse_full(soup, result)

    return result


def _fallback_parse_requirements(soup) -> list:
    """后备: 从 HTML 表格解析要求分"""
    reqs = []
    for table in soup.find_all("table"):
        text = table.get_text()
        matches = re.findall(r"([A-E][、.]\s*(?:思想成长|实践实习|创新创业|志愿公益|文体活动和技能特长))\s*[：:]\s*大于等于(\d+\.?\d*)", text)
        if len(matches) >= 3:
            for m in matches:
                cat = m[0].split("、")[1] if "、" in m[0] else m[0]
                reqs.append({"category": cat, "required": float(m[1])})
            break
    return reqs


def _fallback_parse_full(soup, result: dict) -> dict:
    """后备: 从表格直接提取所有数据"""
    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        if len(rows) < 3:
            continue
        all_text = []
        for row in rows:
            cols = row.find_all("td")
            for c in cols:
                all_text.append(c.get_text(strip=True))

        text = " | ".join(all_text)

        # 解析要求分
        req_matches = re.findall(r"[A-E]、(.+?)：\s*大于等于(\d+\.?\d*)", text)
        if len(req_matches) >= 3 and not result["requirements"]:
            for m in req_matches:
                result["requirements"].append({"category": m[0], "required": float(m[1])})

        # 解析 "我得到的活动分值" 之后的分数
        parts = text.split("我得到的活动分值")
        if len(parts) >= 2:
            earned_text = parts[1].split("我得到的活动总分值")[0] if "我得到的活动总分值" in parts[1] else parts[1]
            score_matches = re.findall(r"[A-E]、(.+?)：\s*(\d+\.?\d*)", earned_text)
            if score_matches and not result["earned"]:
                for m in score_matches:
                    result["earned"].append({"category": m[0], "score": float(m[1])})

        # 解析 "我得到的活动总分值"
        if "我得到的活动总分值" in text:
            total_part = text.split("我得到的活动总分值")[1]
            total_matches = re.findall(r"[A-E]、(.+?)：\s*(\d+\.?\d*)", total_part)
            if total_matches and not result["total_earned"]:
                for m in total_matches:
                    result["total_earned"].append({"category": m[0], "score": float(m[1])})

        # 结论
        conclusion_match = re.search(r"结论[：:]\s*(.+?)(?:\||$)", text)
        if conclusion_match and not result["conclusion"]:
            result["conclusion"] = conclusion_match.group(1).strip()

        break

    return result


# ====================================================================
#  Main
# ====================================================================

def main():
    print("=" * 60)
    print("  二课成绩测试爬取")
    print("=" * 60)
    print(f"  学号: {STUDENT_ID}")
    t0 = time.time()

    # ---- Phase 1: VPN ----
    print(f"\n{'='*60}")
    print("  Phase 1: VPN CAS 认证")
    print(f"{'='*60}")
    session = vpn_cas_login(STUDENT_ID, VPN_PASSWORD)
    if not session:
        print("\n[ABORT] VPN 登录失败")
        return

    # ---- Phase 2: 二课 ----
    print(f"\n{'='*60}")
    print("  Phase 2: 二课登录")
    print(f"{'='*60}")
    if not erke_login(session, STUDENT_ID, ERKE_PASSWORD):
        print("\n[ABORT] 二课登录失败")
        return

    # ---- Phase 3: 活动明细 ----
    print(f"\n{'='*60}")
    print("  Phase 3: 活动明细 + 类别汇总")
    print(f"{'='*60}")
    activity_data = parse_activity_list(session)
    print(f"  明细: {len(activity_data['scores'])} 条")
    for item in activity_data["summary"]:
        g = "✓" if item["score"] >= item["required"] else "✗"
        print(f"  {item['category']}: {item['score']}/{item['required']} {g}")

    print(f"\n  全部活动明细:")
    print(f"  {'日期':<14} {'类别':<18} {'分值':>6}  活动名称")
    print(f"  {'-'*70}")
    for s in activity_data["scores"]:
        date = s["date"].split("至")[0].strip()[:10]
        print(f"  {date:<14} {s['category']:<18} {s['score']:>6}  {s['item'][:50]}")

    # ---- Phase 4: 毕业要求 ----
    print(f"\n{'='*60}")
    print("  Phase 4: 毕业要求 (StuFinishStudentScore.aspx)")
    print(f"{'='*60}")
    grad_url = make_vpn_url("/SyluTW/Sys/SystemForm/FinishExam/StuFinishStudentScore.aspx")
    grad_resp = session.get(grad_url, timeout=15)
    grad_html = decode_html(grad_resp)
    grad_data = parse_score_summary(grad_html, "毕业要求")

    _print_summary(grad_data)

    # ---- Phase 5: 学年要求 ----
    print(f"\n{'='*60}")
    print("  Phase 5: 学年要求 (StuFinishStudentScoreXN.aspx)")
    print(f"{'='*60}")
    year_url = make_vpn_url("/SyluTW/Sys/SystemForm/FinishExam/StuFinishStudentScoreXN.aspx")
    year_resp = session.get(year_url, timeout=15)
    year_html = decode_html(year_resp)
    year_data = parse_score_summary(year_html, "学年要求")

    _print_summary(year_data)

    # ---- Done ----
    elapsed = time.time() - t0
    print(f"\n{'='*60}")
    print(f"  完成 ({elapsed:.1f}s)")
    print(f"{'='*60}")


def _print_summary(data: dict):
    """格式化打印汇总数据"""
    label = data["page"]
    yr = f" ({data['year']})" if data.get("year") else ""

    # 原始数据
    print(f"\n  [原始数据] requirements={data['requirements']}")
    print(f"  [原始数据] earned={data['earned']}")
    if data["total_earned"]:
        print(f"  [原始数据] total_earned={data['total_earned']}")

    print(f"\n  {label}{yr}")
    print(f"  {'类别':<20} {'要求分':>8} {'已得分':>8}", end="")
    if data["total_earned"]:
        print(f" {'累计':>8}", end="")
    print(f" {'状态':>10}")
    print(f"  {'-'*58}")

    cats = ["思想成长", "实践实习", "创新创业", "志愿公益", "文体活动和技能特长"]
    reqs = {r["category"]: r["required"] for r in data["requirements"]}
    earned_map = {e["category"]: e["score"] for e in data["earned"]}
    total_map = {e["category"]: e["score"] for e in data["total_earned"]}

    for cat in cats:
        req = reqs.get(cat, 0)
        earned = earned_map.get(cat, 0)
        total = total_map.get(cat, None)
        status = "✓ 达标" if earned >= req else f"✗ 差{req-earned:.1f}"
        line = f"  {cat:<20} {req:>8.1f} {earned:>8.2f}"
        if total is not None:
            line += f" {total:>8.2f}"
        line += f" {status:>10}"
        print(line)

    print(f"  {'-'*58}")
    ts = data.get("total_earned_sum", sum(e["score"] for e in data["earned"]))
    tr = sum(r["required"] for r in data["requirements"])
    line = f"  {'活动总分':<20} {tr:>8.1f} {ts:>8.2f}"
    if data["total_earned"]:
        to = data.get("total_overall_sum", sum(e["score"] for e in data["total_earned"]))
        line += f" {to:>8.2f}"
    print(line)

    if data["conclusion"]:
        print(f"  结论: {data['conclusion']}")


if __name__ == "__main__":
    main()
