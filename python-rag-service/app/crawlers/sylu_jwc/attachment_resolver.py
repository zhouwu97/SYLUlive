"""附件最终地址解析、签名识别和私有原始归档。"""

from __future__ import annotations

import hashlib
from pathlib import Path

from .fetcher import SiteFetcher


MAGIC_TYPES = {
    b"%PDF": ("application/pdf", "pdf"),
    b"PK\x03\x04": ("application/zip", "zip"),
    b"\xD0\xCF\x11\xE0": ("application/vnd.ms-office", "ole"),
}


def resolve_attachment(attachment: dict, fetcher: SiteFetcher, storage_dir: str | None = None) -> dict:
    """下载附件并返回可持久化元数据；不识别的格式保持 discovered 状态。"""
    result = dict(attachment)
    try:
        fetched = fetcher.get(attachment["url"], max_bytes=32 * 1024 * 1024)
        body = fetched.body
        sha256 = hashlib.sha256(body).hexdigest()
        mime, signature_ext = _detect_type(body, fetched.content_type)
        extension = (attachment.get("extension") or signature_ext).lower()
        if mime == "text/html" and ("验证码".encode("utf-8") in body or b"codeValue" in body):
            result.update({
                "resolved_url": fetched.url,
                "sha256": sha256,
                "size_bytes": len(body),
                "detected_mime": mime,
                "parse_status": "blocked_captcha",
                "privacy_status": "pending",
            })
            return result
        result.update({
            "resolved_url": fetched.url,
            "sha256": sha256,
            "size_bytes": len(body),
            "detected_mime": mime,
            "extension": extension[:16],
            "parse_status": "needs_review" if extension in {"ole", "zip", "rar"} else "discovered",
            "privacy_status": "pending",
        })
        if storage_dir:
            root = Path(storage_dir).resolve()
            root.mkdir(parents=True, exist_ok=True)
            target = root / sha256
            target.write_bytes(body)
            result["raw_storage_key"] = str(target.relative_to(root))
    except Exception as exc:
        result.update({"parse_status": "failed", "error": str(exc)[:300]})
    return result


def _detect_type(body: bytes, content_type: str) -> tuple[str, str]:
    for signature, value in MAGIC_TYPES.items():
        if body.startswith(signature):
            return value
    if content_type and content_type != "application/octet-stream":
        return content_type, _extension_from_mime(content_type)
    return "application/octet-stream", ""


def _extension_from_mime(mime: str) -> str:
    return {
        "application/pdf": "pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/msword": "doc",
        "application/vnd.ms-excel": "xls",
    }.get(mime, "")
