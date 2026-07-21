"""带域名校验、重试和节流的公开站点 HTTP 客户端。"""

from __future__ import annotations

import random
import time
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


ALLOWED_HOST = "jwc.sylu.edu.cn"


def validate_url(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    if parsed.scheme != "https" or parsed.hostname != ALLOWED_HOST or parsed.username:
        raise ValueError("仅允许访问 https://jwc.sylu.edu.cn")
    if parsed.port not in (None, 443):
        raise ValueError("不允许非标准 HTTPS 端口")
    return raw_url


@dataclass
class FetchResult:
    url: str
    body: bytes
    content_type: str
    status: int


class SiteFetcher:
    def __init__(self, *, min_delay: float = 0.5, max_delay: float = 0.8, timeout: float = 20.0, retries: int = 3):
        self.min_delay = min_delay
        self.max_delay = max_delay
        self.timeout = timeout
        self.retries = max(1, retries)
        self._last_request = 0.0
        # 禁用 urllib 的自动重定向，手动逐跳校验目标域名。
        self._opener = build_opener(_NoRedirectHandler())

    def get(self, url: str, *, max_bytes: int = 5 * 1024 * 1024) -> FetchResult:
        current = validate_url(url)
        last_error: Exception | None = None
        for attempt in range(self.retries):
            try:
                self._throttle()
                request = Request(current, headers={"User-Agent": "Shenliyuan-JWC-KnowledgeWorker/1.0"})
                with self._opener.open(request, timeout=self.timeout) as response:
                    status = int(response.status)
                    body = response.read(max_bytes + 1)
                    if len(body) > max_bytes:
                        raise ValueError("响应超过大小限制")
                    return FetchResult(current, body, response.headers.get_content_type(), status)
            except HTTPError as exc:
                if exc.code in (301, 302, 303, 307, 308):
                    location = exc.headers.get("Location", "")
                    if not location:
                        raise ValueError("重定向缺少 Location") from exc
                    current = validate_url(urljoin(current, location))
                    continue
                if exc.code in (404, 410):
                    raise
                last_error = exc
            except (URLError, TimeoutError, OSError, ValueError) as exc:
                last_error = exc
            if attempt + 1 < self.retries:
                time.sleep(0.5 * (2**attempt))
                # 出现偶发失败时仍保持单线程请求节奏。
                continue
        raise RuntimeError(f"抓取失败: {current}: {last_error}") from last_error

    def _throttle(self) -> None:
        now = time.monotonic()
        wait = self._last_request + random.uniform(self.min_delay, self.max_delay) - now
        if wait > 0:
            time.sleep(wait)
        self._last_request = time.monotonic()


class _NoRedirectHandler(HTTPRedirectHandler):
    """在 fetcher 中将重定向作为普通错误返回，由上层决定是否允许。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        validate_url(newurl)
        return None
