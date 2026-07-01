# JWC Public Site Structure Probe

Isolated probe tool for investigating the **public** Shenyang Ligong University
Academic Affairs Office website (https://jwc.sylu.edu.cn/). This is the public
notification site — **no login, no cookie, no account**.

This probe is intentionally separate from `tools/edu_probe/` (which targets the
login-required grade system at `jxw.sylu.edu.cn`). Do not mix the two.

## Purpose

Before building a production server-side crawler and Go API for campus
notifications, we need to confirm the public site's HTML structure:

1. Homepage column sections and their "更多" (more) list-page URLs
2. List-page pagination rule (this site uses inverted numbering — see report)
3. Stable CSS selectors for: list item, title, date, content container, attachments
4. Whether article detail pages and attachment URLs are truly public (no login wall)
5. Page encoding, image/relative-URL completion rule, sticky-post detection
6. Failure/404 behavior

This probe is **throwaway** — it produces a structure report for human review.
After the report is approved, a separate production crawler will be built.

## Usage

```bash
cd python-edu-service

# 1. Probe homepage — find columns + "更多" links
python tools/jwc_public_probe/inspect_homepage.py

# 2. Probe category list pages — 教务通知 & 教务公告, first 2 pages each
python tools/jwc_public_probe/inspect_category.py

# 3. Probe article detail pages — 1 regular + 1 attachment-bearing, + 404 test
python tools/jwc_public_probe/inspect_article.py

# Unit tests
python -m pytest tools/jwc_public_probe -q
```

The three scripts run sequentially — each consumes the previous one's JSON
output from `output/`.

## Output Structure

```
tools/jwc_public_probe/
├── inspect_homepage.py            # 首页探针
├── inspect_category.py            # 栏目列表页探针
├── inspect_article.py             # 文章详情页探针
├── sanitize_html.py               # 白名单 HTML 清洗器
├── tests/
│   ├── conftest.py
│   └── test_sanitize_html.py
├── output/                        # gitignored — 探针原始输出
│   ├── .gitkeep
│   ├── homepage_sanitized.html
│   ├── homepage_summary.json
│   ├── category_*_page_*_sanitized.html
│   ├── category_*_summary.json
│   ├── sample_article_urls.json
│   ├── article_<id>_sanitized.html
│   ├── article_<id>_summary.json
│   ├── article_404_sanitized.html
│   └── article_probe_summary.json
├── report/
│   └── jwc_structure_report.md    # 最终结构报告（提交到 git）
├── README.md                      # 本文件
└── .gitignore
```

## HTTP Etiquette

- Explicit User-Agent identifying the probe
- Single-threaded (sequential `await`, NOT `asyncio.gather`)
- Request interval ≥ 500ms
- Timeout 15s, max 3 retries with exponential backoff (0.5s, 1s, 2s)
- No full-site crawl — only: homepage + 2 target columns × 2 pages + ≤2 sample articles + 1 deliberate 404
- Does NOT execute page JavaScript
- Does NOT download large attachments (HEAD or Range GET only)

## Security

- No credentials, no cookies, no login — public site only
- All raw output files in `output/` are gitignored
- Only the structure report (`report/jwc_structure_report.md`), scripts, tests, and this README are committed

## Stopping Condition

After the structure report is generated, **STOP**. Do NOT modify:

- `python-edu-service/services/` (production crawler — separate future task)
- `python-edu-service/routers/` (API routes)
- `python-edu-service/models/` (DB models)
- `python-edu-service/main.py`, `config.py`
- `client/lib/screens/campus_screen.dart` (Flutter campus page)
- `server/` (Go API)
- Database models or migrations
- Software announcement logic (`/notices`, `/announcements`)

Wait for human review of the structure report before any production changes.
