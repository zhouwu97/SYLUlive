#!/usr/bin/env python3
"""
Static layout & content inspection — NO login required.

Probes public page skeletons and referenced JS to discover:
- login form fields & CSRF token extraction contract
- grade query page HTML skeleton (may redirect to login or serve template)
- referenced JS file list (教务 front-end often hardcodes field names there)
- keyword hits: ksxz, cjbz, pscj, qmcj, zpcj, cxbj, kch, doType, gnmkdm, xnm, xqm
- candidate detail endpoints derivable purely from static resources

Outputs everything to output/site_layout/ for human review.
Designed to be runnable without any credentials — this only fetches
public page shells and static JS, no data requests are made.

Usage:
    python tools/edu_probe/inspect_site_layout.py
"""
import asyncio
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx

PROBE_DIR = Path(__file__).resolve().parent
OUTPUT = PROBE_DIR / "output" / "site_layout"

INDEX_URL = "https://jxw.sylu.edu.cn/xtgl"
GRADE_URL = "https://jxw.sylu.edu.cn/cjcx"

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# Keywords we want to locate in any fetched HTML/JS.
KEYWORDS = [
    # Field names we suspect the raw grade API drops.
    "ksxz", "cjbz", "pscj", "qmcj", "zpcj", "cxbj", "kch",
    # Field names the prod code already uses.
    "kcmc", "jxb_id", "jsxm", "sfxwkc", "bfzcj", "xfjd",
    # Endpoint / param tokens.
    "cjcx_", "doType", "gnmkdm", "xnm", "xqm", "N305005",
    # Possible detail endpoints.
    "xscj", "cjcx_cxXsKscjList", "cjcx_cxXsgrcj", "cj_cx"
    "_cjmx", "cjmx", "details", " getCj ",
]


def safe_name(url: str) -> str:
    """Turn a URL into a safe filename."""
    s = re.sub(r"[^A-Za-z0-9._-]", "_", url)
    return s[-80:]


async def fetch(client: httpx.AsyncClient, url: str, **kw) -> Tuple[int, str, Dict[str, str]]:
    try:
        resp = await client.get(url, **kw)
        return resp.status_code, resp.text, dict(resp.headers)
    except Exception as e:
        return -1, f"<FETCH_ERROR {type(e).__name__}: {e}>", {}


def scan_keywords(text: str) -> Dict[str, int]:
    """Case-insensitive scan; returns keyword -> hit count (only >0)."""
    out: Dict[str, int] = {}
    low = text.lower()
    for kw in KEYWORDS:
        n = low.count(kw.lower())
        if n > 0:
            out[kw] = n
    return out


def extract_script_srcs(html: str) -> List[str]:
    """Extract <script src=...> URLs, resolving relative to base."""
    srcs = re.findall(r'<script[^>]*\bsrc=["\']([^"\']+)["\']', html, flags=re.IGNORECASE)
    resolved = []
    for s in srcs:
        if s.startswith("//"):
            s = "https:" + s
        elif s.startswith("/"):
            s = "https://jxw.sylu.edu.cn" + s
        elif s.startswith("http"):
            pass
        else:
            # relative — resolve against host root
            s = "https://jxw.sylu.edu.cn/" + s
        resolved.append(s)
    return resolved


def extract_form_fields(html: str) -> List[Dict[str, str]]:
    """Extract <input> fields with name + type (no values)."""
    fields = []
    for m in re.finditer(r'<input[^>]*>', html, flags=re.IGNORECASE):
        tag = m.group(0)
        name = re.search(r'\bname=["\']([^"\']+)["\']', tag, flags=re.IGNORECASE)
        type_ = re.search(r'\btype=["\']([^"\']+)["\']', tag, flags=re.IGNORECASE)
        id_ = re.search(r'\bid=["\']([^"\']+)["\']', tag, flags=re.IGNORECASE)
        if name:
            fields.append({
                "name": name.group(1),
                "type": type_.group(1) if type_ else "",
                "id": id_.group(1) if id_ else "",
            })
    return fields


