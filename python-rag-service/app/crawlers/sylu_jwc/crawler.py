"""教务处全栏目发现与正文抓取编排。"""

from __future__ import annotations

from datetime import datetime, timezone
from urllib.error import HTTPError
from urllib.parse import urljoin

from .article_parser import parse_article, parse_list
from .attachment_resolver import resolve_attachment
from .catalog import BASE_URL, requested_categories
from .document_classifier import classify
from .fetcher import SiteFetcher
from .privacy_guard import scan


def crawl_jwc(
    categories: list[str] | None = None,
    known_source_urls: dict[str, list[str]] | None = None,
    max_pages: int = 3,
    reconcile: bool = False,
    resolve_attachments: bool = False,
) -> dict:
    """同步栏目目录和文章正文。

    ``max_pages <= 0`` 表示全量；增量模式仅从最新页开始，仍会抓取第一页以发现同 URL 内容变更。
    """
    configs = requested_categories(categories)
    known = known_source_urls or {}
    fetcher = SiteFetcher()
    items: list[dict] = []
    errors: list[dict] = []
    stats = {"categories_requested": len(configs), "pages_fetched": 0, "list_items_seen": 0, "article_details_fetched": 0, "stop_reason": "completed", "partial_failure": False}

    for config in configs:
        page_url = urljoin(BASE_URL, config.list_path)
        visited_pages: set[str] = set()
        page_count = 0
        while page_url and page_url not in visited_pages and (max_pages <= 0 or page_count < max_pages):
            visited_pages.add(page_url)
            try:
                page = fetcher.get(page_url)
                stats["pages_fetched"] += 1
                page_count += 1
                discovered, page_links = parse_list(page.body, config, page_url)
                stats["list_items_seen"] += len(discovered)
                for candidate in discovered:
                    known_urls = set(known.get(config.slug, []))
                    # reconcile 仍会回源读取已知 URL，普通增量只读未知条目。
                    if not reconcile and candidate.source_url in known_urls:
                        continue
                    try:
                        detail = fetcher.get(candidate.source_url)
                        item = parse_article(detail.body, candidate, candidate.source_url)
                        if resolve_attachments and item["attachments"]:
                            import os

                            storage_dir = os.environ.get("JWC_RAW_STORAGE_DIR", "").strip() or None
                            item["attachments"] = [resolve_attachment(att, fetcher, storage_dir) for att in item["attachments"]]
                        document_type, audience = classify(item["title"], item["content_text"], config.slug)
                        contains_personal_data, privacy_reasons = scan(item["content_text"])
                        item.update({"document_type": document_type, "audience": audience, "contains_personal_data": contains_personal_data, "privacy_reasons": privacy_reasons, "review_status": "needs_review"})
                        items.append(item)
                        stats["article_details_fetched"] += 1
                    except HTTPError as exc:
                        errors.append(_error(config.slug, "article", candidate.source_url, str(exc), exc.code in (408, 429, 500, 502, 503, 504)))
                    except Exception as exc:  # 单篇失败不影响其它栏目。
                        errors.append(_error(config.slug, "article", candidate.source_url, str(exc), True))
                next_pages = [link for link in page_links if link not in visited_pages]
                page_url = next_pages[0] if next_pages else ""
            except HTTPError as exc:
                errors.append(_error(config.slug, "list", page_url, str(exc), exc.code in (408, 429, 500, 502, 503, 504)))
                break
            except Exception as exc:
                errors.append(_error(config.slug, "list", page_url, str(exc), True))
                break
        if max_pages > 0 and page_url:
            stats["stop_reason"] = "max_pages_reached"

    stats["partial_failure"] = bool(errors)
    return {"success": not errors or bool(items), "generated_at": datetime.now(timezone.utc).isoformat(), "items": items, "stats": stats, "errors": errors[:20]}


def _error(category: str, stage: str, url: str, message: str, retryable: bool) -> dict:
    return {"category": category, "stage": stage, "url": url, "code": "fetch_failed", "message": message[:500], "retryable": retryable}
