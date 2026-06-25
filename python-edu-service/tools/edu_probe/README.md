# Edu Grade Structure Probe

Isolated probe tool for investigating the academic affairs grade API structure.

## crawler_probe.py Provenance

The minimal `ProbeCrawler` in `crawler_probe.py` was hand-written based on
the production `EduCrawler` API contract from:

- **Commit**: `8aaf6a13aa2bf356b6cf452e26eecbffed6bbd1d`
- **Date**: 2026-06-23 13:45:40 +0800
- **Subject**: fix(edu): restore edu and erke system to v1.5.10, removing client crawler

The production `services/crawler.py` (all Git revisions) has 49 corrupted
CJK continuation bytes that prevent UTF-8 decoding.  The probe crawler was
rewritten as a minimal, clean implementation covering only the methods
needed for grade structure inspection — it does NOT replace the production
crawler.

## Purpose

The current production scraper (`services/crawler.py`) returns raw `items` from the grade list endpoint, and `routers/grades.py` only maps 9 fields to `GradeInfo`. Many potential fields (exam type, retake status, usual score, final score, weights) are not extracted.

This probe:
1. Inventories ALL fields in the raw grade list response
2. Compares original vs retake records for known courses (e.g. "大学外语1")
3. Discovers grade detail endpoints from the query page HTML/JS
4. Generates a sanitized field structure report

## Security

- Password via `getpass.getpass()` — never in args, env, or files
- Cookies/tokens NEVER written to disk
- Student IDs masked (only last 4 digits shown)
- Personal names replaced with `***`
- All output files excluded from git via `.gitignore`
- Only the developer's own account should be used

## Usage

```bash
cd python-edu-service
python tools/edu_probe/probe_grade_structure.py
```

Follow the interactive prompts to:
1. Enter your student ID (not saved)
2. Enter your password (via getpass, never displayed)
3. Enter at least 2 semesters to probe (year + semester code)

## Output Structure

```
tools/edu_probe/
├── crawler_probe.py              # Copy of services/crawler.py (read-only)
├── probe_grade_structure.py      # Main probe script
├── sanitize.py                   # Data desensitization utilities
├── README.md                     # This file
├── output/                       # Sanitized probe output (gitignored)
│   ├── .gitkeep
│   ├── grade_list_<year>_<semester>_field_names.json
│   ├── grade_list_<year>_<semester>_sanitized.json
│   ├── grade_page_sanitized.html
│   └── discovered_endpoints.json
└── report/
    ├── .gitkeep
    └── grade_structure_report.md  # Final report
```

## Stopping Condition

After the report is generated, STOP. Do NOT modify:
- `services/crawler.py`
- `routers/grades.py`
- `models/schemas.py`
- Go handlers
- Flutter EduGrade / EduProvider

Wait for human review of the field inventory before implementing any production changes.