async def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    print("=" * 60)
    print("  教务网站静态布局侦察 (无需登录)")
    print("=" * 60)

    async with httpx.AsyncClient(
        timeout=httpx.Timeout(15.0),
        follow_redirects=False,
        verify=False,
        headers={"User-Agent": UA},
    ) as client:
        summary: Dict[str, Any] = {
            "fetched": [],
            "keyword_hits": {},
            "form_fields": {},
            "script_srcs": {},
            "endpoint_candidates": set(),
        }

        # --- 1. Login page skeleton ---
        print("\n[1] 抓登录页骨架...")
        st, html, hdrs = await fetch(client, f"{INDEX_URL}/login_slogin.html")
        print(f"    HTTP {st}, len={len(html)}")
        (OUTPUT / "login_page.html").write_text(html, encoding="utf-8", errors="replace")
        fields = extract_form_fields(html) if st == 200 else []
        summary["form_fields"]["login_page"] = fields
        summary["fetched"].append({
            "url": f"{INDEX_URL}/login_slogin.html",
            "status": st,
            "bytes": len(html),
            "kind": "login_page_html",
        })
        # Keyword scan inline too
        hits = scan_keywords(html) if st == 200 else {}
        if hits:
            summary["keyword_hits"]["login_page"] = hits
        srcs = extract_script_srcs(html) if st == 200 else []
        summary["script_srcs"]["login_page"] = srcs
        # CSRF token contract — look for the prod-known id="csrftoken"
        csrf_match = re.search(
            r'id="csrftoken"[^>]*name="csrftoken"[^>]*value="([^"]+)"',
            html,
        )
        summary["csrf_contract"] = {
            "expected_id": "csrftoken",
            "found": bool(csrf_match),
            "note": "crawler_probe.get_csrf_token regex must still match this page",
        }
        print(f"    form fields: {[f['name'] for f in fields]}")
        print(f"    script srcs: {len(srcs)} 个")
        print(f"    CSRF contract found: {summary['csrf_contract']['found']}")

        # --- 2. Grade query page (no cookie — see whether it serves template or 302) ---
        print("\n[2] 抓成绩查询页 (不带 cookie，观测重定向/模板)...")
        st, html2, hdrs2 = await fetch(
            client, f"{GRADE_URL}/cjcx_cxXsgrcj.html",
            params={"gnmkdm": "N305005"},
        )
        print(f"    HTTP {st}, len={len(html2)}, Location={hdrs2.get('location','-')}")
        (OUTPUT / "grade_page_noauth.html").write_text(html2, encoding="utf-8", errors="replace")
        summary["fetched"].append({
            "url": f"{GRADE_URL}/cjcx_cxXsgrcj.html?gnmkdm=N305005",
            "status": st,
            "bytes": len(html2),
            "location": hdrs2.get("location"),
            "kind": "grade_page_noauth",
        })
        if st == 200:
            hits = scan_keywords(html2)
            if hits:
                summary["keyword_hits"]["grade_page_noauth"] = hits
            srcs2 = extract_script_srcs(html2)
            summary["script_srcs"]["grade_page_noauth"] = srcs2
            print(f"    keyword hits: {hits}")
            print(f"    script srcs: {len(srcs2)} 个")
            # Probe detail-endpoint patterns inside the template
            for pat in [
                r"cj cx_[A-Za-z0-9_]+",
                r"cj_[a-z]+_[a-zA-Z_]+",
                r"getCj[A-Za-z]*",
                r"function\s+([a-zA-Z_]*[Cc]j[a-zA-Z_]*)",
                r"doType\s*=\s*[\"'](\w+)[\"']",
            ]:
                found = re.findall(pat, html2, flags=re.IGNORECASE)
                if found:
                    summary["endpoint_candidates"].update(found)
        elif st == 302:
            print(f"    重定向目标: {hdrs2.get('location')}")

        # --- 3. Walk referenced JS files (deduped) ---
        all_srcs: List[str] = []
        for v in summary["script_srcs"].values():
            all_srcs.extend(v)
        all_srcs = list(dict.fromkeys(all_srcs))  # dedup preserve order
        print(f"\n[3] 抓引用的 JS 文件 ({len(all_srcs)} 个唯一)...")
        js_dir = OUTPUT / "js"
        js_dir.mkdir(exist_ok=True)
        for src in all_srcs:
            st, body, _ = await fetch(client, src)
            fname = safe_name(src)
            # Keep a sane suffix
            if not fname.endswith(".js") and not fname.endswith(".html"):
                fname = fname + ".bin"
            try:
                (js_dir / fname).write_text(body, encoding="utf-8", errors="replace")
            except Exception:
                # fall back to ascii-safe
                (js_dir / (Path(fname).stem + "_safe" + Path(fname).suffix or ".bin")
                 ).write_text(body, encoding="utf-8", errors="replace")
            entry = {
                "url": src, "status": st, "bytes": len(body),
                "keyword_hits": scan_keywords(body) if st == 200 and body else {},
                "cj_endpoints": (
                    sorted(set(re.findall(r'cjcx_[A-Za-z0-9_]+', body)))
                    if st == 200 and body else []
                ),
            }
            summary["fetched"].append({"kind": "js", **{k: entry[k] for k in (
                "url", "status", "bytes")}})
            if entry["keyword_hits"]:
                summary["keyword_hits"][src] = entry["keyword_hits"]
            if entry["cj_endpoints"]:
                summary["endpoint_candidates"].update(entry["cj_endpoints"])
            print(f"    {st} {src} ({len(body)}B) kw={entry['keyword_hits']} eps={entry['cj_endpoints']}")

        # --- 4. Probe known/probable endpoints HEAD-like (cheap status check) ---
        print("\n[4] 探测潜在详情接口状态码 (HEAD 不带凭据，仅看响应签名)...")
        candidates = sorted(set([
            f"{GRADE_URL}/cjcx_cxXsgrcj.html",
            f"{GRADE_URL}/cjcx_cxXsKscjList.html",
            f"{GRADE_URL}/cjcx_cxXsKscjcx.html",
            f"{GRADE_URL}/cjcx_cxCjmx.html",
            f"{GRADE_URL}/cj_cxHisCj.html",
            f"{GRADE_URL}/cjcx_getXsjcxx.html",
            f"{GRADE_URL}/cjcx_getXsKscjAllList.html",
        ] + [e if e.startswith("http") else f"{GRADE_URL}/{e}.html"
              for e in list(summary["endpoint_candidates"]) if not e.startswith("http")][:20]))
        ep_report = []
        for ep in candidates:
            st, body, hdrs = await fetch(client, ep)
            sig = {
                "url": ep,
                "status": st,
                "len": len(body),
                "location": hdrs.get("location"),
                "ctype": hdrs.get("content-type"),
            }
            ep_report.append(sig)
            print(f"    {st} {ep} (len={len(body)}, ctype={hdrs.get('content-type','-')})")
        summary["endpoint_status"] = ep_report

        # --- 5. Write summary report ---
        summary["endpoint_candidates"] = sorted(summary["endpoint_candidates"])

        # Markdown summary
        md = ["# 教务网站静态布局侦察报告\n",
              f"探测 URL 主机: https://jxw.sylu.edu.cn\n",
              "## 1. 抓取清单\n",
              "| # | 类型 | URL | HTTP | 字节 |",
              "|---|------|-----|------|------|"]
        for i, f in enumerate(summary["fetched"], 1):
            md.append(f"| {i} | {f.get('kind','-')} | {f.get('url','-')} | {f.get('status','-')} | {f.get('bytes',0)} |")
        md.append("\n## 2. 登录页表单字段\n")
        md.append("| name | type | id |")
        md.append("|------|------|----|")
        for fl in summary["form_fields"].get("login_page", []):
            md.append(f"| `{fl['name']}` | {fl['type']} | {fl.get('id','')} |")
        md.append("\n## 3. CSRF 契约\n")
        md.append(f"- crawler_probe 期望 `id=\"csrftoken\" name=\"csrftoken\" value=\"...\"`")
        md.append(f"- 实际命中: {summary['csrf_contract']['found']}")
        md.append("\n## 4. 关键词命中统计\n")
        for page, hits in summary["keyword_hits"].items():
            md.append(f"### {page}\n")
            md.append("| kw | cnt |")
            md.append("|----|-----|")
            for k, v in sorted(hits.items(), key=lambda kv: -kv[1]):
                md.append(f"| `{k}` | {v} |")
        md.append("\n## 5. 候选详情接口\n")
        for ep in summary["endpoint_candidates"]:
            md.append(f"- `{ep}`")
        md.append("\n## 6. 探测端点状态码（未带凭据）\n")
        md.append("| URL | HTTP | length | location | content-type |")
        md.append("|-----|------|--------|----------|--------------|")
        for s in summary["endpoint_status"]:
            md.append(f"| {s['url']} | {s['status']} | {s['len']} | {s.get('location','-')} | {s.get('ctype','-')} |")
        md.append("\n## 7. 引用的外部 JS 文件\n")
        for page, srcs in summary["script_srcs"].items():
            md.append(f"### {page}\n")
            for s in srcs:
                md.append(f"- {s}")

        (OUTPUT / "site_layout_report.md").write_text("\n".join(md), encoding="utf-8")
        (OUTPUT / "site_layout_summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2, default=str),
            encoding="utf-8")

        print(f"\n报告 → {OUTPUT / 'site_layout_report.md'}")
        print(f"摘要 → {OUTPUT / 'site_layout_summary.json'}")
        print(f"\n文件落盘:")
        for p in sorted(OUTPUT.rglob("*")):
            if p.is_file():
                print(f"  {p.relative_to(OUTPUT)}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))